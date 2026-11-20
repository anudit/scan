import Foundation
import ScanEngine
import ScanQuery

@main struct ScanBench {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { print("Usage: ScanBench <file> [output.json] | ScanBench --quicklook <file>..."); return }
        if CommandLine.arguments[1] == "--quicklook" { try await quickLook(CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath:$0) }); return }
        if CommandLine.arguments[1] == "--open" { try await openStages(URL(fileURLWithPath:CommandLine.arguments[2])); return }
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
    /// One cold pass over the app's open sequence, printing each stage: `ScanBench --open <file>`.
    static func openStages(_ url: URL) async throws {
        func ms(_ start: ContinuousClock.Instant) -> Double { let d = start.duration(to:.now); return Double(d.components.seconds)*1000 + Double(d.components.attoseconds)/1e15 }
        func stage(_ name: String, _ start: ContinuousClock.Instant) { print("\(name): \(String(format:"%.0f",ms(start))) ms") }
        let total = ContinuousClock.now
        var t = ContinuousClock.now
        let engine = try Engine(memoryMB:512,threads:4); stage("engine_init", t)
        t = .now; let info = try await engine.open(url); stage("open_schema", t)
        print("columns: \(info.columns.count), needsImport: \(info.needsImport)")
        t = .now; let first = try await engine.preview(limit:256); stage("first_page", t); print("first page rows: \(first.count)")
        if info.needsImport { t = .now; try await engine.materialize(); stage("materialize", t) }
        var state = ViewState(); state.columns = info.columns
        t = .now; let count = try await engine.apply(state,generation:1); stage("count", t); print("rows: \(count)")
        t = .now; _ = try await engine.page(offset:max(0,count/2),generation:1); stage("deep_page", t)
        t = .now; _ = try await engine.page(offset:max(0,count-256),generation:1); stage("last_page", t)
        if let text = info.columns.first(where: { $0.kind == .text }) {
            state.filter = "\(Planner.identifier(text.name)) ILIKE '%anu%'"
            t = .now; let hits = try await engine.apply(state,generation:2); stage("filter_count", t); print("filter rows: \(hits)")
            t = .now; let page = try await engine.page(offset:0,generation:2); stage("filter_page", t); print("first hit: \(page.columns[0].first.flatMap { $0 } ?? "-")")
        }
        state.filter = ""
        if let number = info.columns.first(where: { $0.kind == .number }) {
            state.sorts = [SortKey(number.name,ascending:false)]
            t = .now; _ = try await engine.apply(state,generation:3); stage("sort_order", t)
            t = .now; let page = try await engine.page(offset:0,generation:3); stage("sort_page", t); print("top: \(page.columns.map { $0.first.flatMap { $0 } ?? "-" }.prefix(4))")
        }
        if let number = info.columns.first(where: { $0.kind == .number }) {
            state.sorts = []
            _ = try await engine.apply(state,generation:4)
            t = .now; _ = try await engine.sparklines(columns:info.columns.filter { $0.kind == .number }.map(\.name),generation:4); stage("sparklines", t)
            t = .now; let profile = try await engine.profile(column:number.name,generation:4); stage("profile", t); print("distinct: \(profile.distinct)")
        }
        stage("total", total)
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
