import Foundation
import CryptoKit
import Security
import os

/// Object storage that speaks the S3 API: Amazon S3 (`s3://bucket/key`), Google Cloud Storage
/// (`gs://bucket/key`, through its XML API with HMAC keys) and Cloudflare R2 (`r2://bucket/key`).
/// Objects are read over HTTPS with AWS Signature Version 4, through the same range reader and
/// download cache as other remote files. Without credentials, requests go unsigned, which works
/// for public buckets.
public enum CloudProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case s3, gcs, r2
    public var id: String { rawValue }
    public var title: String {
        switch self { case .s3: "Amazon S3"; case .gcs: "Google Cloud Storage"; case .r2: "Cloudflare R2" }
    }
    public var scheme: String {
        switch self { case .s3: "s3"; case .gcs: "gs"; case .r2: "r2" }
    }
    /// The URL schemes that name an object in this provider.
    static func provider(scheme: String?) -> CloudProvider? {
        switch scheme?.lowercased() {
        case "s3", "s3a": .s3
        case "gs", "gcs": .gcs
        case "r2": .r2
        default: nil
        }
    }
    /// Variables read before the keychain, so the CLI and scripts work without Settings.
    var environmentNames: (key: [String], secret: [String], token: [String], region: [String], endpoint: [String], account: [String]) {
        switch self {
        case .s3: (["AWS_ACCESS_KEY_ID"], ["AWS_SECRET_ACCESS_KEY"], ["AWS_SESSION_TOKEN"],
                   ["AWS_REGION", "AWS_DEFAULT_REGION"], ["AWS_ENDPOINT_URL_S3", "AWS_ENDPOINT_URL"], [])
        case .gcs: (["GCS_ACCESS_KEY_ID", "GOOGLE_HMAC_ACCESS_ID"], ["GCS_SECRET_ACCESS_KEY", "GOOGLE_HMAC_SECRET"], [], [], [], [])
        case .r2: (["R2_ACCESS_KEY_ID"], ["R2_SECRET_ACCESS_KEY"], [], [], [], ["R2_ACCOUNT_ID", "CLOUDFLARE_ACCOUNT_ID"])
        }
    }
}

/// Keys for one provider. Region and endpoint only apply to S3 (an endpoint points Scan at an
/// S3-compatible server such as MinIO); the account ID only applies to R2.
public struct CloudCredentials: Codable, Equatable, Sendable {
    public var accessKeyID = ""
    public var secretAccessKey = ""
    public var sessionToken = ""
    public var region = ""
    public var endpoint = ""
    public var accountID = ""
    public init(accessKeyID: String = "", secretAccessKey: String = "", sessionToken: String = "",
                region: String = "", endpoint: String = "", accountID: String = "") {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey; self.sessionToken = sessionToken
        self.region = region; self.endpoint = endpoint; self.accountID = accountID
    }
    public var canSign: Bool { !accessKeyID.isEmpty && !secretAccessKey.isEmpty }
    var isEmpty: Bool { self == CloudCredentials() }

    private static let service = "dev.scan.app.cloud"

    /// Environment variables win over the keychain, field by field.
    public static func current(_ provider: CloudProvider) -> CloudCredentials {
        var result = load(provider) ?? CloudCredentials()
        let names = provider.environmentNames
        let environment = ProcessInfo.processInfo.environment
        func read(_ keys: [String]) -> String? {
            keys.lazy.compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        if let key = read(names.key), let secret = read(names.secret) {
            result.accessKeyID = key; result.secretAccessKey = secret
            result.sessionToken = read(names.token) ?? ""
        }
        if let region = read(names.region) { result.region = region }
        if let endpoint = read(names.endpoint) { result.endpoint = endpoint }
        if let account = read(names.account) { result.accountID = account }
        return result
    }

    public static func load(_ provider: CloudProvider) -> CloudCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CloudCredentials.self, from: data)
    }

    @discardableResult
    public static func save(_ credentials: CloudCredentials, for provider: CloudProvider) -> Bool {
        var trimmed = credentials
        for path in [\CloudCredentials.accessKeyID, \.secretAccessKey, \.sessionToken, \.region, \.endpoint, \.accountID] {
            trimmed[keyPath: path] = trimmed[keyPath: path].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        if trimmed.isEmpty { return true }
        guard let data = try? JSONEncoder().encode(trimmed) else { return false }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "Scan · \(provider.title) keys"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

/// Where a remote file is actually fetched from, and how each request is authorized.
struct RemoteEndpoint: Sendable {
    /// The HTTPS URL requests are sent to.
    var url: URL
    var provider: CloudProvider?
    var signer: SigV4Signer?
    /// A Hugging Face bearer token. It is only set for Hugging Face hosts.
    var bearer: String?

    func authorize(_ request: inout URLRequest) {
        if let signer { signer.sign(&request) }
        else if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    }

    /// The error for a 401 or 403 response.
    var accessError: RemoteParquetError {
        guard let provider else { return .authenticationRequired }
        return .accessDenied(provider, signed: signer != nil)
    }

    static func resolve(_ origin: URL) async throws -> RemoteEndpoint {
        guard let provider = CloudProvider.provider(scheme: origin.scheme) else {
            let host = origin.host?.lowercased() ?? ""
            let hf = ["huggingface.co", "www.huggingface.co", "hf.co"].contains(host)
            return RemoteEndpoint(url: origin, bearer: hf ? HuggingFaceToken.current() : nil)
        }
        let object = try CloudObject(origin)
        let credentials = CloudCredentials.current(provider)
        switch provider {
        case .s3:
            let custom = credentials.endpoint.isEmpty ? nil : try endpointURL(credentials.endpoint)
            var region = credentials.region
            if custom == nil, region.isEmpty, credentials.canSign { region = await S3Region.discover(bucket: object.bucket) ?? "us-east-1" }
            if region.isEmpty { region = "us-east-1" }
            let url: URL
            if let custom { url = try object.pathStyle(custom) }
            else if object.bucket.contains(".") {
                // A dotted bucket name does not match the wildcard certificate of the virtual host.
                url = try object.pathStyle(URL(string: credentials.canSign ? "https://s3.\(region).amazonaws.com" : "https://s3.amazonaws.com")!)
            } else {
                url = try object.virtualHosted(credentials.canSign ? "s3.\(region).amazonaws.com" : "s3.amazonaws.com")
            }
            return RemoteEndpoint(url: url, provider: .s3, signer: credentials.canSign ? SigV4Signer(credentials, region: region) : nil)
        case .gcs:
            let url = try object.pathStyle(URL(string: "https://storage.googleapis.com")!)
            return RemoteEndpoint(url: url, provider: .gcs, signer: credentials.canSign ? SigV4Signer(credentials, region: "auto") : nil)
        case .r2:
            let account = credentials.accountID.lowercased()
            guard !account.isEmpty, account.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw RemoteParquetError.unsupported("Add your Cloudflare account ID and R2 keys in Settings → Cloud Storage, or set R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY.")
            }
            let url = try object.pathStyle(URL(string: "https://\(account).r2.cloudflarestorage.com")!)
            return RemoteEndpoint(url: url, provider: .r2, signer: credentials.canSign ? SigV4Signer(credentials, region: "auto") : nil)
        }
    }

    private static func endpointURL(_ text: String) throws -> URL {
        let value = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            throw RemoteParquetError.unsupported("The S3 endpoint “\(text)” is not a valid URL.")
        }
        return url
    }
}

/// A bucket and key parsed from `s3://bucket/key`.
struct CloudObject {
    var bucket: String
    var key: String
    init(_ url: URL) throws {
        guard let bucket = url.host(percentEncoded: false), !bucket.isEmpty else { throw RemoteParquetError.invalidURL }
        let key = String(url.path(percentEncoded: false).drop(while: { $0 == "/" }))
        guard !key.isEmpty, !key.hasSuffix("/") else { throw RemoteParquetError.invalidURL }
        self.bucket = bucket; self.key = key
    }
    /// `https://endpoint/bucket/key`.
    func pathStyle(_ endpoint: URL) throws -> URL {
        var base = endpoint.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + SigV4Signer.encode(bucket) + "/" + SigV4Signer.encode(key, keepSlash: true)) else { throw RemoteParquetError.invalidURL }
        return url
    }
    /// `https://bucket.host/key`.
    func virtualHosted(_ host: String) throws -> URL {
        guard let url = URL(string: "https://\(bucket).\(host)/" + SigV4Signer.encode(key, keepSlash: true)) else { throw RemoteParquetError.invalidURL }
        return url
    }
}

/// Finds a bucket's region from the `x-amz-bucket-region` header, which S3 returns even to
/// unauthenticated requests. Results are remembered for the life of the process.
enum S3Region {
    private static let known = OSAllocatedUnfairLock(initialState: [String: String]())

    static func discover(bucket: String) async -> String? {
        if let cached = known.withLock({ $0[bucket] }) { return cached }
        guard !bucket.contains("."), let url = URL(string: "https://\(bucket).s3.amazonaws.com/") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let region = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-amz-bucket-region"), !region.isEmpty else { return nil }
        known.withLock { $0[bucket] = region }
        return region
    }
}

/// AWS Signature Version 4 for unpayloaded GET and HEAD requests to an S3-compatible API.
struct SigV4Signer: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String
    let region: String
    let service = "s3"

    init(_ credentials: CloudCredentials, region: String) {
        accessKeyID = credentials.accessKeyID
        secretAccessKey = credentials.secretAccessKey
        sessionToken = credentials.sessionToken
        self.region = region
    }

    /// The SHA-256 of an empty body.
    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func sign(_ request: inout URLRequest, date: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date), day = String(stamp.prefix(8))
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var headers = ["host": hostHeader, "x-amz-content-sha256": Self.emptyHash, "x-amz-date": stamp]
        if !sessionToken.isEmpty { headers["x-amz-security-token"] = sessionToken }
        if let range = request.value(forHTTPHeaderField: "Range") { headers["range"] = range }
        for (name, value) in headers where name != "host" && name != "range" { request.setValue(value, forHTTPHeaderField: name) }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()

        let canonical = [request.httpMethod ?? "GET",
                         Self.canonicalPath(url),
                         Self.canonicalQuery(url),
                         canonicalHeaders,
                         signedHeaders,
                         Self.emptyHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// The path exactly as sent. Paths are built with `encode`, so they are already canonical.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? "/" : path
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else { return "" }
        return items.map { (encode($0.name), encode($0.value ?? "")) }.sorted { $0 < $1 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// Percent-encodes everything except the RFC 3986 unreserved characters (and `/` in keys).
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var result = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                result.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/") where keepSlash: result.append("/")
            default: result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}
