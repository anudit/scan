import Foundation
import ScanEngine
import ScanQuery

@main struct ScanBench {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { print("Usage: ScanBench <file> [output.json]"); return }
        let url = URL(fileURLWithPath:CommandLine.arguments[1])
        var results: [String:[Double]] = [:]
        func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
            let start = ContinuousClock.now; let value = try await body(); let duration = start.duration(to:.now)
            let ms = Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15
            results[name,default:[]].append(ms); print("\(name): \(String(format:"%.2f",ms)) ms"); return value
        }
        for _ in 0..<3 {
            let engine = try await measure("engine_init") { try Engine() }
            let info = try await measure("open_schema") { try await engine.open(url) }
            _ = try await measure("first_page") { try await engine.preview(limit:256) }
            if info.needsImport { try await measure("materialize") { try await engine.materialize() } }
            var state = ViewState(); state.columns = info.columns
            let count = try await measure("count") { try await engine.apply(state,generation:1) }
            _ = try await measure("deep_page") { try await engine.page(offset:max(0,count/2),generation:1) }
            _ = try await measure("last_page") { try await engine.page(offset:max(0,count-256),generation:1) }
            if let col = info.columns.first(where: { $0.kind == .number }) {
                state.sorts = [SortKey(col.name,ascending:false)]
                _ = try await measure("sort_order_ids") { try await engine.apply(state,generation:2) }
                _ = try await measure("sort_page") { try await engine.page(offset:0,generation:2) }
            }
            if let col = info.columns.first(where: { $0.kind == .text }) {
                state.sorts = []; state.filter = "\(Planner.identifier(col.name)) ILIKE '%covid%'"
                _ = try await measure("filter_count") { try await engine.apply(state,generation:3) }
            }
            state.filter = ""
            if info.columns.contains(where: { $0.name == "openaccessinfo" }) {
                _ = try await measure("pivot_license") { try await engine.ask("SELECT json_extract_string(openaccessinfo, '$.license') AS license, count(*) AS records, avg(length(abstract)) AS average_abstract_length FROM scan_data GROUP BY 1 ORDER BY 2 DESC") }
            } else if let column = info.columns.first(where: { $0.kind == .text }) {
                state.groups = [column.name]
                _ = try await measure("pivot") { try await engine.pivot(state:state) }
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        let medians = results.mapValues { values in values.sorted()[values.count/2] }
        let report: [String:Any] = ["dataset":url.path,"runs":results,"median_ms":medians,"peak_rss_mb":Double(usage.ru_maxrss)/1048576,"os":ProcessInfo.processInfo.operatingSystemVersionString,"duckdb":"1.5.6","date":ISO8601DateFormatter().string(from:Date()),"note":"Engine-only, warm filesystem cache across runs. UI first paint is separate."]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count > 2 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2])) }
        else { print(String(decoding:data,as:UTF8.self)) }
    }
}
