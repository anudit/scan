import SwiftUI
import Observation
import ScanEngine
import ScanQuery
import ScanGrid
import ScanTheme

@MainActor @Observable final class DocumentModel: Identifiable {
    let id = UUID()
    let url: URL
    var title: String { url.lastPathComponent }
    var schema: [Column] = []
    var tables: [String] = []
    var selectedTable = ""
    var state = ViewState()
    var rowCount = 0
    var busy = false
    var error: String?
    var status = "Opening…"
    var elapsedMS = 0.0
    var filterDraft = ""
    var filterError: String?
    var selectedCell = ""
    var selectedColumn = ""
    var inspector = false
    var inspectorTab = "Cell"
    var generation = 0
    var pivotRoots: [PivotNode] = []
    var pivotRows: [PivotNode] { pivotRoots.flatMap(\.flattened) }
    @ObservationIgnored var engine: Engine?
    @ObservationIgnored let cache = PageCache()
    @ObservationIgnored weak var grid: ScanGrid?
    @ObservationIgnored private var pending: [Int: Task<Void,Never>] = [:]
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var validation: Task<Void,Never>?
    @ObservationIgnored private var selectionTask: Task<Void,Never>?
    @ObservationIgnored var selectedRow = 0
    @ObservationIgnored var selectedIndex = 0
    @ObservationIgnored private var scope = false
    init(url: URL) { self.url = url; scope = url.startAccessingSecurityScopedResource() }
    func close() { cancel(); if scope { url.stopAccessingSecurityScopedResource(); scope = false }; engine = nil }
    func cancel() { work?.cancel(); validation?.cancel(); selectionTask?.cancel(); pending.values.forEach { $0.cancel() }; pending.removeAll(); engine?.cancel(); busy = false }
    func open(table: String? = nil) {
        cancel(); busy = true; error = nil; status = "Opening…"; cache.removeAll(); generation += 1
        let token = generation
        work = Task {
            do {
                let start = ContinuousClock.now
                let engine: Engine
                if table != nil, let existing = self.engine { engine = existing }
                else { engine = try Engine(memoryMB: max(64, UserDefaults.standard.integer(forKey: "memoryMB") == 0 ? 512 : UserDefaults.standard.integer(forKey: "memoryMB")), threads: 4); self.engine = engine }
                let info = try await engine.open(url, table: table)
                guard token == generation, !Task.isCancelled else { return }
                schema = info.columns; tables = info.tables; selectedTable = table ?? info.tables.first ?? ""
                state = ViewState(); state.columns = schema; filterDraft = ""
                let first = try await engine.preview(limit: 256)
                guard token == generation, !Task.isCancelled else { return }
                cache.insert(first,index:0); rowCount = first.count; grid?.refresh()
                elapsedMS = Double(start.duration(to: .now).components.attoseconds) / 1e15 + Double(start.duration(to: .now).components.seconds)*1000
                status = "\(info.format) · \(Int(elapsedMS)) ms to first page"
                if info.needsImport { status = "Indexing CSV…"; try await engine.materialize() }
                let count = try await engine.apply(state,generation:token)
                guard token == generation, !Task.isCancelled else { return }
                rowCount = count; busy = false; status = info.format.uppercased(); NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch { if token == generation && !Task.isCancelled { self.error = error.localizedDescription; busy = false; status = "Could not open file" } }
        }
    }
    func reload() {
        cancel(); generation += 1; let token = generation
        busy = true; error = nil
        let snapshot = state
        work = Task {
            do {
                guard let engine else { return }
                let start = ContinuousClock.now
                if !snapshot.groups.isEmpty {
                    let roots = try await engine.pivot(state:snapshot)
                    guard token == generation, !Task.isCancelled else { return }
                    pivotRoots = roots; rowCount = pivotRows.count; cache.removeAll(); rebuildPivotCache()
                } else {
                    let count = try await engine.apply(snapshot,generation:token)
                    let first = try await engine.page(offset:0,generation:token)
                    guard token == generation, !Task.isCancelled else { return }
                    pivotRoots = []; rowCount = count; cache.removeAll(); cache.insert(first,index:0)
                }
                let duration = start.duration(to:.now); elapsedMS = Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15
                status = "\(Int(elapsedMS)) ms"; busy = false; grid?.refresh()
            } catch { if token == generation && !Task.isCancelled { self.error = error.localizedDescription; busy = false } }
        }
    }
    func request(_ index: Int) {
        guard state.groups.isEmpty, pending[index] == nil, cache.page(index) == nil, !busy else { return }
        let token = generation
        pending[index] = Task {
            defer { pending[index] = nil }
            do {
                guard let engine else { return }
                let page = try await engine.page(offset:index*256,generation:token)
                guard !Task.isCancelled, token == generation else { return }
                cache.insert(page,index:index); grid?.refresh()
            } catch { if !Task.isCancelled && token == generation && !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func validateFilter() {
        validation?.cancel(); let text = filterDraft
        validation = Task { try? await Task.sleep(for:.milliseconds(300)); guard !Task.isCancelled else { return }
            do { try await engine?.validate(filter:text); if !Task.isCancelled { filterError = nil } }
            catch { if !Task.isCancelled { filterError = error.localizedDescription } }
        }
    }
    func applyFilter() { guard filterError == nil else { return }; state.filter = filterDraft; reload() }
    func sort(_ index: Int, add: Bool) {
        guard state.columns.indices.contains(index) else { return }; let name = state.columns[index].name
        let existing = state.sorts.first { $0.column == name }
        if !add { state.sorts.removeAll() } else { state.sorts.removeAll { $0.column == name } }
        if existing?.ascending != false { state.sorts.append(SortKey(name,ascending:existing == nil)) }
        reload()
    }
    func hide(_ column: Column) { guard state.columns.count > 1 else { return }; state.columns.removeAll { $0.id == column.id }; reload() }
    func show(_ column: Column) { if !state.columns.contains(column) { state.columns.append(column); reload() } }
    func group(_ column: Column) { if !state.groups.contains(column.name) { state.groups.append(column.name) }; inspector = true; inspectorTab = "Pivot"; reload() }
    func select(row: Int, column: Int) {
        selectedRow = row; selectedIndex = column
        if inspector && inspectorTab == "Cell" { fetchCell() }
    }
    func fetchCell() {
        selectionTask?.cancel(); let row = selectedRow, col = selectedIndex, token = generation
        guard state.columns.indices.contains(col) else { return }
        selectedColumn = state.columns[col].name; selectedCell = "Loading…"
        if !state.groups.isEmpty { let rows = pivotRows; if rows.indices.contains(row) { selectedCell = rows[row].values[col] ?? "NULL" }; return }
        selectionTask = Task {
            do {
                let page = try await engine?.page(offset:row,limit:1,generation:token,full:true)
                guard !Task.isCancelled, token == generation else { return }
                let value = page?.columns[col].first ?? nil
                if let value, let data = value.data(using:.utf8), let json = try? JSONSerialization.jsonObject(with:data), let pretty = try? JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]), let string = String(data:pretty,encoding:.utf8) { selectedCell = string }
                else { selectedCell = value ?? "NULL" }
            } catch { if !Task.isCancelled { selectedCell = error.localizedDescription } }
        }
    }
    func inspect() { inspector = true; inspectorTab = "Cell"; fetchCell() }
    func copy(rows: ClosedRange<Int>, columns: ClosedRange<Int>, csv: Bool) {
        if rows.count * columns.count > 100_000 {
            let alert = NSAlert(); alert.messageText = "Copy \(rows.count.formatted()) rows?"; alert.informativeText = "The clipboard will contain the full values and may use significant memory."; alert.addButton(withTitle:"Copy"); alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let token = generation
        Task {
            do {
                var values: [[String?]] = csv ? [columns.map { state.columns.indices.contains($0) ? state.columns[$0].name : "Rec" }] : []
                if !state.groups.isEmpty { let nodes = pivotRows; values += rows.compactMap { nodes.indices.contains($0) ? Array(nodes[$0].values[columns]) : nil } }
                else {
                    for offset in stride(from:rows.lowerBound,through:rows.upperBound,by:256) {
                        guard let page = try await engine?.page(offset:offset,limit:min(256,rows.upperBound-offset+1),generation:token,full:true), token == generation else { return }
                        values += (0..<page.count).map { Array(page.row($0)[columns]) }
                    }
                }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Planner.csv(values,separator:csv ? "," : "\t"),forType:.string)
            } catch { self.error = error.localizedDescription }
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-view.csv"; panel.title = "Export view as a new CSV or Parquet file"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; let snapshot = state
        work = Task { do { try await engine?.export(to:destination,state:snapshot); status = "Exported \(destination.lastPathComponent)" } catch { self.error = error.localizedDescription }; busy = false }
    }
    func togglePivot(_ row: Int) {
        let flat = pivotRows; guard flat.indices.contains(row) else { return }; let node = flat[row]
        if node.expanded { updateNode(node.id) { $0.expanded = false }; rebuildPivotCache(); return }
        guard node.path.count < state.groups.count else { return }
        let snapshot = state, token = generation
        Task {
            do {
                let children = try await engine?.pivot(state:snapshot,path:node.path) ?? []
                guard token == generation else { return }
                updateNode(node.id) { $0.children = children; $0.expanded = true }; rebuildPivotCache()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func updateNode(_ id: UUID, change: (inout PivotNode)->Void) {
        func visit(_ nodes: inout [PivotNode]) {
            for i in nodes.indices { if nodes[i].id == id { change(&nodes[i]); return }; if nodes[i].children != nil { visit(&nodes[i].children!) } }
        }; visit(&pivotRoots)
    }
    private func rebuildPivotCache() {
        cache.removeAll(); let rows = pivotRows; rowCount = rows.count
        for offset in stride(from:0,to:rows.count,by:256) {
            let slice = rows[offset..<min(rows.count,offset+256)]
            let cols = (0...state.columns.count).map { index in slice.map { $0.values[index] } }
            cache.insert(RowPage(offset:offset,columns:cols),index:offset/256)
        }; grid?.refresh()
    }
    func gridData() -> GridData {
        let data = GridData(); data.columns = state.columns + (state.groups.isEmpty ? [] : [Column("Rec","BIGINT")]); data.rowCount = rowCount; data.generation = generation
        let height = UserDefaults.standard.double(forKey:"rowHeight"); data.rowHeight = height == 0 ? 28 : height
        data.page = { [weak self] in self?.cache.page($0) }
        data.request = { [weak self] in self?.request($0) }
        data.sort = { [weak self] in self?.sort($0,add:$1) }
        data.select = { [weak self] in self?.select(row:$0,column:$1) }
        data.inspect = { [weak self] in self?.inspect() }
        data.copy = { [weak self] in self?.copy(rows:$0,columns:$1,csv:$2) }
        let nodes = pivotRows
        data.pivot = { row in guard nodes.indices.contains(row) else { return nil }; let node = nodes[row]; return (node.path.count-1,node.expanded,node.path.last.flatMap { $0 } ?? "NULL") }
        data.togglePivot = { [weak self] in self?.togglePivot($0) }
        data.onFirstPaint = {
            if ProcessInfo.processInfo.environment["SCAN_BENCHMARK"] == "1" {
                FileHandle.standardOutput.write(Data("SCAN_FIRST_ROWS\n".utf8))
            }
        }
        return data
    }
}

struct GridBridge: NSViewRepresentable {
    let model: DocumentModel
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScanGrid, context: Context) -> CGSize? { CGSize(width:proposal.width ?? 800,height:proposal.height ?? 500) }
    func makeNSView(context: Context) -> ScanGrid { let grid = ScanGrid(); model.grid = grid; grid.update(model.gridData()); return grid }
    func updateNSView(_ nsView: ScanGrid, context: Context) { nsView.update(model.gridData()); model.grid = nsView }
}
