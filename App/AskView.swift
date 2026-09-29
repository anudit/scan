import SwiftUI
import ScanEngine
import ScanQuery
import ScanTheme
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct GeneratedQuery {
    @Guide(description: "One DuckDB SELECT statement using only scan_data. No Markdown fences or trailing semicolon.")
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
            Text("Describe what you want to know. Scan sends the column names and types to Apple's on-device model, then runs its DuckDB query against this file.")
                .font(.system(size:12)).foregroundStyle(.secondary)
            HStack(spacing:10) {
                TextField("For example: Count rows by country, highest first",text:$question)
                    .textFieldStyle(.roundedBorder).focused($questionFocused).onSubmit { ask() }
                Button("Ask") { ask() }.buttonStyle(.borderedProminent)
                    .disabled(!canAsk || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || working || document.engine == nil)
            }
            Text(modelStatus).font(.caption).foregroundStyle(canAsk ? Color(nsColor:ScanTheme.muted) : Color(nsColor:ScanTheme.danger))
            if working { ProgressView("Generating and running query…").frame(maxWidth:.infinity,alignment:.leading) }
            if let error { Text(error).foregroundStyle(Color(nsColor:ScanTheme.danger)).font(.system(size:12)).textSelection(.enabled) }
            if !generatedSQL.isEmpty {
                HStack { Text("DUCKDB QUERY").font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(.secondary); Spacer(); Button("Copy SQL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(generatedSQL,forType:.string) }.buttonStyle(.link) }
                Text(generatedSQL).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(10)
                    .background(Color(nsColor:ScanTheme.chrome)).clipShape(RoundedRectangle(cornerRadius:5))
                Text(explanation).font(.system(size:12)).foregroundStyle(.secondary)
            }
            if let result {
                Text("RESULT · \(result.page.count) rows shown").font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(.secondary)
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
                                        .background(row.isMultiple(of:2) ? Color.white.opacity(0.025) : .clear)
                                }
                            }
                        }
                    }
                }.background(Color(nsColor:ScanTheme.grid)).clipShape(RoundedRectangle(cornerRadius:5))
            } else { Spacer(minLength:0) }
        }
        .padding(20).frame(minWidth:680,minHeight:500)
        .onAppear { questionFocused = true }
    }
    private func ask() {
        guard canAsk, !working, let engine = document.engine else { return }
        let input = question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        working = true; error = nil; result = nil; generatedSQL = ""; explanation = ""
        let schema = document.schema.map { "\(Planner.identifier($0.name)) \($0.type)" }.joined(separator:", ")
        Task {
            do {
                guard #available(macOS 26.0, *) else { throw EngineError("Ask requires macOS 26 or later.") }
                let session = LanguageModelSession(instructions: "You generate DuckDB SQL for a read-only local table named scan_data. Return only a SELECT query. Reference only scan_data and the supplied columns. Never call file-reading functions or modify data. Use LIMIT for row listings. Prefer aggregates for count and summary questions.")
                let generated = try await session.respond(to: "Table: scan_data. Columns: \(schema). Question: \(input)", generating: GeneratedQuery.self).content
                guard !Task.isCancelled else { return }
                let sql = try AskQuery.validate(generated.sql)
                generatedSQL = sql; explanation = generated.explanation
                result = try await engine.ask(sql)
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
