import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanEngine
import ScanQuery
import ScanTheme

struct WorkspaceView: View {
    @State private var model: WindowModel
    init(model: WindowModel = WindowModel()) { _model = State(initialValue:model) }
    @AppStorage("accentHex") private var accentHex = ""
    @State private var search = ""
    @State private var targeted = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0
    var body: some View {
        HStack(spacing:0) {
            ResizablePanel(edge:.leading,size:$sidebarWidth,isOpen:Binding(get:{ model.sidebar && model.active != nil },set:{ model.sidebar = $0 }),range:190...380,gap:6) { sidebar }
            VStack(spacing:0) {
                if let doc = model.active { DocumentView(model:doc).id(doc.id) }
                else { empty }
            }
        }
        .background(Color(nsColor:ScanTheme.chrome))
        .tint(Color(nsColor:ScanTheme.accent)).environment(\.accentRevision,accentHex)
        .focusedSceneValue(\.scanWindow,model)
        .onDrop(of:[UTType.fileURL],isTargeted:$targeted) { providers in
            for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in model.open([url]) } } } }; return true
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius:12,style:.continuous).strokeBorder(Color.accentColor,lineWidth:2).padding(6)
                    .shadow(color:Color.accentColor.opacity(0.6),radius:10)
                    .background(RoundedRectangle(cornerRadius:12,style:.continuous).fill(Color.accentColor.opacity(0.05)).padding(6))
                    .allowsHitTesting(false).transition(.opacity.combined(with:.scale(scale:1.01)))
            }
        }
        .animation(Motion.hover,value:targeted)
        .background(NativeWindowBridge(model:model))
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:14) {
            SoftSearchField(prompt:"Search files & columns",text:$search).padding(.top,7)
            ScrollView {
                VStack(alignment:.leading,spacing:2) {
                    sectionLabel("Files",count:model.documents.count)
                    ForEach(model.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { doc in
                        Button { withAnimation(Motion.hover) { model.selection = doc.id } } label: {
                            HStack(spacing:8) { FileIcon(url:doc.url); Text(doc.title).lineLimit(1).truncationMode(.middle); Spacer(minLength:0) }
                                .frame(height:30).rowHighlight(selected:model.selection == doc.id)
                        }.buttonStyle(.plain)
                        .contextMenu {
                            if doc.isRemote {
                                Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(doc.url.absoluteString, forType: .string) }
                            } else {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                            }
                            Button("Close") { model.close(doc.id) }
                        }
                    }
                    if let doc = model.active {
                        if !doc.tables.isEmpty {
                            sectionLabel("Tables",count:doc.tables.count).padding(.top,16)
                            ForEach(doc.tables.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) },id:\.self) { table in
                                Button { doc.open(table:table) } label: {
                                    HStack(spacing:8) {
                                        Image(systemName:table == doc.selectedTable ? "tablecells.fill" : "tablecells").foregroundStyle(table == doc.selectedTable ? Color(nsColor:ScanTheme.accent) : .secondary).frame(width:16)
                                        Text(table).lineLimit(1); Spacer(minLength:0)
                                    }.frame(height:28).rowHighlight(selected:table == doc.selectedTable)
                                }.buttonStyle(.plain)
                            }
                        }
                        sectionLabel("Columns",count:doc.schema.count).padding(.top,16)
                        ForEach(doc.schema.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { col in
                            let visible = doc.state.columns.contains(col)
                            Button { if let index = doc.state.columns.firstIndex(of:col) { doc.grid?.focus(row:doc.selectedRow,column:index) } } label: {
                                HStack(spacing:8) {
                                    Text(col.kind.glyph).font(.system(size:10.5,design:.monospaced)).foregroundStyle(Color(nsColor:ScanTheme.muted)).frame(width:18)
                                    Text(col.name).lineLimit(1).foregroundStyle(visible ? Color(nsColor:ScanTheme.primary) : Color.secondary)
                                    Spacer(minLength:0)
                                    if doc.heatColumns.contains(col.name) { HeatSwatch().transition(.scale.combined(with:.opacity)) }
                                    if !visible { Image(systemName:"eye.slash").font(.system(size:10)).foregroundStyle(.secondary) }
                                    if col.kind != .binary {
                                        Button { withAnimation(Motion.panel) { doc.toggleFacet(col.name) } } label: {
                                            Image(systemName:"chevron.right").font(.system(size:9,weight:.semibold))
                                                .rotationEffect(.degrees(doc.facetColumn == col.name ? 90 : 0)).frame(width:16,height:16)
                                        }.buttonStyle(HoverButtonStyle(active:doc.facetColumn == col.name)).help("Show the most common values")
                                    }
                                }.frame(height:28).rowHighlight()
                            }.buttonStyle(.plain).contextMenu {
                                Button("Show Top Values") { withAnimation(Motion.panel) { doc.toggleFacet(col.name) } }
                                Button("Show Profile") { doc.showProfile(col.name) }
                                Divider()
                                Button("Sort Ascending") { doc.state.sorts = [SortKey(col.name)]; doc.reload() }
                                Button("Sort Descending") { doc.state.sorts = [SortKey(col.name,ascending:false)]; doc.reload() }
                                Button("Group by") { doc.group(col) }
                                if col.kind == .number {
                                    Toggle("Color as Heatmap",isOn:Binding(get:{ doc.heatColumns.contains(col.name) },set:{ _ in withAnimation(Motion.hover) { doc.toggleHeatmap(col.name) } }))
                                }
                                Button(visible ? "Hide Column" : "Show Column") { if visible { doc.hide(col) } else { doc.show(col) } }
                            }
                            if doc.facetColumn == col.name {
                                FacetList(model:doc,column:col.name).transition(.opacity.combined(with:.move(edge:.top)))
                            }
                        }
                    }
                }.padding(.bottom,8)
            }.scrollIndicators(.never)
            HStack {
                SettingsLink { Image(systemName:"gearshape").frame(width:24,height:24) }.buttonStyle(HoverButtonStyle()).help("Settings")
                Spacer()
                Text("READ ONLY").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(0.8).foregroundStyle(.secondary)
                    .padding(.horizontal,7).padding(.vertical,3).background(Capsule().fill(Color.primary.opacity(0.05)))
            }.padding(.bottom,12)
        }.padding(.horizontal,10).background(Color(nsColor:ScanTheme.chrome))
    }
    private func sectionLabel(_ name: String,count: Int) -> some View {
        HStack {
            Text(name).font(.system(size:11,weight:.semibold)).foregroundStyle(Color(nsColor:ScanTheme.muted))
            Spacer()
            Text(String(count)).font(.system(size:10,weight:.medium).monospacedDigit()).foregroundStyle(.secondary)
                .padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentTransition(.numericText()).animation(Motion.hover,value:count)
        }.padding(.horizontal,8).padding(.top,4).padding(.bottom,4)
    }
    private var empty: some View {
        VStack(spacing:16) {
            Spacer(); Image(systemName:"tablecells").font(.system(size:46,weight:.ultraLight)).foregroundStyle(Color.accentColor)
            Text("A closer look at your data.").font(.system(size:24,weight:.medium))
            Text("Drop a CSV, TSV, JSON, Parquet, Excel, SQLite or DuckDB file, or a folder of them").foregroundStyle(.secondary)
            Text("or open a remote file by URL, including Hugging Face datasets").font(.callout).foregroundStyle(.tertiary)
            HStack(spacing:10) {
                Button("Open File…") { model.choose() }.keyboardShortcut("o").buttonStyle(.borderedProminent)
                Button("Open URL…") { model.chooseRemote() }
            }.padding(.top,6)
            let recent = NSDocumentController.shared.recentDocumentURLs.prefix(5)
            if !recent.isEmpty { VStack(alignment:.leading,spacing:8) { Text("RECENT").font(.caption).foregroundStyle(.secondary); ForEach(Array(recent),id:\.self) { url in Button(url.lastPathComponent) { model.open([url]) }.buttonStyle(.link) } }.padding(.top,24) }
            Spacer(); Text("Local files. Native speed. Always read-only.").font(.caption).foregroundStyle(.secondary).padding(.bottom,28)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct DocumentView: View {
    @Bindable var model: DocumentModel
    @State private var sqlFocused = false
    @State private var builder = false
    @State private var goToRow = false
    @State private var rowNumber = ""
    @AppStorage("inspectorWidth") private var inspectorWidth = 300.0
    @AppStorage("sqlHeight") private var sqlHeight = 300.0
    @State private var chipHover = false
    /// The space around the table card, the rail and the toolbar icons, so their edges line up.
    private static let gutter: CGFloat = 8
    var body: some View {
        VStack(spacing:0) {
            toolbar
            if let error = model.error {
                HStack { Image(systemName:"exclamationmark.circle"); Text(error).font(.system(size:11)).lineLimit(3); Spacer(); Button("Copy details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error,forType:.string) }; Button { model.error = nil } label: { Image(systemName:"xmark") } }
                    .foregroundStyle(Color(nsColor:ScanTheme.danger)).padding(10).background(Color.red.opacity(0.06), in:RoundedRectangle(cornerRadius:10,style:.continuous)).padding(.horizontal,Self.gutter).padding(.bottom,Self.gutter)
                    .transition(.move(edge:.top).combined(with:.opacity))
            }
            HStack(spacing:0) {
                GeometryReader { proxy in
                    VStack(spacing:0) {
                        ZStack {
                            GridBridge(model:model)
                            if model.rowCount == 0 && !model.busy && model.error == nil { VStack(spacing:10) { Text("No rows match this view").foregroundStyle(.secondary); Button("Clear Filter") { model.filterDraft = ""; model.state.filter = ""; model.reload() } } }
                        }.panelCard()
                        // The table keeps at least 150 points, so a short window shrinks the SQL panel instead.
                        ResizablePanel(edge:.bottom,size:$sqlHeight,isOpen:$model.sqlOpen,range:190...max(190,min(560,proxy.size.height-150)),gap:6) { SQLPanel(model:model,focused:$sqlFocused) }
                    }
                }
                ResizablePanel(edge:.trailing,size:$inspectorWidth,isOpen:$model.inspector,range:260...720,gap:Self.gutter) { InspectorView(model:model).panelCard() }
                rail
            }
            .padding(.leading,Self.gutter)
            .animation(Motion.panel,value:model.error)
            statusBar
        }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanFocusFilter"))) { note in if note.object as? UUID == model.id { openSQL(.filter) } }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanToggleSQL"))) { note in if note.object as? UUID == model.id { if model.sqlOpen { withAnimation(Motion.panel) { model.sqlOpen = false } } else { openSQL(model.console.mode) } } }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanGoToRow"))) { note in if note.object as? UUID == model.id { goToRow = true } }
        .sheet(isPresented:$goToRow) { VStack(alignment:.leading,spacing:16) { Text("Go to row").font(.headline); TextField("Row number",text:$rowNumber).onSubmit { jump() }; HStack { Button("Cancel") { goToRow = false }; Spacer(); Button("Go") { jump() }.keyboardShortcut(.defaultAction) } }.padding(24).frame(width:300) }
    }
    private var toolbar: some View {
        HStack(spacing:10) {
            filterChip
            Spacer(minLength:8)
            tool("arrow.clockwise","Reload from disk (⌘R)") { model.open() }
            if model.hasSavedView {
                tool("arrow.uturn.backward","Reset view: forget this file's saved filter, sorts, columns, widths and heatmaps") { model.resetView() }
                    .transition(.opacity.combined(with:.scale(scale:0.7)))
            }
            Divider().frame(height:16)
            Menu { ForEach(model.schema) { col in Button(col.name) { model.state.sorts.append(SortKey(col.name)); model.reload() } }; Divider(); Button("Clear Sort") { model.state.sorts = []; model.reload() } } label: { Image(systemName:"arrow.up.arrow.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width:30,height:24).background(RoundedRectangle(cornerRadius:6,style:.continuous).fill(model.state.sorts.isEmpty ? Color.clear : Color(nsColor:ScanTheme.accent).opacity(0.14))).help("Add sort column; Shift-click headers for multi-column sorting")
            Menu {
                let numbers = model.state.columns.filter { $0.kind == .number }
                if numbers.isEmpty { Text("No numeric columns") }
                ForEach(numbers) { col in Toggle(col.name,isOn:Binding(get:{ model.heatColumns.contains(col.name) },set:{ _ in model.toggleHeatmap(col.name) })) }
                if !model.heatColumns.isEmpty { Divider(); Button("Clear Heatmaps") { for name in model.heatColumns { model.toggleHeatmap(name) } } }
            } label: { Image(systemName:"thermometer.medium") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width:30,height:24)
                .background(RoundedRectangle(cornerRadius:6,style:.continuous).fill(model.heatColumns.isEmpty ? Color.clear : Color(nsColor:ScanTheme.accent).opacity(0.14)))
                .help("Color numeric columns as a heatmap, green at the minimum to red at the maximum")
            tool("line.3.horizontal.decrease.circle","Filter builder",active:builder) { builder.toggle() }.popover(isPresented:$builder) { FilterBuilder(model:model).frame(width:480).padding(20) }
        }.padding(.leading,12).padding(.trailing,Self.gutter).frame(height:26+Self.gutter*2)
    }
    /// The active filter, or the way into the SQL panel when there is none.
    private var filterChip: some View {
        let active = !model.state.filter.isEmpty
        let accent = Color(nsColor:ScanTheme.accent)
        return HStack(spacing:8) {
            Image(systemName:active ? "line.3.horizontal.decrease.circle.fill" : "terminal").font(.system(size:12)).foregroundStyle(active ? accent : .secondary)
            Text(active ? model.state.filter : "Filter, query or ask…").font(.system(size:12,design:.monospaced)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(active ? Color(nsColor:ScanTheme.primary) : Color.secondary)
            if active { Button { model.filterDraft = ""; model.state.filter = ""; model.reload() } label: { Image(systemName:"xmark.circle.fill").font(.system(size:12)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter") }
            else { Text("⌘J").font(.system(size:10,weight:.medium)).foregroundStyle(.tertiary).padding(.horizontal,5).padding(.vertical,1).background(RoundedRectangle(cornerRadius:4).fill(Color.primary.opacity(0.06))) }
        }
        .padding(.horizontal,11).frame(height:28).frame(maxWidth:460,alignment:.leading)
        .background(Capsule().fill(active ? accent.opacity(chipHover ? 0.2 : 0.13) : Color.primary.opacity(chipHover ? 0.07 : 0.045)))
        .overlay(Capsule().strokeBorder(active ? accent.opacity(0.35) : Color.primary.opacity(0.06)))
        .contentShape(Capsule()).onHover { chipHover = $0 }.animation(Motion.hover,value:chipHover)
        .onTapGesture { openSQL(.filter) }.help("Open the SQL panel (⌘J)")
    }
    /// Icons along the right edge open the inspector on a tab, plus the SQL panel.
    private var rail: some View {
        VStack(spacing:6) {
            railButton("doc.text.magnifyingglass","Cell (⌘I)","Cell")
            railButton("rectangle.split.3x1","Columns","Columns")
            railButton("chart.bar.xaxis","Column profile","Profile")
            railButton("square.stack.3d.up","Pivot","Pivot")
            Rectangle().fill(Color(nsColor:ScanTheme.line)).frame(width:18,height:1).padding(.vertical,2)
            tool("terminal","SQL (⌘J)",active:model.sqlOpen) { if model.sqlOpen { withAnimation(Motion.panel) { model.sqlOpen = false } } else { openSQL(model.console.mode) } }
            Spacer()
        }.padding(.leading,Self.gutter).padding(.trailing,Self.gutter)
    }
    private func railButton(_ icon: String,_ help: String,_ tab: String) -> some View {
        tool(icon,help,active:model.inspector && model.inspectorTab == tab) { panel(tab) }
    }
    private var statusBar: some View {
        HStack(spacing:12) {
            if model.busy { ProgressView().controlSize(.small); Text(model.status); Button("Cancel") { model.cancel() }.buttonStyle(.link) }
            else {
                Image(systemName:"tablecells")
                Text("\(model.rowCount.formatted(.number.locale(Locale(identifier:"en_US")))) \(model.state.groups.isEmpty ? "rows" : "groups")").contentTransition(.numericText()).animation(.snappy,value:model.rowCount)
                Divider().frame(height:12); Text("\(model.state.columns.count) columns").contentTransition(.numericText()).animation(.snappy,value:model.state.columns.count)
            }
            Spacer()
            if !model.state.sorts.isEmpty { Text(model.state.sorts.map { $0.column + ($0.ascending ? " ↑" : " ↓") }.joined(separator:", ")).lineLimit(1) }
            if !model.busy { Text(model.status).foregroundStyle(.secondary) }
            tool("square.and.arrow.up","Export current view") { model.export() }
        }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,14).frame(height:32)
    }
    private func openSQL(_ mode: SQLMode) {
        model.console.mode = mode
        withAnimation(Motion.panel) { model.sqlOpen = true }
        Task { try? await Task.sleep(for:.milliseconds(120)); sqlFocused = true }
    }
    private func jump() { if let row = Int(rowNumber.replacingOccurrences(of:",",with:"")) { model.grid?.focus(row:row-1,column:model.selectedIndex); goToRow = false } }
    private func tool(_ icon: String,_ help: String,active: Bool = false,action:@escaping ()->Void) -> some View { Button(action:action) { Image(systemName:icon).frame(width:26,height:26) }.buttonStyle(HoverButtonStyle(active:active)).help(help) }
    /// Opens the inspector on a tab, switches tabs when it is open on another one, and closes it otherwise.
    private func panel(_ tab: String) {
        if model.inspector && model.inspectorTab == tab { model.inspector = false }
        else { model.inspectorTab = tab; model.inspector = true; if tab == "Cell" { model.fetchCell() } }
    }
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
            if model.active != nil {
                Button { model.sidebar.toggle() } label: {
                    Image(systemName:"sidebar.left").frame(width:24,height:24)
                }.buttonStyle(HoverButtonStyle()).help("Toggle sidebar (⌘0)").accessibilityLabel("Toggle sidebar")
            }
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
                            .modifier(TabChrome(selected:tab === model))
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
            Button { model.newTab() } label: { Image(systemName:"plus").frame(width:24,height:24) }
                .buttonStyle(HoverButtonStyle()).help("New tab (⌘T)").accessibilityLabel("New tab")
        }
        .padding(.trailing,12).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

/// A titlebar tab's fill and border, brighter when selected and on hover.
private struct TabChrome: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius:8,style:.continuous).fill(Color.primary.opacity(selected ? 0.10 : hovering ? 0.06 : 0.025)))
            .overlay { RoundedRectangle(cornerRadius:8,style:.continuous).strokeBorder(Color.primary.opacity(selected ? 0.13 : hovering ? 0.08 : 0.04)) }
            .onHover { hovering = $0 }
            .animation(Motion.hover,value:hovering)
            .animation(Motion.hover,value:selected)
    }
}

/// A symbol and tint for a file's format, shown in tabs and the sidebar. Compressed files use the inner format.
struct FileIcon: View {
    let url: URL?
    var body: some View {
        let (symbol,tint) = Self.style(for:url)
        Image(systemName:symbol).foregroundStyle(tint).frame(width:16)
    }
    static func style(for url: URL?) -> (String,Color) {
        guard let url else { return ("doc",.secondary) }
        if url.isFileURL && (url.hasDirectoryPath || (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true) {
            return ("folder",Color(nsColor:ScanTheme.accent))
        }
        switch FileKind.guess(name:url.lastPathComponent)?.format {
        case .delimited?: return ("tablecells",.green)
        case .excel?: return ("tablecells.badge.ellipsis",.green)
        case .jsonLines?, .json?: return ("curlybraces",.orange)
        case .geoJSON?: return ("map",.orange)
        case .parquet?: return ("rectangle.split.3x1",Color(nsColor:ScanTheme.accent))
        case .sqlite?, .duckdb?: return ("cylinder.split.1x2",.purple)
        default: return ("doc.text",.secondary)
        }
    }
}

struct AccentRevisionKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues { var accentRevision: String { get { self[AccentRevisionKey.self] } set { self[AccentRevisionKey.self] = newValue } } }
