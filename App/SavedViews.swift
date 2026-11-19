import Foundation
import CryptoKit
import ScanQuery

/// What Scan remembers about how a file was last viewed: its filter, sorts, column order and
/// visibility, column widths and heatmaps. Pivots are not kept.
struct SavedView: Codable, Equatable {
    struct Sort: Codable, Equatable { var column: String; var ascending: Bool }
    var filter = ""
    var sorts: [Sort] = []
    /// Visible columns in display order.
    var columns: [String] = []
    /// Columns the user hid, so a column added to the file later still shows.
    var hidden: [String] = []
    var widths: [String: Double] = [:]
    var heat: [String] = []

    /// This view applied to a freshly opened file. Names the file no longer has are dropped.
    func state(schema: [Column]) -> ViewState {
        var state = ViewState()
        let byName = Dictionary(schema.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var columns = self.columns.compactMap { byName[$0] }
        let listed = Set(self.columns).union(hidden)
        columns += schema.filter { !listed.contains($0.name) }
        state.columns = columns.isEmpty ? schema : columns
        state.sorts = sorts.filter { byName[$0.column] != nil }.map { SortKey($0.column, ascending: $0.ascending) }
        state.filter = filter
        return state
    }

    init() {}
    init(state: ViewState, schema: [Column], widths: [String: Double], heat: Set<String>) {
        filter = state.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        sorts = state.sorts.map { Sort(column: $0.column, ascending: $0.ascending) }
        let visible = Set(state.columns.map(\.name))
        // An unchanged column set is stored as nothing, so new columns in the file keep showing.
        if state.columns.map(\.name) != schema.map(\.name) {
            columns = state.columns.map(\.name)
            hidden = schema.map(\.name).filter { !visible.contains($0) }
        }
        self.widths = widths
        self.heat = heat.sorted()
    }

    var isEmpty: Bool { self == SavedView() }
}

/// Saved views, one JSON file per file (and table) in Application Support.
enum ViewStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Scan/Views", isDirectory: true)
    }
    private static func file(_ url: URL, table: String) -> URL {
        let identity = (url.isFileURL ? url.standardizedFileURL.path : url.absoluteString) + "\n" + table
        let name = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    static func load(_ url: URL, table: String) -> SavedView? {
        guard let data = try? Data(contentsOf: file(url, table: table)) else { return nil }
        return try? JSONDecoder().decode(SavedView.self, from: data)
    }
    static func save(_ view: SavedView, for url: URL, table: String) {
        let target = file(url, table: table)
        if view.isEmpty { try? FileManager.default.removeItem(at: target); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(view).write(to: target, options: .atomic)
    }
}
