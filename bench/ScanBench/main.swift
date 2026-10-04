import Foundation
import ScanEngine
import ScanQuery

@main struct ScanBench {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { print("Usage: ScanBench <file> [output.json] | ScanBench --quicklook <file>..."); return }
        if CommandLine.arguments[1] == "--quicklook" { try await quickLook(CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath:$0) }); return }
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
    /// Mirrors QuickLook/PreviewViewController: a fresh engine per preview, schema, first 10 rows.
    static func quickLook(_ urls: [URL]) async throws {
        func ms(_ start: ContinuousClock.Instant) -> Double { let d = start.duration(to:.now); return Double(d.components.seconds)*1000 + Double(d.components.attoseconds)/1e15 }
        for url in urls {
            var stages: [String:[Double]] = [:]
            for _ in 0..<7 {
                let total = ContinuousClock.now
                var t = ContinuousClock.now
                let engine = try Engine.preview(); stages["init",default:[]].append(ms(t))
                t = .now; _ = try await engine.open(url, previewLimit:10); stages["open",default:[]].append(ms(t))
                t = .now; let page = try await engine.preview(limit:10); stages["rows",default:[]].append(ms(t))
                precondition(page.count <= 10)
                stages["total",default:[]].append(ms(total))
            }
            let median = stages.mapValues { $0.sorted()[$0.count/2] }
            print(String(format:"%-48@ init %6.1f  open %6.1f  rows %6.1f  total %6.1f ms", url.lastPathComponent as NSString, median["init"]!, median["open"]!, median["rows"]!, median["total"]!))
        }
    }
}
