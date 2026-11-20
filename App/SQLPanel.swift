import SwiftUI
import AppKit
import ScanEngine
import ScanQuery
import ScanTheme
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct GeneratedQuery {
    @Guide(description: "A complete DuckDB SELECT statement with FROM scan_data. Quote column names with double quotes and text values with single quotes. No Markdown, comments, or extra statements.")
    var sql: String
    @Guide(description: "One short sentence explaining what the query calculates.")
    var explanation: String
}

/// What the bottom panel's editor does with its text.
enum SQLMode: String, CaseIterable, Codable, Identifiable {
    case filter = "Filter", sql = "SQL", ask = "Ask"
    var id: String { rawValue }
    var icon: String { switch self { case .filter: "line.3.horizontal.decrease"; case .sql: "terminal"; case .ask: "sparkles" } }
    var placeholder: String {
        switch self {
        case .filter: "A WHERE expression, such as  num_likes > 100 AND is_pro"
        case .sql: "SELECT * FROM scan_data WHERE …"
        case .ask: "Ask in plain English, such as  count rows by country, highest first"
        }
    }
    var hint: String {
        switch self {
        case .filter: "Return filters the table above"
        case .sql: "⌘↵ runs a read-only SELECT against scan_data"
        case .ask: "Return writes a query and runs it"
        }
    }
}
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var mode: SQLMode
    var text: String
    var date = Date()
}

/// The state of the bottom panel: what was typed in each mode, the last result, and the history.
@MainActor @Observable final class SQLConsole {
    var mode: SQLMode = .filter
    var sql = ""
    var question = ""
    var result: AskResult?
    var explanation = ""
    var error: String?
    var working = false
    var phase = ""
    var elapsedMS: Double?
    var history: [HistoryEntry] = SQLConsole.loadHistory()
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var runningSQL = false

    private static let historyKey = "sqlHistory"
    private static let historyLimit = 200
    private static func loadHistory() -> [HistoryEntry] {
        UserDefaults.standard.data(forKey: historyKey).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }
    private func record(_ mode: SQLMode, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        history.removeAll { $0.mode == mode && $0.text == text }
        history.insert(HistoryEntry(mode: mode, text: text), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        saveHistory()
    }
    private func saveHistory() { UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: Self.historyKey) }
    func remove(_ entry: HistoryEntry) { history.removeAll { $0.id == entry.id }; saveHistory() }
    func clearHistory() { history = []; saveHistory() }
    /// Puts a history entry back in the editor of its mode.
    func restore(_ entry: HistoryEntry, in document: DocumentModel) {
        mode = entry.mode
        switch entry.mode {
        case .filter: document.filterDraft = entry.text; document.validateFilter()
        case .sql: sql = entry.text
        case .ask: question = entry.text
        }
    }

    static var askStatus: String {
        guard #available(macOS 26.0, *) else { return "Ask requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return "On-device Apple Intelligence"
        case .unavailable: return "Apple Intelligence is unavailable on this Mac or has not finished setting up."
        }
    }
    static var canAsk: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }
    var canRun: Bool {
        switch mode {
        case .filter: true
        case .sql: !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ask: Self.canAsk && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func run(_ document: DocumentModel) {
        guard !working else { return }
        switch mode {
        case .filter:
            guard document.filterError == nil else { return }
            record(.filter, document.filterDraft); error = nil
            document.applyFilter()
        case .sql: runSQL(sql, in: document)
        case .ask: ask(in: document)
        }
    }
    func cancel(_ document: DocumentModel? = nil) {
        task?.cancel(); task = nil
        if runningSQL { document?.engine?.cancel() }
        working = false; runningSQL = false
    }
    private func runSQL(_ text: String, in document: DocumentModel, remember: Bool = true) {
        guard !document.busy, let engine = document.engine else { error = "Wait for the file to finish opening."; return }
        working = true; runningSQL = true; phase = "Running query…"; error = nil; explanation = ""
        let start = ContinuousClock.now
        task = Task {
            defer { if !Task.isCancelled { working = false; runningSQL = false; task = nil } }
            do {
                let validated = try AskQuery.validate(text)
                let output = try await engine.ask(validated)
                try Task.checkCancellation()
                sql = validated; result = output
                let d = start.duration(to: .now); elapsedMS = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                if remember { record(.sql, validated) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; result = nil } }
        }
    }
    /// Turns the question into a query, runs it, and shows the query and its output in the SQL view.
    private func ask(in document: DocumentModel) {
        guard Self.canAsk, !document.busy, let engine = document.engine else { return }
        let input = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        working = true; error = nil; result = nil; explanation = ""; phase = "Writing a query…"
        record(.ask, input)
        let schema = document.schema.map { "\(Planner.identifier($0.name)) \($0.type)" }.joined(separator: ", ")
        let start = ContinuousClock.now
        task = Task {
            var written = ""
            defer { if !Task.isCancelled { working = false; runningSQL = false; task = nil } }
            do {
                guard #available(macOS 26.0, *) else { throw EngineError("Ask requires macOS 26 or later.") }
                let session = LanguageModelSession(instructions: """
                    Translate the user's question into one complete DuckDB SELECT query against scan_data.
                    Use only the supplied columns, with their exact names in double quotes. Use single quotes for text values.
                    Infer ordinary singular/plural references, such as titles meaning the title column.
                    For text matching, contains is a function, not an infix operator.
                    Example request: titles that include play.
                    Example SQL: SELECT "title" FROM scan_data WHERE contains(lower(CAST("title" AS VARCHAR)), 'play') LIMIT 200
                    Example request: how many rows?
                    Example SQL: SELECT count(*) AS rows FROM scan_data
                    Return matching rows unless the user explicitly asks for a count or summary.
                    For counts use count(*). For counts by a column, GROUP BY that column and ORDER BY the count DESC.
                    Use LIMIT 200 for row listings. Never invent columns, use other tables, read files, or modify data.
                    Do not return a WHERE expression by itself, Markdown, comments, or more than one statement.
                    """)
                var prompt = "Table: scan_data. Columns: \(schema). Question: \(input)"
                for attempt in 0..<2 {
                    let generated = try await session.respond(to: prompt, generating: GeneratedQuery.self).content
                    try Task.checkCancellation()
                    written = generated.sql; explanation = generated.explanation
                    do {
                        phase = "Running query…"
                        let validated = try AskQuery.validate(generated.sql)
                        written = validated; runningSQL = true
                        let output = try await engine.ask(validated)
                        runningSQL = false
                        try Task.checkCancellation()
                        // The query and its rows now live in the SQL view, ready to edit and run again.
                        sql = validated; result = output; mode = .sql
                        let d = start.duration(to: .now); elapsedMS = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                        record(.sql, validated)
                        return
                    } catch {
                        runningSQL = false
                        try Task.checkCancellation()
                        guard attempt == 0 else { throw error }
                        phase = "Refining the query…"
                        prompt = "The query failed: \(error.localizedDescription). Correct it to answer the original question using the exact supplied column names. Return a complete SELECT query from scan_data."
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.error = "Couldn’t answer that yet. \(error.localizedDescription)" + (written.isEmpty ? " Try a shorter question." : " The query it wrote is in the SQL view, ready to edit.")
                    if !written.isEmpty { sql = written; mode = .sql }
                }
            }
        }
    }
}

/// The interactive SQL view at the bottom of a document: filter, query or ask, with the output below.
struct SQLPanel: View {
    @Bindable var model: DocumentModel
    @Binding var focused: Bool
    @State private var historyShown = false
    @State private var runHover = false

    private var console: SQLConsole { model.console }
    private var text: Binding<String> {
        switch console.mode {
        case .filter: Binding(get: { model.filterDraft }, set: { model.filterDraft = $0 })
        case .sql: Binding(get: { console.sql }, set: { console.sql = $0 })
        case .ask: Binding(get: { console.question }, set: { console.question = $0 })
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color(nsColor: ScanTheme.line)).frame(height: 1)
            editor
            Rectangle().fill(Color(nsColor: ScanTheme.line)).frame(height: 1)
            output
        }
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: 10) {
            modePicker
            Spacer(minLength: 8)
            statusView
            Button { historyShown.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24)
            }
            .buttonStyle(HoverButtonStyle(active: historyShown)).help("History")
            .popover(isPresented: $historyShown, arrowEdge: .top) { SQLHistoryList(model: model, dismiss: { historyShown = false; focused = true }) }
            runButton
            Button { withAnimation(Motion.panel) { model.sqlOpen = false } } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }.buttonStyle(HoverButtonStyle()).help("Collapse (⌘J)")
        }
        .padding(.horizontal, 10).frame(height: 40)
    }
    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(SQLMode.allCases) { mode in
                let selected = console.mode == mode
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { console.mode = mode }; focused = true } label: {
                    Label(mode.rawValue, systemImage: mode.icon).labelStyle(.titleAndIcon)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color(nsColor: ScanTheme.accent) : Color.secondary)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background { if selected { Capsule().fill(Color(nsColor: ScanTheme.accent).opacity(0.14)) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(Capsule().fill(Color.primary.opacity(0.05)))
    }
    @ViewBuilder private var statusView: some View {
        if console.working {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(console.phase).font(.system(size: 11)).foregroundStyle(.secondary) }
                .transition(.opacity)
        } else if let result = console.result, console.mode == .sql {
            Text("\(result.page.count) row\(result.page.count == 1 ? "" : "s")" + (console.elapsedMS.map { " · \(Int($0)) ms" } ?? ""))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).transition(.opacity)
        }
    }
    private var runButton: some View {
        Button {
            if console.working { console.cancel(model) } else { console.run(model) }
        } label: {
            Label(console.working ? "Stop" : "Run", systemImage: console.working ? "stop.fill" : "play.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color(nsColor: ScanTheme.accent).opacity(runHover ? 0.24 : 0.14)))
                .overlay(Capsule().strokeBorder(Color(nsColor: ScanTheme.accent).opacity(runHover ? 0.55 : 0.3)))
                .foregroundStyle(Color(nsColor: ScanTheme.accent))
        }
        .buttonStyle(.plain).onHover { runHover = $0 }.animation(Motion.hover, value: runHover)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!console.working && !console.canRun).opacity(!console.working && !console.canRun ? 0.45 : 1)
        .help(console.working ? "Stop the query" : "Run (⌘↵)")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                SQLEditor(text: text, highlight: console.mode != .ask, focused: $focused,
                          // Filter and Ask are one-liners. SQL keeps Return for new lines and runs on ⌘↵.
                          onReturn: { guard console.mode != .sql else { return false }; console.run(model); return true },
                          onEscape: {
                              if console.mode == .filter { model.filterDraft = model.state.filter; model.validateFilter() }
                              focused = false; model.grid?.focus(row: model.selectedRow, column: model.selectedIndex)
                          })
                    .onChange(of: model.filterDraft) { if console.mode == .filter { model.validateFilter() } }
                if text.wrappedValue.isEmpty {
                    Text(console.mode.placeholder).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 15).padding(.vertical, 8).allowsHitTesting(false).lineLimit(1)
                }
            }
            .frame(height: 56)
            HStack(spacing: 8) {
                if console.mode == .filter, let message = model.filterError {
                    Image(systemName: "exclamationmark.circle.fill"); Text(message).lineLimit(1)
                }
                else if console.mode == .ask { Image(systemName: "cpu"); Text(SQLConsole.askStatus).lineLimit(1) }
                else { Text(console.mode.hint) }
                Spacer()
                if console.mode == .filter, !model.state.filter.isEmpty {
                    Button("Clear filter") { model.filterDraft = ""; model.state.filter = ""; model.reload() }.buttonStyle(.link)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(console.mode == .filter && model.filterError != nil || console.mode == .ask && !SQLConsole.canAsk ? Color(nsColor: ScanTheme.danger) : Color(nsColor: ScanTheme.muted))
            .padding(.horizontal, 12).padding(.bottom, 7)
        }
    }

    @ViewBuilder private var output: some View {
        if let error = console.error {
            ScrollView {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(Color(nsColor: ScanTheme.danger)).padding(12)
            }
        } else if let result = console.result, console.mode != .filter {
            VStack(alignment: .leading, spacing: 0) {
                if !console.explanation.isEmpty {
                    Text(console.explanation).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                }
                if result.page.count == 0 {
                    emptyState("No rows matched", "Try a broader condition.", icon: "tray")
                } else {
                    ResultTable(result: result)
                }
            }
        } else {
            switch console.mode {
            case .filter: suggestions(icon: "line.3.horizontal.decrease.circle", title: "Filter the table", detail: "A WHERE expression narrows the rows above. Click a cell to add one.", chips: filterChips)
            case .sql: suggestions(icon: "terminal", title: "Query this file", detail: "Results appear here. The table is called scan_data.", chips: sqlChips)
            case .ask: suggestions(icon: "sparkles", title: "Ask your data", detail: "The question becomes a query that you can read, edit and run again.", chips: askChips)
            }
        }
    }
    private var filterChips: [(String, () -> Void)] {
        guard let column = model.schema.first else { return [] }
        let name = Planner.identifier(column.name)
        return [("\(column.name) IS NOT NULL", { model.filterDraft = "\(name) IS NOT NULL"; model.validateFilter(); focused = true })]
    }
    private var sqlChips: [(String, () -> Void)] {
        var chips: [(String, () -> Void)] = [("Count rows", { console.sql = "SELECT count(*) AS rows FROM scan_data"; focused = true })]
        if let column = model.schema.first(where: { $0.kind == .text }) {
            let name = Planner.identifier(column.name)
            chips.append(("Top values of \(column.name)", { console.sql = "SELECT \(name), count(*) AS n FROM scan_data GROUP BY 1 ORDER BY n DESC LIMIT 50"; focused = true }))
        }
        return chips
    }
    private var askChips: [(String, () -> Void)] {
        var chips: [(String, () -> Void)] = [("How many rows?", { console.question = "How many rows are in this file?"; focused = true })]
        if let column = model.schema.first(where: { $0.kind == .text }) {
            chips.append(("Count rows by \(column.name)", { console.question = "Count rows by \(column.name), highest first"; focused = true }))
        }
        return chips
    }
    private func suggestions(icon: String, title: String, detail: String, chips: [(String, () -> Void)]) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(Color(nsColor: ScanTheme.accent).opacity(0.8))
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Button(action: chip.1) { Text(chip.0).font(.system(size: 11)).padding(.horizontal, 9).frame(height: 22).background(Capsule().fill(Color.primary.opacity(0.06))) }
                        .buttonStyle(.plain)
                }
            }.padding(.top, 2)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
    }
    private func emptyState(_ title: String, _ detail: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Past filters, queries and questions, newest first. Choosing one puts it back in the editor.
private struct SQLHistoryList: View {
    @Bindable var model: DocumentModel
    let dismiss: () -> Void
    @State private var search = ""
    private var entries: [HistoryEntry] {
        model.console.history.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.console.history.isEmpty { Button("Clear") { model.console.clearHistory() }.buttonStyle(.link).font(.system(size: 11)) }
            }
            SoftSearchField(prompt: "Search history", text: $search)
            if entries.isEmpty {
                Text(model.console.history.isEmpty ? "Filters, queries and questions you run appear here." : "Nothing matches.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry, remove: { model.console.remove(entry) }) { model.console.restore(entry, in: model); dismiss() }
                        }
                    }
                }.frame(maxHeight: 280).scrollIndicators(.never)
            }
        }.padding(14).frame(width: 380)
    }
}
private struct HistoryRow: View {
    let entry: HistoryEntry
    let remove: () -> Void
    let choose: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.mode.icon).font(.system(size: 10.5)).foregroundStyle(Color(nsColor: ScanTheme.accent)).frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).font(.system(size: 11.5, design: entry.mode == .ask ? .default : .monospaced)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(entry.date.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if hovering { Button(action: remove) { Image(systemName: "xmark") .font(.system(size: 9, weight: .semibold)) }.buttonStyle(HoverButtonStyle()).help("Remove") }
            }.rowHighlight()
            .padding(.vertical, 3)
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// A query's rows: a pinned header, row numbers, and values colored by type.
struct ResultTable: View {
    let result: AskResult
    @State private var available: CGFloat = 0
    /// Columns share the panel's width, and never get narrower than 150 points.
    private var columnWidth: CGFloat { max(150, (available - 64) / CGFloat(max(1, result.columns.count))) }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<result.page.count, id: \.self) { row in
                        HStack(spacing: 0) {
                            Text(String(row + 1)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(nsColor: ScanTheme.muted))
                                .frame(width: 44, alignment: .trailing).padding(.trailing, 10)
                            ForEach(result.columns.indices, id: \.self) { col in
                                let value = result.page.columns[col][row]
                                Text(value ?? "NULL").font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color(nsColor: ScanTheme.color(for: result.columns[col].kind, value: value)))
                                    .lineLimit(1).truncationMode(.tail).help(value ?? "NULL")
                                    .frame(width: columnWidth, alignment: .leading).padding(.horizontal, 8)
                            }
                        }
                        .frame(height: 26)
                        .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    }
                } header: {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 54)
                        ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(column.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                Text(column.type.lowercased()).font(.system(size: 9.5)).foregroundStyle(Color(nsColor: ScanTheme.muted)).lineLimit(1)
                            }.frame(width: columnWidth, alignment: .leading).padding(.horizontal, 8)
                        }
                    }
                    .frame(height: 34).background(Color(nsColor: ScanTheme.chrome))
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: ScanTheme.line)).frame(height: 1) }
                }
            }
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { available = proxy.size.width }.onChange(of: proxy.size.width) { available = proxy.size.width } })
    }
}
