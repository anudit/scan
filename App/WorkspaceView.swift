import SwiftUI
import UniformTypeIdentifiers
import ScanQuery
import ScanTheme

struct WorkspaceView: View {
    @State private var model = WindowModel()
    @State private var search = ""
    @State private var targeted = false
    var body: some View {
        HStack(spacing:0) {
            if model.sidebar { sidebar.frame(width:205); Divider() }
            VStack(spacing:0) {
                tabs
                if let doc = model.active { DocumentView(model:doc).id(doc.id) }
                else { empty }
            }
        }
        .background(Color(nsColor:ScanTheme.grid))
        .tint(Color(nsColor:ScanTheme.accent))
        .focusedSceneValue(\.scanWindow,model)
        .onDrop(of:[UTType.fileURL],isTargeted:$targeted) { providers in
            for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in model.open([url]) } } } }; return true
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius:8).stroke(Color.accentColor,lineWidth:3).padding(6).allowsHitTesting(false) } }
        .onAppear {
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath:$0) }.filter { FileManager.default.fileExists(atPath:$0.path) }
            if model.documents.isEmpty { model.open(args + AppDelegate.pendingURLs); AppDelegate.pendingURLs = [] }
        }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanOpenFiles"))) { notification in
            guard let urls = notification.object as? [URL], NSApp.keyWindow?.isKeyWindow != false else { return }; model.open(urls); AppDelegate.pendingURLs = []
        }
        .onDisappear { model.documents.forEach { $0.close() } }
        .navigationTitle(model.active?.title ?? "Scan")
        .background(Color(nsColor:ScanTheme.chrome).ignoresSafeArea())
        .modifier(HiddenWindowTitle())
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Image(systemName:"square.grid.3x3.fill").foregroundStyle(Color.accentColor); Text("Scan").font(.system(size:18,weight:.semibold)); Spacer(); Button { model.choose() } label: { Image(systemName:"plus") }.buttonStyle(.plain).help("Open files (⌘O)") }.padding(.top,16)
            TextField("Search files & columns",text:$search).textFieldStyle(.roundedBorder).font(.system(size:11))
            ScrollView {
                VStack(alignment:.leading,spacing:5) {
                    sectionLabel("FILES",count:model.documents.count)
                    ForEach(model.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { doc in
                        Button { model.selection = doc.id } label: { HStack { Image(systemName:"tablecells").foregroundStyle(Color.accentColor); Text(doc.title).lineLimit(1); Spacer(minLength:0) }.padding(8).background(model.selection == doc.id ? Color.white.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius:4)) }.buttonStyle(.plain)
                        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }; Button("Close") { model.close(doc.id) } }
                    }
                    if let doc = model.active {
                        if !doc.tables.isEmpty {
                            sectionLabel("TABLES",count:doc.tables.count).padding(.top,18)
                            ForEach(doc.tables.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) },id:\.self) { table in
                                Button { doc.open(table:table) } label: { Label(table,systemImage:table == doc.selectedTable ? "tablecells.fill" : "tablecells").lineLimit(1).padding(6) }.buttonStyle(.plain)
                            }
                        }
                        sectionLabel("COLUMNS",count:doc.schema.count).padding(.top,18)
                        ForEach(doc.schema.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { col in
                            Button { if let index = doc.state.columns.firstIndex(of:col) { doc.grid?.focus(row:doc.selectedRow,column:index) } } label: {
                                HStack(spacing:8) { Text(col.kind.glyph).font(.system(size:11,design:.monospaced)).foregroundStyle(Color(nsColor:ScanTheme.muted)).frame(width:20); Text(col.name).lineLimit(1); Spacer(minLength:0); if !doc.state.columns.contains(col) { Image(systemName:"eye.slash").font(.system(size:10)) } }.padding(.vertical,6)
                            }.buttonStyle(.plain).contextMenu {
                                Button("Sort Ascending") { doc.state.sorts = [SortKey(col.name)]; doc.reload() }
                                Button("Sort Descending") { doc.state.sorts = [SortKey(col.name,ascending:false)]; doc.reload() }
                                Button("Group by") { doc.group(col) }
                                Button(doc.state.columns.contains(col) ? "Hide Column" : "Show Column") { if doc.state.columns.contains(col) { doc.hide(col) } else { doc.show(col) } }
                            }
                        }
                    }
                }
            }
            Spacer(minLength:0)
            HStack { SettingsLink { Image(systemName:"gearshape") }.buttonStyle(.plain); Spacer(); Text("READ ONLY").font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.secondary) }.padding(.bottom,14)
        }.padding(.horizontal,12).background(Color(nsColor:ScanTheme.chrome))
    }
    private func sectionLabel(_ name: String,count: Int) -> some View { HStack { Text(name).tracking(1); Spacer(); Text(String(count)) }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary).padding(.vertical,5) }
    private var tabs: some View {
        HStack(spacing:0) {
            ScrollView(.horizontal,showsIndicators:false) { HStack(spacing:0) {
                ForEach(model.documents) { doc in
                    HStack(spacing:8) { Image(systemName:"tablecells").foregroundStyle(Color.accentColor); Text(doc.title).lineLimit(1); Button { model.close(doc.id) } label: { Image(systemName:"xmark").font(.system(size:9)) }.buttonStyle(.plain) }
                        .font(.system(size:12)).padding(.horizontal,14).frame(height:38).background(model.selection == doc.id ? Color(nsColor:ScanTheme.grid) : Color.clear,ignoresSafeAreaEdges:[])
                        .overlay(alignment:.bottom) { if model.selection == doc.id { Rectangle().fill(Color.accentColor).frame(height:2) } }
                        .contentShape(Rectangle()).onTapGesture { model.selection = doc.id }
                }
            } }
            Button { model.choose() } label: { Image(systemName:"plus").frame(width:36,height:36) }.buttonStyle(.plain).help("Open a new tab (⌘T)")
        }.background(Color(nsColor:ScanTheme.chrome))
    }
    private var empty: some View {
        VStack(spacing:16) {
            Spacer(); Image(systemName:"tablecells").font(.system(size:46,weight:.ultraLight)).foregroundStyle(Color.accentColor)
            Text("A closer look at your data.").font(.system(size:24,weight:.medium))
            Text("Drop a CSV, TSV, Parquet, SQLite or DuckDB file").foregroundStyle(.secondary)
            Button("Open File…") { model.choose() }.keyboardShortcut("o").buttonStyle(.borderedProminent).padding(.top,6)
            let recent = NSDocumentController.shared.recentDocumentURLs.prefix(5)
            if !recent.isEmpty { VStack(alignment:.leading,spacing:8) { Text("RECENT").font(.caption).foregroundStyle(.secondary); ForEach(Array(recent),id:\.self) { url in Button(url.lastPathComponent) { model.open([url]) }.buttonStyle(.link) } }.padding(.top,24) }
            Spacer(); Text("Local files. Native speed. Always read-only.").font(.caption).foregroundStyle(.secondary).padding(.bottom,28)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct DocumentView: View {
    @Bindable var model: DocumentModel
    @FocusState private var filterFocused: Bool
    @State private var builder = false
    @State private var askShown = false
    @State private var goToRow = false
    @State private var rowNumber = ""
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter rows with a WHERE expression…",text:$model.filterDraft).textFieldStyle(.plain).font(.system(size:12,design:.monospaced)).focused($filterFocused)
                    .onSubmit { model.applyFilter() }.onChange(of:model.filterDraft) { model.validateFilter() }.onExitCommand { model.filterDraft = model.state.filter; filterFocused = false; model.grid?.focus(row:model.selectedRow,column:model.selectedIndex) }
                    .help(model.filterError ?? "Press Return to apply, Escape to revert")
                if !model.state.filter.isEmpty { Button { model.filterDraft = ""; model.state.filter = ""; model.reload() } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain) }
                Divider().frame(height:18)
                tool("arrow.clockwise","Reload from disk (⌘R)") { model.open() }
                Menu { ForEach(model.schema) { col in Button(col.name) { model.state.sorts.append(SortKey(col.name)); model.reload() } }; Divider(); Button("Clear Sort") { model.state.sorts = []; model.reload() } } label: { Image(systemName:"arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().help("Add sort column; Shift-click headers for multi-column sorting")
                tool("rectangle.split.3x1","Columns") { model.inspectorTab = "Columns"; model.inspector.toggle() }
                tool("square.stack.3d.up","Pivot") { model.inspectorTab = "Pivot"; model.inspector.toggle() }
                tool("line.3.horizontal.decrease.circle","Filter builder") { builder.toggle() }.popover(isPresented:$builder) { FilterBuilder(model:model).frame(width:480).padding(20) }
                Button { askShown = true } label: { Label("Ask",systemImage:"sparkles") }
                    .buttonStyle(.plain).font(.system(size:12,weight:.semibold)).help("Ask your data with Apple Intelligence")
                tool("sidebar.right","Inspector (⌘I)") { model.inspector.toggle(); if model.inspector { model.fetchCell() } }
            }.padding(.horizontal,12).frame(height:40)
            Rectangle().fill(model.filterError == nil ? Color(nsColor:ScanTheme.line) : Color(nsColor:ScanTheme.danger)).frame(height:1)
            if let error = model.error ?? model.filterError {
                HStack { Image(systemName:"exclamationmark.circle"); Text(error).font(.system(size:11)).lineLimit(3); Spacer(); Button("Copy details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error,forType:.string) }; Button { model.error = nil; model.filterError = nil } label: { Image(systemName:"xmark") } }.foregroundStyle(Color(nsColor:ScanTheme.danger)).padding(10).background(Color.red.opacity(0.06))
            }
            HStack(spacing:0) {
                ZStack {
                    GridBridge(model:model)
                    if model.rowCount == 0 && !model.busy && model.error == nil { VStack(spacing:10) { Text("No rows match this view").foregroundStyle(.secondary); Button("Clear Filter") { model.filterDraft = ""; model.state.filter = ""; model.reload() } } }
                }
                if model.inspector { Divider(); InspectorView(model:model).frame(width:290) }
            }
            Divider()
            HStack(spacing:12) {
                if model.busy { ProgressView().controlSize(.small); Text(model.status); Button("Cancel") { model.cancel() }.buttonStyle(.link) }
                else { Image(systemName:"tablecells"); Text("\(model.rowCount.formatted()) \(model.state.groups.isEmpty ? "rows" : "groups")"); Divider().frame(height:12); Text("\(model.state.columns.count) columns") }
                Spacer()
                if !model.state.sorts.isEmpty { Text(model.state.sorts.map { $0.column + ($0.ascending ? " ↑" : " ↓") }.joined(separator:", ")).lineLimit(1) }
                if !model.busy { Text(model.status).foregroundStyle(.secondary) }
                tool("square.and.arrow.up","Export current view") { model.export() }
            }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,12).frame(height:30)
        }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanFocusFilter"))) { note in if note.object as? UUID == model.id { filterFocused = true } }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanGoToRow"))) { note in if note.object as? UUID == model.id { goToRow = true } }
        .sheet(isPresented:$goToRow) { VStack(alignment:.leading,spacing:16) { Text("Go to row").font(.headline); TextField("Row number",text:$rowNumber).onSubmit { jump() }; HStack { Button("Cancel") { goToRow = false }; Spacer(); Button("Go") { jump() }.keyboardShortcut(.defaultAction) } }.padding(24).frame(width:300) }
        .sheet(isPresented:$askShown) { AskView(document:model) }
    }
    private func jump() { if let row = Int(rowNumber.replacingOccurrences(of:",",with:"")) { model.grid?.focus(row:row-1,column:model.selectedIndex); goToRow = false } }
    private func tool(_ icon: String,_ help: String,action:@escaping ()->Void) -> some View { Button(action:action) { Image(systemName:icon).frame(width:24,height:24) }.buttonStyle(.plain).help(help) }
}

/// Hides the window title text (the active tab already names the file) so it never draws
/// over the sidebar or tab strip. The title stays set for the Window menu and Mission Control.
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing:.title).toolbarBackground(.hidden,for:.windowToolbar)
        } else {
            content.background(TitlebarStyler())
        }
    }
}
private struct TitlebarStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
    }
}
