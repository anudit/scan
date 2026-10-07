import SwiftUI
import UniformTypeIdentifiers
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
    /// The selected cell parsed as JSON, when it holds an object or array.
    var selectedJSON: JSONValue?
    /// Changes with every new cell value, so the JSON tree resets its expansion.
    var cellRevision = 0
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
    @ObservationIgnored private var queued: Set<Int> = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var validation: Task<Void,Never>?
    @ObservationIgnored private var selectionTask: Task<Void,Never>?
    @ObservationIgnored var selectedRow = 0
    @ObservationIgnored var selectedIndex = 0
    @ObservationIgnored private var scope = false
    @ObservationIgnored private var appliedState = ViewState()
    @ObservationIgnored private var initialMemoryMB = 512
    init(url: URL) { self.url = url; scope = url.startAccessingSecurityScopedResource() }
    func close() { cancel(); if scope { url.stopAccessingSecurityScopedResource(); scope = false }; engine = nil }
    func cancel() { work?.cancel(); validation?.cancel(); selectionTask?.cancel(); pending.values.forEach { $0.cancel() }; pending.removeAll(); queued.removeAll(); engine?.cancel(); busy = false }
    func open(table: String? = nil) {
        cancel(); busy = true; error = nil; status = "Opening…"; cache.removeAll(); generation += 1
        let token = generation
        work = Task {
            do {
                let start = ContinuousClock.now
                let engine: Engine
                if table != nil, let existing = self.engine { engine = existing }
                else {
                    initialMemoryMB = max(64,UserDefaults.standard.integer(forKey:"memoryMB") == 0 ? 512 : UserDefaults.standard.integer(forKey:"memoryMB"))
                    engine = try Engine(memoryMB:initialMemoryMB,threads:4); self.engine = engine
                }
                let info = try await engine.open(url, table: table)
                guard token == generation, !Task.isCancelled else { return }
                schema = info.columns; tables = info.tables; selectedTable = table ?? info.tables.first ?? ""
                state = ViewState(); state.columns = schema; filterDraft = ""
                let first = try await engine.preview(limit: 256)
                guard token == generation, !Task.isCancelled else { return }
                cache.insert(first,index:0); rowCount = first.count; grid?.refresh()
                elapsedMS = Double(start.duration(to: .now).components.attoseconds) / 1e15 + Double(start.duration(to: .now).components.seconds)*1000
                status = "\(info.format) · \(Int(elapsedMS)) ms to first page"
                if info.needsImport { status = "Indexing…"; try await engine.materialize() }
                let count = try await engine.apply(state,generation:token)
                let memoryMB = await engine.memoryLimitMB
                guard token == generation, !Task.isCancelled else { return }
                appliedState = state; rowCount = count; busy = false; status = budgetStatus(info.format.uppercased(),memoryMB:memoryMB); NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch { if token == generation && !Task.isCancelled { self.error = error.localizedDescription; busy = false; status = "Could not open file" } }
        }
    }
    func reload() {
        cancel(); generation += 1; let token = generation; selectedRow = 0
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
                let memoryMB = await engine.memoryLimitMB
                guard token == generation, !Task.isCancelled else { return }
                appliedState = snapshot; status = budgetStatus("\(Int(elapsedMS)) ms",memoryMB:memoryMB); busy = false; grid?.refresh()
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                let message = error.localizedDescription
                // Keep the previous view pageable if a new filter/sort fails.
                if let engine {
                    do {
                        _ = try await engine.apply(appliedState,generation:token)
                        guard token == generation, !Task.isCancelled else { return }
                        state = appliedState
                    } catch {}
                }
                guard token == generation, !Task.isCancelled else { return }
                self.error = message; busy = false; grid?.refresh()
            }
        }
    }
    /// Requests made during one draw are coalesced, so a jump loads its visible pages in a single scan.
    func request(_ index: Int) {
        guard state.groups.isEmpty, pending[index] == nil, cache.page(index)?.isComplete != true, !busy else { return }
        queued.insert(index)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushRequests() }
    }
    private func flushRequests() {
        flushScheduled = false
        var runs: [ClosedRange<Int>] = []
        for index in queued.sorted() where pending[index] == nil {
            if let last = runs.last, last.upperBound + 1 == index { runs[runs.count - 1] = last.lowerBound...index } else { runs.append(index...index) }
        }
        queued.removeAll()
        runs.forEach(load)
    }
    private func load(_ run: ClosedRange<Int>) {
        let token = generation, names = Set(state.columns.map(\.name))
        let heavy = Set(state.columns.filter(\.isHeavy).map(\.name)), light = names.subtracting(heavy)
        // Pages that already hold the light columns only need the heavy ones.
        let partial = run.allSatisfy { cache.page($0) != nil }
        let task = Task {
            do {
                guard let engine else { return }
                let offset = run.lowerBound * 256, limit = run.count * 256
                if heavy.isEmpty || light.isEmpty {
                    let page = try await engine.page(offset:offset,limit:limit,generation:token)
                    guard !Task.isCancelled, token == generation else { return }
                    store(page, run: run)
                } else {
                    if !partial {
                        let first = try await engine.page(offset:offset,limit:limit,generation:token,only:light)
                        guard !Task.isCancelled, token == generation else { return }
                        store(first, run: run)
                    }
                    let rest = try await engine.page(offset:offset,limit:limit,generation:token,only:heavy)
                    guard !Task.isCancelled, token == generation else { return }
                    store(rest, run: run)
                }
                let memoryMB = await engine.memoryLimitMB
                if token == generation, !Task.isCancelled, memoryMB > initialMemoryMB {
                    status = budgetStatus(url.pathExtension.uppercased(),memoryMB:memoryMB)
                }
            } catch { if !Task.isCancelled && token == generation && !(error is CancellationError) { self.error = error.localizedDescription } }
        }
        for index in run { pending[index] = task }
        Task { _ = await task.value; for index in run where pending[index] == task { pending[index] = nil } }
    }
    /// Splits a multi-page result into cached pages, filling in columns that earlier loads left empty.
    private func store(_ result: RowPage, run: ClosedRange<Int>) {
        for index in run {
            let start = (index - run.lowerBound) * 256
            let columns = result.columns.map { column in column.isEmpty ? [] : Array(column[min(start, column.count)..<min(start + 256, column.count)]) }
            let page = RowPage(offset: index * 256, columns: columns)
            cache.insert(cache.page(index).map { $0.merging(page) } ?? page, index: index)
        }
        grid?.refresh()
    }
    private func budgetStatus(_ text: String, memoryMB: Int) -> String {
        memoryMB > initialMemoryMB ? "\(text) · memory limit \(memoryMB.formatted()) MB" : text
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
        let column = state.columns[col]
        selectedColumn = column.name
        if !state.groups.isEmpty { let rows = pivotRows; if rows.indices.contains(row) { showCell(rows[row].values[col]) }; return }
        // Show the grid's value at once. Query only when the grid's display copy may be shortened.
        if let page = cache.page(row / 256), page.isLoaded(col), page.columns[col].indices.contains(row - page.offset) {
            let value = page.columns[col][row - page.offset]
            showCell(value)
            if !column.isHeavy, (value?.unicodeScalars.count ?? 0) < Planner.displayLimit { return }
        } else { showCell("Loading…") }
        selectionTask = Task {
            do {
                let value = try await engine?.cell(row:row,column:column.name,generation:token)
                guard !Task.isCancelled, token == generation else { return }
                showCell(value)
            } catch { if !Task.isCancelled && !(error is CancellationError) { showCell(error.localizedDescription) } }
        }
    }
    private func showCell(_ value: String?) {
        selectedJSON = value.flatMap(JSONValue.init(parsing:))
        selectedCell = selectedJSON?.pretty() ?? value ?? "NULL"
        cellRevision += 1
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
        let base = url.lastPathComponent.components(separatedBy:".").first ?? "export"
        guard let destination = ExportPanel.run(name: base + "-view") else { return }
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
        let data = GridData(); data.columns = state.columns + (state.groups.isEmpty ? [] : [Column("Rec","BIGINT")]); data.rowCount = rowCount; data.generation = generation; data.sorts = state.groups.isEmpty ? state.sorts : []
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

/// A save panel with a Format pop-up. Choosing a format rewrites the file name's extension.
@MainActor final class ExportPanel: NSObject {
    private let panel = NSSavePanel()
    private let popup = NSPopUpButton()
    static func run(name: String) -> URL? {
        let helper = ExportPanel()
        let stored = UserDefaults.standard.string(forKey:"exportFormat").flatMap(ExportFormat.init(rawValue:)) ?? .csv
        helper.panel.title = "Export View"; helper.panel.message = "Export the current filtered and sorted view as a new file."
        helper.popup.addItems(withTitles: ExportFormat.allCases.map(\.title))
        helper.popup.selectItem(at: ExportFormat.allCases.firstIndex(of: stored) ?? 0)
        helper.popup.target = helper; helper.popup.action = #selector(formatChanged)
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, helper.popup]); stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        helper.panel.accessoryView = stack
        helper.panel.nameFieldStringValue = name + "." + stored.rawValue
        helper.apply(stored)
        guard helper.panel.runModal() == .OK, let url = helper.panel.url else { return nil }
        UserDefaults.standard.set(helper.format.rawValue, forKey:"exportFormat")
        return url
    }
    private var format: ExportFormat { ExportFormat.allCases[max(0, popup.indexOfSelectedItem)] }
    private func apply(_ format: ExportFormat) {
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = stem + "." + format.rawValue
    }
    @objc private func formatChanged() { apply(format) }
}
