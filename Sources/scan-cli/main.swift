import Foundation
let arguments = CommandLine.arguments.dropFirst()
let files = arguments.filter { !$0.hasPrefix("-") }
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
