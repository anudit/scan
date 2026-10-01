import Foundation
import CDuckDB
import ScanQuery

public struct EngineError: Error, LocalizedError, Sendable {
    public let message: String
    let outOfMemory: Bool
    public init(_ message: String) { self.message = message; outOfMemory = false }
    init(_ message: String, outOfMemory: Bool) { self.message = message; self.outOfMemory = outOfMemory }
    public var errorDescription: String? { message }
}
// Only Engine's serial actor executes queries. DuckDB explicitly allows interrupt from another thread.
final class Connection: @unchecked Sendable {
    private var database: duckdb_database?
    private var handle: duckdb_connection?
    private let lock = NSLock()
    private var budget: QueryBudget
    var memoryMB: Int { budget.memoryMB }
    let directory: URL
    init(memoryMB: Int, threads: Int) throws {
        budget = QueryBudget(memoryMB:memoryMB,threads:threads)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config: duckdb_config?
        duckdb_create_config(&config)
        defer { duckdb_destroy_config(&config) }
        duckdb_set_config(config, "memory_limit", "\(budget.memoryMB)MB")
        duckdb_set_config(config, "threads", "\(budget.threads)")
        duckdb_set_config(config, "autoload_known_extensions", "false")
        duckdb_set_config(config, "autoinstall_known_extensions", "false")
        duckdb_set_config(config, "temp_directory", directory.appendingPathComponent("spill").path)
        var error: UnsafeMutablePointer<CChar>?
        guard duckdb_open_ext(directory.appendingPathComponent("cache.duckdb").path, &database, config, &error) == DuckDBSuccess else {
            let message = error.map { String(cString: $0) } ?? "Could not initialize DuckDB"
            duckdb_free(error); throw EngineError(message)
        }
        guard duckdb_connect(database, &handle) == DuckDBSuccess else { duckdb_close(&database); throw EngineError("Could not connect to DuckDB") }
    }
    deinit { lock.lock(); duckdb_disconnect(&handle); duckdb_close(&database); lock.unlock(); try? FileManager.default.removeItem(at: directory) }
    func cancel() { lock.lock(); defer { lock.unlock() }; if let handle { duckdb_interrupt(handle) } }
    func query(_ sql: SQL, onlySelect: Bool = false, retryOnOOM: Bool = true) throws -> RowPage {
        while true {
            do { return try queryOnce(sql,onlySelect:onlySelect) }
            catch let error as EngineError {
                guard retryOnOOM, error.outOfMemory else { throw error }
                var next = budget
                guard next.recover() else { throw error }
                try execute("SET threads=\(next.threads)")
                try execute("SET memory_limit='\(next.memoryMB)MB'")
                budget = next
            }
        }
    }
    private func queryOnce(_ sql: SQL, onlySelect: Bool) throws -> RowPage {
        var statement: duckdb_prepared_statement?
        guard duckdb_prepare(handle, sql.text, &statement) == DuckDBSuccess else {
            let error = duckdb_prepare_error(statement).map { String(cString: $0) } ?? "Invalid query"
            duckdb_destroy_prepare(&statement); throw EngineError(error,outOfMemory:error.hasPrefix("Out of Memory Error"))
        }
        defer { duckdb_destroy_prepare(&statement) }
        if onlySelect && duckdb_prepared_statement_type(statement) != DUCKDB_STATEMENT_TYPE_SELECT {
            throw EngineError("Ask can run SELECT queries only.")
        }
        for (index, value) in sql.parameters.enumerated() {
            let status = value.map { duckdb_bind_varchar(statement, UInt64(index + 1), $0) } ?? duckdb_bind_null(statement, UInt64(index + 1))
            if status != DuckDBSuccess { throw EngineError("Could not bind query parameter") }
        }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_execute_prepared(statement, &result) == DuckDBSuccess else {
            throw EngineError(duckdb_result_error(&result).map { String(cString:$0) } ?? "Query failed",outOfMemory:duckdb_result_error_type(&result) == DUCKDB_ERROR_OUT_OF_MEMORY)
        }
        let count = Int(duckdb_column_count(&result))
        var columns = Array(repeating: [String?](), count: count)
        // UI SELECTs cast values to VARCHAR. Chunk vectors avoid the legacy per-cell value API.
        while let fetched = duckdb_fetch_chunk(result) {
            var chunk: duckdb_data_chunk? = fetched
            defer { duckdb_destroy_data_chunk(&chunk) }
            let rows = Int(duckdb_data_chunk_get_size(chunk))
            for col in 0..<count {
                let vector = duckdb_data_chunk_get_vector(chunk, UInt64(col))
                let validity = duckdb_vector_get_validity(vector)
                var type = duckdb_vector_get_column_type(vector)
                let typeID = duckdb_get_type_id(type)
                duckdb_destroy_logical_type(&type)
                guard let data = duckdb_vector_get_data(vector) else { continue }
                for row in 0..<rows {
                    if let validity, !duckdb_validity_row_is_valid(validity, UInt64(row)) { columns[col].append(nil); continue }
                    if typeID == DUCKDB_TYPE_VARCHAR {
                        var string = data.assumingMemoryBound(to: duckdb_string_t.self)[row]
                        let length = Int(duckdb_string_t_length(string))
                        let value = withUnsafeMutablePointer(to: &string) { p -> String in
                            guard let bytes = duckdb_string_t_data(p) else { return "" }
                            return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
                        }
                        columns[col].append(value)
                    } else if typeID == DUCKDB_TYPE_BIGINT { columns[col].append(String(data.assumingMemoryBound(to: Int64.self)[row])) }
                    else if typeID == DUCKDB_TYPE_BOOLEAN { columns[col].append(data.assumingMemoryBound(to: Bool.self)[row] ? "true" : "false") }
                    else { throw EngineError("Internal query returned an unconverted vector type: \(typeID)") }
                }
            }
        }
        return RowPage(offset: 0, columns: columns)
    }
    func execute(_ text: String, _ parameters: [String?] = [], retryOnOOM: Bool = false) throws { _ = try query(SQL(text, parameters),retryOnOOM:retryOnOOM) }
}
