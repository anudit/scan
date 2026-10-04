import SwiftUI
import ScanQuery
import ScanTheme
/// The inspector's leading border. Dragging it resizes the inspector; the width persists.
struct InspectorResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    var body: some View {
        Rectangle().fill(Color(nsColor:ScanTheme.line)).frame(width:1)
            .overlay { Color.clear.frame(width:9).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global)
                    .onChanged { value in let base = start ?? width; start = base; width = min(720,max(220,base - value.translation.width)) }
                    .onEnded { _ in start = nil })
            }
            .help("Drag to resize the inspector")
    }
}
struct InspectorView: View {
    @Bindable var model: DocumentModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Picker("Inspector",selection:$model.inspectorTab) { Text("Pivot").tag("Pivot"); Text("Columns").tag("Columns"); Text("Cell").tag("Cell") }.pickerStyle(.segmented).labelsHidden()
            if model.inspectorTab == "Cell" {
                Text(model.selectedColumn.isEmpty ? "Select a cell" : model.selectedColumn).font(.headline)
                ScrollView(.vertical) { Text(model.selectedCell).font(.system(size:12,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.topLeading) }
                Button("Copy Full Value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.selectedCell,forType:.string) }.disabled(model.selectedColumn.isEmpty)
            } else if model.inspectorTab == "Columns" {
                Text("VISIBLE COLUMNS").font(.caption).foregroundStyle(.secondary)
                ScrollView { VStack(spacing:8) { ForEach(model.schema) { col in
                    HStack { Toggle(col.name,isOn:Binding(get:{ model.state.columns.contains(col) },set:{ if $0 { model.show(col) } else { model.hide(col) } })).toggleStyle(.checkbox).lineLimit(1)
                        Spacer(); if let index = model.state.columns.firstIndex(of:col), index > 0 { Button { model.state.columns.swapAt(index,index-1); model.reload() } label: { Image(systemName:"arrow.up") }.buttonStyle(.plain).help("Move column left") }
                    }
                } } }
            } else {
                Text("GROUP BY").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.state.groups.enumerated()),id:\.offset) { index,name in HStack { Text("\(index+1)").foregroundStyle(.secondary); Text(name); Spacer(); Button { model.state.groups.remove(at:index); model.reload() } label: { Image(systemName:"xmark") }.buttonStyle(.plain) } }
                Menu("Add Group…") { ForEach(model.schema.filter { !model.state.groups.contains($0.name) }) { col in Button(col.name) { model.group(col) } } }
                if !model.state.groups.isEmpty { Button("Clear Pivot") { model.state.groups = []; model.reload() } }
                Divider(); Text("AGGREGATES").font(.caption).foregroundStyle(.secondary)
                ScrollView { VStack(alignment:.leading,spacing:12) { ForEach(model.state.columns.filter { !model.state.groups.contains($0.name) }) { col in
                    VStack(alignment:.leading,spacing:4) { Text(col.name).font(.system(size:11)).lineLimit(1)
                        Picker("Function",selection:Binding(get:{ model.state.aggregates[col.name] ?? (col.kind == .number ? .sum : .count) },set:{ model.state.aggregates[col.name] = $0; model.reload() })) {
                            ForEach(Aggregate.allCases.filter { col.kind == .number || ![.sum,.avg].contains($0) },id:\.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                    }
                } } }
            }
            Spacer(minLength:0)
        }.padding(14).background(Color(nsColor:ScanTheme.chrome)).onChange(of:model.inspectorTab) { if model.inspectorTab == "Cell" { model.fetchCell() } }
    }
}
struct FilterBuilder: View {
    @Bindable var model: DocumentModel
    @State private var rules: [FilterRule] = []
    @State private var any = false
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Filter rows").font(.headline); Spacer(); Picker("Match",selection:$any) { Text("All (AND)").tag(false); Text("Any (OR)").tag(true) }.fixedSize() }
            ForEach($rules) { $rule in
                HStack {
                    Picker("Column",selection:$rule.column) { ForEach(model.schema) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width:140)
                    Picker("Operator",selection:$rule.op) { ForEach(FilterOperator.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width:100)
                    if ![.isNull,.isNotNull].contains(rule.op) { TextField("Value",text:$rule.value) }
                    Button { rules.removeAll { $0.id == rule.id } } label: { Image(systemName:"minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack { Button("Add Condition") { if let first = model.schema.first { rules.append(FilterRule(column:first.name)) } }; Spacer(); Button("Apply") {
                // Emit an editable expression with safely quoted literals. The engine executes it as one SELECT.
                let expression = rules.map { rule -> String in
                    let query = Planner.predicate([rule],any:false)
                    guard let value = query.parameters.first else { return query.text }
                    // The placeholder occurs at the end of these known operator templates, never in an identifier.
                    if let range = query.text.range(of:"?",options:.backwards) { var text = query.text; text.replaceSubrange(range,with:value.map(Planner.literal) ?? "NULL"); return text }
                    return query.text
                }.joined(separator:any ? " OR " : " AND ")
                model.filterDraft = expression; model.filterError = nil; model.state.filter = expression; model.reload(); dismiss()
            }.keyboardShortcut(.defaultAction) }
        }.onAppear { if rules.isEmpty, let first = model.schema.first { rules = [FilterRule(column:first.name)] } }
    }
}
