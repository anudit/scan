import Foundation
let files = CommandLine.arguments.dropFirst()
if files.isEmpty || files.contains("--help") { print("Usage: scan <file.csv|file.tsv|file.csv.gz|file.tsv.gz|file.jsonl|file.jsonl.gz|file.parquet|file.sqlite|file.duckdb> ...") }
else {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let bundled = own.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scan.app")
    process.arguments = ["-a", FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : "Scan"] + files.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) } catch { fputs("scan: \(error.localizedDescription)\n", stderr); exit(1) }
}
