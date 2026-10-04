import SwiftUI
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

struct AskView: View {
    @Bindable var document: DocumentModel
    @State private var question = ""
    @State private var generatedSQL = ""
    @State private var explanation = ""
    @State private var result: AskResult?
    @State private var working = false
    @State private var error: String?
    @State private var phase = ""
    @State private var editingSQL = false
    @State private var runningSQL = false
    @State private var queryTask: Task<Void,Never>?
    @FocusState private var questionFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var modelStatus: String {
        guard #available(macOS 26.0, *) else { return "Ask requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return "On-device Apple Intelligence"
        case .unavailable: return "Apple Intelligence is unavailable on this Mac or has not finished setting up."
        }
    }
    private var canAsk: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Image(systemName:"sparkles").foregroundStyle(Color(nsColor:ScanTheme.accent))
                Text("Ask your data").font(.system(size:20,weight:.semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain)
            }
            Text("Ask a question about this file. Search rows, count matches, or summarize your data. Everything runs locally on your Mac.")
                .font(.system(size:12)).foregroundStyle(.secondary)
            HStack(spacing:10) {
                TextField("For example: Count rows by country, highest first",text:$question)
                    .textFieldStyle(.roundedBorder).focused($questionFocused).onSubmit { ask() }
                Button("Ask") { ask() }.buttonStyle(.borderedProminent)
                    .disabled(!canAsk || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || working || document.engine == nil || document.busy)
            }
            Text(modelStatus).font(.caption).foregroundStyle(canAsk ? Color(nsColor:ScanTheme.muted) : Color(nsColor:ScanTheme.danger))
            if generatedSQL.isEmpty && !working {
                HStack(spacing:10) {
                    Button("Count rows") { question = "How many rows are in this file?" }
                    if let column = document.schema.first(where: { $0.kind == .text }) {
                        Button("Find text") { question = "Show rows where \(column.name) contains \"play\"" }
                        Button("Summarize") { question = "Count rows by \(column.name), highest first" }
                    }
                }.buttonStyle(.link).font(.system(size:11))
            }
            if working {
                HStack { ProgressView().controlSize(.small); Text(phase); Spacer(); Button("Cancel") { cancel() }.buttonStyle(.link) }
                    .font(.system(size:12))
            }
            if let error { Text(error).foregroundStyle(Color(nsColor:ScanTheme.danger)).font(.system(size:12)).textSelection(.enabled) }
            if !generatedSQL.isEmpty {
                HStack { Text("DUCKDB QUERY").font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(.secondary); Spacer(); Button(editingSQL ? "Done editing" : "Edit SQL") { editingSQL.toggle() }.buttonStyle(.link); Button("Copy SQL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(generatedSQL,forType:.string) }.buttonStyle(.link) }
                if editingSQL {
                    TextEditor(text:$generatedSQL).font(.system(size:12,design:.monospaced))
                        .frame(height:100).scrollContentBackground(.hidden).padding(8)
                        .background(Color(nsColor:ScanTheme.chrome)).clipShape(RoundedRectangle(cornerRadius:5))
                    Button("Run Query") { runEditedQuery() }.disabled(working || document.busy)
                } else {
                    ScrollView { Text(generatedSQL).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading) }
                        .frame(maxHeight:110).padding(10)
                        .background(Color(nsColor:ScanTheme.chrome)).clipShape(RoundedRectangle(cornerRadius:5))
                }
                Text(explanation).font(.system(size:12)).foregroundStyle(.secondary)
            }
            if let result {
                Text(result.page.count == 200 ? "RESULT · first 200 rows" : "RESULT · \(result.page.count) rows").font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(.secondary)
                if result.page.count == 0 { Text("No rows matched. Try a different word or a broader question.").font(.system(size:12)).foregroundStyle(.secondary) }
                ScrollView([.horizontal,.vertical]) {
                    Grid(horizontalSpacing:0,verticalSpacing:0) {
                        GridRow {
                            ForEach(Array(result.columns.enumerated()),id:\.offset) { _,column in
                                Text(column.name).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                                    .frame(minWidth:130,maxWidth:.infinity,alignment:.leading).padding(8)
                                    .background(Color(nsColor:ScanTheme.chrome))
                            }
                        }
                        ForEach(0..<result.page.count,id:\.self) { row in
                            GridRow {
                                ForEach(result.columns.indices,id:\.self) { col in
                                    let value = result.page.columns[col][row]
                                    Text(value ?? "NULL").font(.system(size:12,design:.monospaced))
                                        .foregroundStyle(Color(nsColor:value == nil ? ScanTheme.null : ScanTheme.color(for:result.columns[col].kind,value:value)))
                                        .lineLimit(1).frame(minWidth:130,maxWidth:.infinity,alignment:.leading).padding(8)
                                        .background(row.isMultiple(of:2) ? Color.primary.opacity(0.025) : .clear)
                                }
                            }
                        }
                    }
                }.background(Color(nsColor:ScanTheme.grid)).clipShape(RoundedRectangle(cornerRadius:5))
            } else { Spacer(minLength:0) }
        }
        .padding(20).frame(width:720,height:560)
        .onAppear { questionFocused = true }
        .onDisappear { cancel() }
    }
    private func cancel() {
        queryTask?.cancel()
        queryTask = nil
        if runningSQL { document.engine?.cancel() }
        working = false
        runningSQL = false
    }
    private func runEditedQuery() {
        guard !working, !document.busy, let engine = document.engine else { return }
        working = true; runningSQL = true; phase = "Running query…"; error = nil; result = nil
        let sql = generatedSQL
        queryTask = Task {
            defer { if !Task.isCancelled { working = false; runningSQL = false; queryTask = nil } }
            do {
                let validated = try AskQuery.validate(sql)
                let output = try await engine.ask(validated)
                try Task.checkCancellation()
                generatedSQL = validated; result = output
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func ask() {
        guard canAsk, !working, !document.busy, let engine = document.engine else { return }
        let input = question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        working = true; error = nil; result = nil; generatedSQL = ""; explanation = ""; editingSQL = false
        phase = "Writing a query…"
        let schema = document.schema.map { "\(Planner.identifier($0.name)) \($0.type)" }.joined(separator:", ")
        queryTask = Task {
            defer { if !Task.isCancelled { working = false; runningSQL = false; queryTask = nil } }
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
                    let generated = try await session.respond(to:prompt,generating:GeneratedQuery.self).content
                    try Task.checkCancellation()
                    generatedSQL = generated.sql; explanation = generated.explanation
                    do {
                        phase = "Running query…"
                        let sql = try AskQuery.validate(generated.sql)
                        generatedSQL = sql
                        runningSQL = true
                        let output = try await engine.ask(sql)
                        runningSQL = false
                        try Task.checkCancellation()
                        result = output
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
                    self.error = "Couldn’t answer that yet. \(error.localizedDescription)" + (generatedSQL.isEmpty ? " Try a shorter question." : " You can edit the SQL below and run it again.")
                }
            }
        }
    }
}
