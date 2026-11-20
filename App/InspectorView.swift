import SwiftUI
import ScanQuery
import ScanTheme
import ScanGrid
struct InspectorView: View {
    @Bindable var model: DocumentModel
    @AppStorage("cellJSONTree") private var jsonTree = true
    static func icon(_ tab: String) -> String {
        switch tab { case "Columns": "rectangle.split.3x1"; case "Profile": "chart.bar.xaxis"; case "Pivot": "square.stack.3d.up"; default: "doc.text.magnifyingglass" }
    }
    /// The cell as an http(s) URL, when the whole value is one.
    static func webURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where:\.isWhitespace), let url = URL(string:t), ["http","https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }
    /// URLs that look like images by extension, or that live on a well-known avatar/image path.
    static func isImage(_ url: URL) -> Bool {
        if ["png","jpg","jpeg","gif","webp","svg","bmp","heic","tiff","avif"].contains(url.pathExtension.lowercased()) { return true }
        let host = url.host?.lowercased() ?? "", path = url.path.lowercased()
        return host.contains("avatar") || path.contains("/avatars/") || path.contains("/images/")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:8) {
                Image(systemName:Self.icon(model.inspectorTab)).font(.system(size:12,weight:.medium)).foregroundStyle(Color(nsColor:ScanTheme.accent))
                Text(model.inspectorTab).font(.system(size:13,weight:.semibold))
                Spacer()
                if model.inspectorTab == "Cell" {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.selectedCell,forType:.string) } label: { Image(systemName:"doc.on.doc").font(.system(size:11,weight:.medium)).frame(width:22,height:22) }
                        .buttonStyle(HoverButtonStyle()).help("Copy full value").disabled(model.selectedColumn.isEmpty)
                }
                Button { model.inspector = false } label: { Image(systemName:"xmark").font(.system(size:10,weight:.semibold)).frame(width:22,height:22) }.buttonStyle(HoverButtonStyle()).help("Close")
            }
            if model.inspectorTab == "Cell" {
                HStack {
                    Text(model.selectedColumn.isEmpty ? "Select a cell" : model.selectedColumn).font(.headline).lineLimit(1)
                    Spacer()
                    if model.selectedJSON != nil {
                        Picker("JSON View",selection:$jsonTree) { Image(systemName:"list.bullet.indent").help("Tree").tag(true); Image(systemName:"text.alignleft").help("Text").tag(false) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
                if let url = Self.webURL(model.selectedCell) {
                    HStack(spacing:8) {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open in Browser",systemImage:"safari") }
                        if let temporal = TemporalFormat.local(model.selectedCell) { Text(temporal).font(.caption).foregroundStyle(.secondary) }
                    }
                    if Self.isImage(url) {
                        AsyncImage(url:url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit().frame(maxWidth:.infinity,maxHeight:260).clipShape(RoundedRectangle(cornerRadius:8))
                            case .failure: EmptyView()
                            default: ProgressView().controlSize(.small).frame(maxWidth:.infinity,minHeight:60)
                            }
                        }.id(url)
                    }
                } else if let temporal = TemporalFormat.local(model.selectedCell) {
                    Text(temporal).font(.caption).foregroundStyle(.secondary)
                }
                if let json = model.selectedJSON, jsonTree { JSONTreeView(root:json).id(model.cellRevision) }
                else { ScrollView(.vertical) { Text(model.selectedCell).font(.system(size:12,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.topLeading) } }
            } else if model.inspectorTab == "Profile" {
                ProfileView(model:model)
            } else if model.inspectorTab == "Columns" {
                Text("Visible columns").font(.system(size:11,weight:.semibold)).foregroundStyle(Color(nsColor:ScanTheme.muted))
                ScrollView { VStack(spacing:0) { ForEach(model.schema) { col in
                    HStack(spacing:6) { Toggle(col.name,isOn:Binding(get:{ model.state.columns.contains(col) },set:{ if $0 { model.show(col) } else { model.hide(col) } })).toggleStyle(.checkbox).lineLimit(1)
                        Spacer()
                        if col.kind == .number {
                            Button { withAnimation(Motion.hover) { model.toggleHeatmap(col.name) } } label: { HeatSwatch(on:model.heatColumns.contains(col.name)).frame(width:22,height:22) }
                                .buttonStyle(HoverButtonStyle()).help(model.heatColumns.contains(col.name) ? "Remove heatmap" : "Color as heatmap")
                        }
                        if let index = model.state.columns.firstIndex(of:col), index > 0 { Button { model.state.columns.swapAt(index,index-1); model.reload() } label: { Image(systemName:"arrow.up").font(.system(size:11)).frame(width:22,height:22) }.buttonStyle(HoverButtonStyle()).help("Move column left") }
                        else { Color.clear.frame(width:28,height:22) }
                    }.frame(height:30).rowHighlight()
                } } }.scrollIndicators(.never)
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
        }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).onChange(of:model.inspectorTab) { if model.inspectorTab == "Cell" { model.fetchCell() } }
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
