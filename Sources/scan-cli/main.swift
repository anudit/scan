import Foundation
let arguments = CommandLine.arguments.dropFirst()
let files = arguments.filter { !$0.hasPrefix("-") }
if arguments.first == "upgrade" || arguments.first == "update" { upgrade(checkOnly: arguments.contains("--check")) }
if arguments.contains("--version") { print(installedVersion() ?? "unknown"); exit(0) }
if files.isEmpty || arguments.contains("--help") {
    print("Usage: scan <file|folder|https://…/file|s3://bucket/key|gs://…|r2://…> ...")
    print("")
    print("Files: CSV, TSV, PSV, TXT, JSON, JSONL/NDJSON and GeoJSON (each optionally .gz or .zst),")
    print("Parquet (.parquet, .parq, .pq), Excel (.xlsx), SQLite and DuckDB databases.")
    print("A folder opens as one table of its Parquet, CSV or JSON Lines files, including")
    print("Hive-partitioned layouts such as year=2024/month=01/part-0.parquet.")
    print("")
    print("Remote Parquet URLs, including Hugging Face dataset links, are previewed on demand")
    print("with HTTP range requests; other remote files are downloaded in full.")
    print("Set HF_TOKEN to open gated or private repositories.")
} else {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let bundled = own.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scan.app")
    let paths = files.map { argument -> String in
        if let url = URL(string: argument), let scheme = url.scheme?.lowercased(),
           ["http", "https", "s3", "s3a", "gs", "gcs", "r2"].contains(scheme) {
            return url.absoluteString
        }
        return URL(fileURLWithPath: argument).standardizedFileURL.path
    }
    process.arguments = ["-a", FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : "Scan"] + paths
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) } catch { fputs("scan: \(error.localizedDescription)\n", stderr); exit(1) }
}

func appBundle() -> URL? {
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let beside = own.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scan.app")
    for candidate in [beside, URL(fileURLWithPath: "/Applications/Scan.app")] where FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    return nil
}
func installedVersion() -> String? {
    guard let app = appBundle(), let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
    return info["CFBundleShortVersionString"] as? String
}
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }, y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    for i in 0..<max(x.count, y.count) { let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0; if l != r { return l > r } }
    return false
}
@discardableResult func run(_ tool: String, _ args: [String]) -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = args
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return 127 }
}
func fail(_ message: String) -> Never { fputs("scan: \(message)\n", stderr); exit(1) }
/// `scan upgrade`: installs the newest GitHub release over this Scan.app and scan command.
func upgrade(checkOnly: Bool) -> Never {
    let api = URL(string: "https://api.github.com/repos/anudit/scan/releases/latest")!
    var request = URLRequest(url: api, timeoutInterval: 20); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    var payload: Data?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if (response as? HTTPURLResponse)?.statusCode == 200 { payload = data }
        done.signal()
    }.resume(); done.wait()
    guard let payload, let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let tag = json["tag_name"] as? String else { fail("could not reach GitHub releases.") }
    let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let current = installedVersion() ?? "0"
    guard isNewer(latest, than: current) else { print("Scan \(current) is up to date."); exit(0) }
    print("Scan \(latest) is available (installed: \(current)).")
    if checkOnly { print("Run `scan upgrade` to install it."); exit(0) }
    let assets = json["assets"] as? [[String: Any]] ?? []
    guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }), let link = asset["browser_download_url"] as? String else {
        fail("release \(tag) has no zip to install. See \(json["html_url"] as? String ?? "GitHub").")
    }
    guard let target = appBundle() else { fail("could not find Scan.app next to this command or in /Applications.") }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("scan-upgrade-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    print("Downloading \(asset["name"] as? String ?? link)…")
    let zip = work.appendingPathComponent("release.zip")
    guard run("/usr/bin/curl", ["-L", "--fail", "--silent", "--show-error", "-o", zip.path, link]) == 0 else { fail("download failed.") }
    let unpacked = work.appendingPathComponent("unpacked")
    guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { fail("could not unpack the download.") }
    guard let found = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "Scan.app" }) else { fail("the download has no Scan.app.") }
    // Replace the app, then the command line tool that shipped beside it.
    let staged = target.deletingLastPathComponent().appendingPathComponent(".Scan.app.upgrade")
    try? FileManager.default.removeItem(at: staged)
    guard run("/usr/bin/ditto", [found.path, staged.path]) == 0 else { fail("could not write to \(target.deletingLastPathComponent().path). Try with sudo.") }
    do { _ = try FileManager.default.replaceItemAt(target, withItemAt: staged) } catch { try? FileManager.default.removeItem(at: staged); fail("could not replace \(target.path): \(error.localizedDescription)") }
    let newTool = found.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/scan")
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if FileManager.default.fileExists(atPath: newTool.path), own.lastPathComponent == "scan" {
        let temp = own.deletingLastPathComponent().appendingPathComponent(".scan.upgrade")
        try? FileManager.default.removeItem(at: temp)
        if (try? FileManager.default.copyItem(at: newTool, to: temp)) != nil { _ = try? FileManager.default.replaceItemAt(own, withItemAt: temp) }
    }
    print("Upgraded Scan to \(latest). Relaunch the app to use it.")
    exit(0)
}
