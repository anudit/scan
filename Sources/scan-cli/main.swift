import Foundation
let arguments = CommandLine.arguments.dropFirst()
let files = arguments.filter { !$0.hasPrefix("-") }
if files.isEmpty || arguments.contains("--help") {
    print("Usage: scan <file.csv|file.tsv|file.csv.gz|file.tsv.gz|file.jsonl|file.ndjson|file.jsonl.gz|file.ndjson.gz|file.parquet|file.sqlite|file.duckdb|https://…/file.parquet> ...")
    print("")
    print("Remote Parquet URLs, including Hugging Face dataset links, are previewed on demand")
    print("with HTTP range requests. Set HF_TOKEN to open gated or private repositories.")
} else {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let bundled = own.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scan.app")
    let paths = files.map { argument -> String in
        if let url = URL(string: argument), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url.absoluteString
        }
        return URL(fileURLWithPath: argument).standardizedFileURL.path
    }
    process.arguments = ["-a", FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : "Scan"] + paths
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) } catch { fputs("scan: \(error.localizedDescription)\n", stderr); exit(1) }
}
