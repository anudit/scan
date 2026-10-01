import Foundation
import ScanQuery
import CSQLite
import os

public struct SourceInfo: Sendable {
    public var columns: [Column]; public var tables: [String]; public var format: String; public var needsImport: Bool
}
public struct AskResult: Sendable {
    public var columns: [Column]
    public var page: RowPage
}
public actor Engine {
    private nonisolated let connection: Connection
    private var source = "source"
    private var sourceURL: URL?
    private var format = ""
    private var schema: [Column] = []
    private var tables: [String] = []
    private var hasRowID = false
    private var rowID = "rowid"
    private var ordered = false
    private var activeState = ViewState()
    private var generation = 0
    private let log = OSSignposter(subsystem: "dev.scan.app", category: "Queries")
    public init(memoryMB: Int = 512, threads: Int = 4) throws { connection = try Connection(memoryMB: memoryMB, threads: threads) }
    public nonisolated func cancel() { connection.cancel() }
    public var memoryLimitMB: Int { connection.memoryMB }
    public func open(_ url: URL, table: String? = nil, previewLimit: Int? = nil) throws -> SourceInfo {
        sourceURL = url; ordered = false; format = url.pathExtension.lowercased()
        try connection.execute("DROP VIEW IF EXISTS scan_data")
        try connection.execute("DROP VIEW IF EXISTS source")
        if ["duckdb", "ddb"].contains(format) {
            if tables.isEmpty { try connection.execute("ATTACH \(Planner.literal(url.path)) AS input (READ_ONLY)") }
            let result = try connection.query(SQL("SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_catalog='input' ORDER BY 1"))
            tables = result.columns.first?.compactMap { $0 } ?? []
            guard let chosen = table ?? tables.first else { throw EngineError("This database contains no tables.") }
            let parts = chosen.split(separator: ".", maxSplits: 1).map(String.init)
            source = "input." + parts.map(Planner.identifier).joined(separator: ".")
            rowID = "rowid"; hasRowID = true
        } else if ["sqlite", "sqlite3", "db"].contains(format) {
            tables = try sqliteTables(url)
            guard let chosen = table ?? tables.first else { throw EngineError("This database contains no tables.") }
            try importSQLite(url, table: chosen, limit: previewLimit)
            source = "sqlite_data"; rowID = "rowid"; hasRowID = true
        } else {
            source = "source"
            let parquet = format == "parquet"
            let jsonl = format == "jsonl" || url.lastPathComponent.lowercased().hasSuffix(".jsonl.gz")
            let reader: String
            if parquet {
                reader = "read_parquet(\(Planner.literal(url.path)), file_row_number=true)"
            } else if jsonl {
                reader = "read_json(\(Planner.literal(url.path)), format='newline_delimited', sample_size=2048, compression='\(format == "gz" ? "gzip" : "uncompressed")')"
            } else {
                reader = "read_csv(\(Planner.literal(url.path)), header=true, sample_size=2048\(format == "tsv" || url.lastPathComponent.lowercased().hasSuffix(".tsv.gz") ? ", delim='\\t'" : ""))"
            }
            try connection.execute("CREATE VIEW source AS SELECT * FROM \(reader)")
            hasRowID = parquet; rowID = "file_row_number"
        }
        schema = try describe(source).filter { !(format == "parquet" && $0.name == "file_row_number") }
        try connection.execute("CREATE TEMP VIEW scan_data AS SELECT * FROM \(source)")
        activeState = ViewState(); activeState.columns = schema
        return SourceInfo(columns: schema, tables: tables, format: format, needsImport: !hasRowID)
    }
    private func describe(_ relation: String) throws -> [Column] {
        let rows = try connection.query(SQL("SELECT CAST(column_name AS VARCHAR), CAST(column_type AS VARCHAR) FROM (DESCRIBE SELECT * FROM \(relation))"))
        return (0..<rows.count).map { Column(rows.columns[0][$0] ?? "", rows.columns[1][$0] ?? "VARCHAR") }
    }
    public func materialize() throws {
        guard !hasRowID else { return }
        try connection.execute("CREATE OR REPLACE TABLE imported AS SELECT * FROM source",retryOnOOM:true)
        source = "imported"; rowID = "rowid"; hasRowID = true
        try connection.execute("CREATE OR REPLACE TEMP VIEW scan_data AS SELECT * FROM imported")
    }
    private func whereClause(_ state: ViewState) throws -> String {
        try Planner.validateFilter(state.filter)
        return state.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " WHERE (\(state.filter))"
    }
    public func apply(_ state: ViewState, generation: Int) throws -> Int {
        let interval = log.beginInterval("apply")
        defer { log.endInterval("apply", interval) }
        let predicate = try whereClause(state)
        if !state.sorts.isEmpty && !hasRowID { try materialize() }
        if !state.sorts.isEmpty || (!predicate.isEmpty && hasRowID) || ["duckdb", "ddb"].contains(format) {
            let order = Planner.order(state.sorts)
            // Materialize only ordered row IDs. Payload columns never enter the sort.
            try connection.execute("CREATE OR REPLACE TEMP TABLE next_order AS SELECT \(Planner.identifier(rowID)) AS rid FROM \(source)\(predicate)\(order)",retryOnOOM:true)
            try connection.execute("DROP TABLE IF EXISTS scan_order")
            try connection.execute("ALTER TABLE next_order RENAME TO scan_order")
            ordered = true
        } else { ordered = false }
        activeState = state; self.generation = generation
        let count = try connection.query(SQL("SELECT CAST(count(*) AS VARCHAR) FROM \(ordered ? "scan_order" : source)\(ordered ? "" : predicate)"))
        return Int(count.columns[0][0] ?? "0") ?? 0
    }
    public func page(offset: Int, limit: Int = 256, generation: Int, full: Bool = false) throws -> RowPage {
        guard generation == self.generation else { throw CancellationError() }
        let interval = log.beginInterval("page fetch"); defer { log.endInterval("page fetch", interval) }
        let projection = activeState.columns.map { Planner.display($0, alias: "s", full: full) }.joined(separator: ", ")
        guard !projection.isEmpty else { return RowPage(offset: offset, columns: []) }
        let sql: String
        if ordered {
            let keys = try connection.query(SQL("SELECT CAST(rid AS VARCHAR) FROM scan_order WHERE rowid >= \(max(0, offset)) AND rowid < \(max(0, offset) + max(0, limit)) ORDER BY rowid"))
            let ids = keys.columns.first?.compactMap { $0.flatMap(Int64.init) } ?? []
            guard let low = ids.min(), let high = ids.max() else { return RowPage(offset:offset,columns:activeState.columns.map { _ in [] }) }
            let rid = "s." + Planner.identifier(rowID)
            let fetched = try connection.query(SQL("SELECT CAST(\(rid) AS VARCHAR), \(projection) FROM \(source) s WHERE \(rid) BETWEEN \(low) AND \(high) AND \(rid) IN (\(ids.map(String.init).joined(separator:",")))"))
            var positions: [Int64:Int] = [:]
            for index in 0..<fetched.count { if let value = fetched.columns[0][index].flatMap(Int64.init) { positions[value] = index } }
            let result = fetched.columns.dropFirst().map { column in ids.map { id in positions[id].flatMap { column[$0] } } }
            return RowPage(offset:offset,columns:result)
        } else if hasRowID && activeState.filter.isEmpty {
            sql = "SELECT \(projection) FROM \(source) s WHERE s.\(Planner.identifier(rowID)) >= \(max(0, offset)) AND s.\(Planner.identifier(rowID)) < \(max(0, offset) + max(0, limit))"
        } else { sql = "SELECT \(projection) FROM \(source) s\(try whereClause(activeState)) LIMIT \(max(0, limit)) OFFSET \(max(0, offset))" }
        let result = try connection.query(SQL(sql))
        return RowPage(offset: offset, columns: result.columns)
    }
    public func preview(limit: Int = 500) throws -> RowPage { try page(offset: 0, limit: limit, generation: generation) }
    public func validate(filter: String) throws {
        try Planner.validateFilter(filter)
        _ = try connection.query(SQL("SELECT CAST(1 AS VARCHAR) FROM \(source) WHERE (\(filter.isEmpty ? "true" : filter)) LIMIT 0"))
    }
    public func ask(_ generatedSQL: String) throws -> AskResult {
        let sql = try AskQuery.validate(generatedSQL)
        // Validate the parsed statement too; token checks alone cannot establish
        // that an LLM-generated statement is read-only.
        _ = try connection.query(SQL("SELECT * FROM (\(sql)) AS check_result LIMIT 0"), onlySelect: true)
        let columns = try describe("(\(sql))")
        guard !columns.isEmpty else { throw EngineError("The query returned no columns.") }
        let projection = columns.map { "left(CAST(\(Planner.identifier($0.name)) AS VARCHAR), 300) AS \(Planner.identifier($0.name))" }.joined(separator:", ")
        let page = try connection.query(SQL("SELECT \(projection) FROM (\(sql)) AS ask_result LIMIT 200"), onlySelect:true)
        return AskResult(columns:columns,page:page)
    }
    public func pivot(state: ViewState, path: [String?] = []) throws -> [PivotNode] {
        guard path.count < state.groups.count else { return [] }
        let key = state.groups[path.count]
        let c = Planner.identifier(key)
        var predicates: [String] = []; var parameters: [String?] = []
        if !state.filter.isEmpty { try Planner.validateFilter(state.filter); predicates.append("(\(state.filter))") }
        for (i, value) in path.enumerated() { predicates.append("CAST(\(Planner.identifier(state.groups[i])) AS VARCHAR) IS NOT DISTINCT FROM ?"); parameters.append(value) }
        let aggregates = state.columns.map { col -> String in
            if col.name == key { return "CAST(\(c) AS VARCHAR)" }
            let op = state.aggregates[col.name] ?? (col.kind == .number ? .sum : .count)
            return "CAST(\(Planner.aggregate(op, column: col.name)) AS VARCHAR)"
        }
        let whereSQL = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let sql = "SELECT CAST(\(c) AS VARCHAR), \((aggregates + ["CAST(count(*) AS VARCHAR)"]).joined(separator: ", ")) FROM \(source)\(whereSQL) GROUP BY \(c) ORDER BY \(c) NULLS LAST LIMIT 10001"
        let result = try connection.query(SQL(sql, parameters))
        guard result.count <= 10000 else { throw EngineError("This pivot has more than 10,000 groups at one level. Filter the data before expanding it.") }
        return (0..<result.count).map { i in PivotNode(path: path + [result.columns[0][i]], values: Array(result.row(i).dropFirst())) }
    }
    public func export(to url: URL, state: ViewState) throws {
        guard url.standardizedFileURL != sourceURL?.standardizedFileURL, !FileManager.default.fileExists(atPath: url.path) else { throw EngineError("Choose a new file. Scan never overwrites existing files.") }
        let projection: String
        let group: String
        if state.groups.isEmpty { projection = state.columns.map { Planner.identifier($0.name) }.joined(separator: ", "); group = "" }
        else {
            projection = (state.groups.map(Planner.identifier) + state.columns.filter { !state.groups.contains($0.name) }.map { "\(Planner.aggregate(state.aggregates[$0.name] ?? ($0.kind == .number ? .sum : .count), column: $0.name)) AS \(Planner.identifier($0.name))" } + ["count(*) AS Rec"]).joined(separator: ", ")
            group = " GROUP BY " + state.groups.map(Planner.identifier).joined(separator: ", ")
        }
        let query = "SELECT \(projection) FROM \(source)\(try whereClause(state))\(group)\(state.groups.isEmpty ? Planner.order(state.sorts) : "")"
        try connection.execute("COPY (\(query)) TO \(Planner.literal(url.path)) (FORMAT \(url.pathExtension.lowercased() == "parquet" ? "PARQUET" : "CSV, HEADER true"))")
    }
    private func sqliteOpen(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw EngineError("Could not open SQLite database read-only.")
        }; return db
    }
    private func sqliteTables(_ url: URL) throws -> [String] {
        let db = try sqliteOpen(url); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &statement, nil) == SQLITE_OK else { throw EngineError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }; var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }; return names
    }
    private func importSQLite(_ url: URL, table: String, limit: Int? = nil) throws {
        let db = try sqliteOpen(url); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(Planner.identifier(table))\(limit.map { " LIMIT \(max(0,$0))" } ?? "")", -1, &statement, nil) == SQLITE_OK else { throw EngineError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let n = sqlite3_column_count(statement)
        let fields = (0..<n).map { i -> String in
            let name = String(cString: sqlite3_column_name(statement, i))
            let type = sqlite3_column_decltype(statement, i).map { String(cString: $0).uppercased() } ?? "TEXT"
            let mapped = type.contains("INT") ? "BIGINT" : (["REAL", "FLOAT", "DOUBLE", "NUMERIC", "DECIMAL"].contains(where: type.contains) ? "DOUBLE" : "VARCHAR")
            return Planner.identifier(name) + " " + mapped
        }
        try connection.execute("CREATE OR REPLACE TABLE sqlite_data (\(fields.joined(separator: ", ")))")
        try connection.execute("BEGIN")
        do {
            var batch: [[String?]] = []
            func flush() throws {
                guard !batch.isEmpty else { return }
                let row = "(" + Array(repeating: "?", count: Int(n)).joined(separator: ",") + ")"
                try connection.execute("INSERT INTO sqlite_data VALUES " + Array(repeating: row, count: batch.count).joined(separator: ","), batch.flatMap { $0 })
                batch.removeAll(keepingCapacity: true)
            }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                batch.append((0..<n).map { i in sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_text(statement, i).map { String(cString: $0) } })
                if batch.count == 256 { try flush() }; status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw EngineError(String(cString: sqlite3_errmsg(db))) }
            try flush(); try connection.execute("COMMIT")
        } catch { try? connection.execute("ROLLBACK"); throw error }
    }
}
