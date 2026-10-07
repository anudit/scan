import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanQuery
import ScanTheme

struct WorkspaceView: View {
    @State private var model: WindowModel
    init(model: WindowModel = WindowModel()) { _model = State(initialValue:model) }
    @State private var search = ""
    @State private var targeted = false
    var body: some View {
        HStack(spacing:0) {
            if model.sidebar { sidebar.frame(width:205); Divider() }
            VStack(spacing:0) {
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
        .background(NativeWindowBridge(model:model))
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:16) {
            TextField("Search files & columns",text:$search).textFieldStyle(.roundedBorder).font(.system(size:11)).padding(.top,14)
            ScrollView {
                VStack(alignment:.leading,spacing:5) {
                    sectionLabel("FILES",count:model.documents.count)
                    ForEach(model.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { doc in
                        Button { model.selection = doc.id } label: { HStack { FileIcon(url:doc.url); Text(doc.title).lineLimit(1); Spacer(minLength:0) }.padding(8).background(model.selection == doc.id ? Color.primary.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius:4)) }.buttonStyle(.plain)
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
    private var empty: some View {
        VStack(spacing:16) {
            Spacer(); Image(systemName:"tablecells").font(.system(size:46,weight:.ultraLight)).foregroundStyle(Color.accentColor)
            Text("A closer look at your data.").font(.system(size:24,weight:.medium))
            Text("Drop a CSV, TSV, JSONL, NDJSON, Parquet, SQLite or DuckDB file").foregroundStyle(.secondary)
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
    @AppStorage("inspectorWidth") private var inspectorWidth = 290.0
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
                if model.inspector { InspectorResizeHandle(width:$inspectorWidth); InspectorView(model:model).frame(width:inspectorWidth) }
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

/// AppKit hosts this accessory inside the title row, beside the traffic lights.
final class WorkspaceTitlebarController: NSTitlebarAccessoryViewController {
    private var model: WindowModel
    init(model: WindowModel) {
        self.model = model
        super.init(nibName:nil,bundle:nil)
        layoutAttribute = .right
        let host = NSHostingView(rootView:WorkspaceTitlebar(model:model))
        host.sizingOptions = []
        host.frame = NSRect(x:0,y:0,width:700,height:44)
        view = host

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ model: WindowModel) {
        self.model = model
        (view as? NSHostingView<WorkspaceTitlebar>)?.rootView = WorkspaceTitlebar(model:model)
    }
    func resize() {
        guard let window = model.window else { return }
        let width = max(300,window.frame.width - 108)
        if abs(view.frame.width - width) > 0.5 { view.setFrameSize(NSSize(width:width,height:view.frame.height)) }
    }
}

private struct WorkspaceTitlebar: View {
    let model: WindowModel
    var body: some View {
        HStack(spacing:12) {
            Button { model.sidebar.toggle() } label: {
                Image(systemName:"sidebar.left").frame(width:28,height:28)
            }.buttonStyle(.plain).help("Toggle sidebar (⌘0)").accessibilityLabel("Toggle sidebar")
            Text("Scan").font(.system(size:15,weight:.semibold)).padding(.trailing,12)
            ScrollViewReader { scroll in
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:6) {
                        ForEach(model.tabs) { tab in
                            HStack(spacing:8) {
                                Button { NativeWindows.shared.select(tab) } label: {
                                    HStack(spacing:8) {
                                        FileIcon(url:tab.active?.url)
                                        Text(tab.active?.title ?? "New Tab").lineLimit(1).truncationMode(.middle)
                                    }.frame(minWidth:80,maxWidth:220,alignment:.leading)
                                }.buttonStyle(.plain)
                                Button { NativeWindows.shared.closeTab(tab) } label: {
                                    Image(systemName:"xmark").font(.system(size:9,weight:.medium)).frame(width:18,height:22)
                                }.buttonStyle(.plain).help("Close tab").accessibilityLabel("Close \(tab.active?.title ?? "New Tab")")
                            }
                            .font(.system(size:12,weight:tab === model ? .medium : .regular))
                            .padding(.horizontal,10).frame(height:30)
                            .background(tab === model ? Color.primary.opacity(0.10) : Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:8))
                            .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(Color.primary.opacity(tab === model ? 0.13 : 0.04)) }
                            .id(tab.id)
                            .contextMenu {
                                Button("Move Tab to New Window") { NativeWindows.shared.detach(tab) }
                                Button("Close Tab") { NativeWindows.shared.closeTab(tab) }
                            }
                            .onDrag { NSItemProvider(object:("scan-tab:" + tab.id.uuidString) as NSString) }
                            .onDrop(of:[UTType.text],isTargeted:nil) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass:NSString.self) { item,_ in
                                    guard let value = item as? String, value.hasPrefix("scan-tab:"), let id = UUID(uuidString:String(value.dropFirst(9))) else { return }
                                    Task { @MainActor in
                                        guard let dragged = NativeWindows.shared.models.first(where: { $0.id == id }),
                                              dragged !== tab else { return }
                                        NativeWindows.shared.move(dragged,before:tab)
                                    }
                                }
                                return true
                            }
                        }
                    }.padding(.vertical,3)
                }
                .onAppear { scroll.scrollTo(model.id,anchor:.trailing) }
                .onChange(of:NativeWindows.shared.revision) { scroll.scrollTo(model.id,anchor:.trailing) }
            }
            Button { model.newTab() } label: { Image(systemName:"plus").frame(width:28,height:28) }
                .buttonStyle(.plain).help("New tab (⌘T)").accessibilityLabel("New tab")
        }
        .padding(.trailing,12).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

/// A symbol and tint for a file's format, shown in tabs and the sidebar. Gzip files use the inner format.
struct FileIcon: View {
    let url: URL?
    var body: some View {
        let (symbol,tint) = Self.style(for:url)
        Image(systemName:symbol).foregroundStyle(tint).frame(width:16)
    }
    static func style(for url: URL?) -> (String,Color) {
        guard let url else { return ("doc",.secondary) }
        var format = url.pathExtension.lowercased()
        if format == "gz" { format = url.deletingPathExtension().pathExtension.lowercased() }
        switch format {
        case "csv","tsv": return ("tablecells",.green)
        case "jsonl","ndjson","json": return ("curlybraces",.orange)
        case "parquet": return ("rectangle.split.3x1",Color(nsColor:ScanTheme.accent))
        case "sqlite","sqlite3","db","duckdb","ddb": return ("cylinder.split.1x2",.purple)
        default: return ("doc.text",.secondary)
        }
    }
}
