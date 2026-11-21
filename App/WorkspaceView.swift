import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanEngine
import ScanQuery
import ScanTheme

struct WorkspaceView: View {
    @Environment(\.accentRevision) private var accentRevision
    @State private var model: WindowModel
    init(model: WindowModel = WindowModel()) { _model = State(initialValue:model) }
    @AppStorage("accentHex") private var accentHex = ""
    @State private var search = ""
    @State private var searching = false
    @State private var targeted = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0
    /// The sidebar's width while its edge is dragged, so the tabs and the card follow it live.
    @State private var liveSidebar: Double?

    /// Where the title row's controls start, clear of the traffic lights. They never move, so the
    /// sidebar toggle stays under the pointer and can be clicked again to undo.
    static let titleLeading: CGFloat = 78
    /// The title row: the toggle and app name, then the tabs.
    static let titleHeight: CGFloat = WindowChrome.titleHeight
    /// The space around the card, and between it and the sidebar.
    static let gutter: CGFloat = 8
    /// Where the tabs may start at the earliest: after the toggle and the app name.
    private static let tabsMinLeading: CGFloat = titleLeading + 112
    private static let sidebarRange: ClosedRange<Double> = 190...380

    private var sidebarOpen: Bool { model.sidebar && model.active != nil }
    /// The sidebar's current width: what it is being dragged to, its saved width, or zero when closed.
    private var sidebarShown: CGFloat { sidebarOpen ? CGFloat(liveSidebar ?? min(sidebarWidth, Self.sidebarRange.upperBound)) : 0 }
    /// How far right of the card's leading edge the tabs start. With the sidebar open the first tab
    /// sits flush with the card; with it closed the card reaches under the toggle and the tabs stay put.
    private var tabJoin: CGFloat { max(0, Self.tabsMinLeading - (sidebarShown + Self.gutter)) }
    /// The selected tab is the first one, so its edge and the card's top-left corner meet.
    private var firstSelected: Bool { model.tabs.first === model }

    var body: some View {
        ZStack(alignment:.topLeading) {
            WindowDragArea().frame(height:Self.titleHeight)
            HStack(spacing:0) {
                ResizablePanel(edge:.leading,size:$sidebarWidth,isOpen:Binding(get:{ sidebarOpen },set:{ model.setSidebar($0) }),range:Self.sidebarRange,gap:Self.gutter,liveSize:$liveSidebar,handleInset:Self.titleHeight) { sidebar }
                VStack(spacing:0) {
                    tabRow
                    card
                }
                // With the sidebar closed, the gutter its handle provided moves here, so the card keeps its inset.
                .padding(.leading,sidebarOpen ? 0 : Self.gutter)
                .padding([.trailing,.bottom],Self.gutter)
            }
            titleControls
        }
        .animation(Motion.panel,value:sidebarOpen)
        .animation(liveSidebar == nil ? Motion.release : nil,value:sidebarWidth)
        .background(Color(nsColor:ScanTheme.frame))
        .ignoresSafeArea()
        .tint(Color.scanAccent).environment(\.accentRevision,accentHex)
        .focusedSceneValue(\.scanWindow,model)
        .onDrop(of:[UTType.fileURL],isTargeted:$targeted) { providers in
            for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in model.open([url]) } } } }; return true
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius:12,style:.continuous).strokeBorder(Color.scanAccent,lineWidth:2).padding(6)
                    .shadow(color:Color.scanAccent.opacity(0.6),radius:10)
                    .background(RoundedRectangle(cornerRadius:12,style:.continuous).fill(Color.scanAccent.opacity(0.05)).padding(6))
                    .allowsHitTesting(false).transition(.opacity.combined(with:.scale(scale:1.01)))
            }
        }
        .animation(Motion.hover,value:targeted)
        .background(NativeWindowBridge(model:model))
    }

    /// The sidebar toggle and app name, at a fixed place beside the traffic lights.
    private var titleControls: some View {
        HStack(spacing:8) {
            Button { model.setSidebar(!model.sidebar) } label: { Image(systemName:"sidebar.left") }
                .buttonStyle(IconButtonStyle(active:false))
                .help(sidebarOpen ? "Hide sidebar (⌘0)" : "Show sidebar (⌘0)").accessibilityLabel("Toggle sidebar")
                .disabled(model.active == nil)
            HStack(spacing:6) {
                Image(nsImage:NSApp.applicationIconImage).resizable().interpolation(.high).frame(width:16,height:16)
                Text("Scan").font(.system(size:13,weight:.semibold))
            }.allowsHitTesting(false)
        }
        // The same height and bottom edge as a tab, so the toggle, the name and the tab titles share a center line.
        .padding(.leading,Self.titleLeading).frame(height:TabMetrics.height).padding(.top,Self.titleHeight - TabMetrics.height)
    }

    private var tabRow: some View {
        TabStrip(model:model,join:tabJoin)
        // The strip's own inset leaves room for the selected tab's curved feet; the card's edge is a foot further left.
        .padding(.leading,tabJoin - TabMetrics.foot)
        .frame(height:Self.titleHeight + TabMetrics.overlap,alignment:.bottom)
        // The strip hangs over the card's top edge, so the selected tab hides the border beneath it.
        .padding(.bottom,-TabMetrics.overlap)
        .zIndex(1)
    }

    private var card: some View {
        let shape = CardShape(join:firstSelected ? tabJoin : 1000)
        return VStack(spacing:0) {
            if let doc = model.active { DocumentView(model:doc).id(doc.id) }
            else { empty }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(Color(nsColor:ScanTheme.chrome))
        .clipShape(shape)
        .overlay(shape.stroke(Color(nsColor:ScanTheme.line),lineWidth:1))
    }

    private var sidebar: some View {
        VStack(alignment:.leading,spacing:10) {
            Color.clear.frame(height:Self.titleHeight)
            ScrollView {
                VStack(alignment:.leading,spacing:2) {
                    if let doc = model.active {
                        if doc.tables.count > 1 {
                            sectionLabel("Tables",count:doc.tables.count)
                            ForEach(doc.tables.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) },id:\.self) { table in
                                Button { doc.open(table:table) } label: {
                                    HStack(spacing:8) {
                                        Image(systemName:table == doc.selectedTable ? "tablecells.fill" : "tablecells").foregroundStyle(table == doc.selectedTable ? Color.scanAccent : .secondary).frame(width:16)
                                        Text(table).lineLimit(1); Spacer(minLength:0)
                                    }.frame(height:28).rowHighlight(selected:table == doc.selectedTable)
                                }.buttonStyle(.plain)
                            }
                            Color.clear.frame(height:12)
                        }
                        columnsHeader(count:doc.schema.count)
                        ForEach(doc.schema.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { col in
                            columnRow(col,in:doc)
                        }
                    }
                }.padding(.bottom,8)
            }.scrollIndicators(.never)
            HStack {
                Button { SettingsWindow.show() } label: { Image(systemName:"gearshape") }.buttonStyle(IconButtonStyle()).help("Settings")
                Spacer()
                Text("READ ONLY").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(0.8).foregroundStyle(.secondary)
                    .padding(.horizontal,7).padding(.vertical,3).background(Capsule().fill(Color.primary.opacity(0.05)))
            }.padding(.bottom,10)
        }.padding(.leading,10).padding(.trailing,2).background(Color(nsColor:ScanTheme.frame))
    }
    /// The Columns heading, which becomes a search field when its magnifying glass is clicked.
    @ViewBuilder private func columnsHeader(count: Int) -> some View {
        if searching {
            SoftSearchField(prompt:"Search columns",text:$search,autofocus:true) { withAnimation(Motion.hover) { searching = false } }
                .padding(.bottom,4)
                .transition(.opacity.combined(with:.scale(scale:0.96,anchor:.trailing)))
        } else {
            HStack(spacing:6) {
                Text("Columns").font(.system(size:11,weight:.semibold)).foregroundStyle(Color(nsColor:ScanTheme.muted))
                countBadge(count)
                Spacer()
                Button { withAnimation(Motion.hover) { searching = true } } label: { Image(systemName:"magnifyingglass").font(.system(size:11,weight:.medium)) }
                    .buttonStyle(IconButtonStyle()).help("Search columns").accessibilityLabel("Search columns")
            }
            .padding(.leading,8).frame(height:28)
            .transition(.opacity)
        }
    }
    private func columnRow(_ col: Column,in doc: DocumentModel) -> some View {
        let visible = doc.state.columns.contains(col)
        let semantic = doc.semantics[col.name]
        return Group {
            Button { if let index = doc.state.columns.firstIndex(of:col) { doc.grid?.focus(row:doc.selectedRow,column:index) } } label: {
                HStack(spacing:8) {
                    Text(semantic?.glyph ?? col.kind.glyph).font(.system(size:10.5,design:.monospaced))
                        .foregroundStyle(semantic == nil ? Color(nsColor:ScanTheme.muted) : Color.scanAccent).frame(width:18)
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
            }.buttonStyle(.plain)
            .help(semantic.map { "\(col.name): \(col.type.lowercased()), shown as \($0.label)" } ?? "\(col.name): \(col.type.lowercased())")
            .contextMenu {
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
    private func countBadge(_ count: Int) -> some View {
        Text(String(count)).font(.system(size:10,weight:.medium).monospacedDigit()).foregroundStyle(.secondary)
            .padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentTransition(.numericText()).animation(Motion.hover,value:count)
    }
    private func sectionLabel(_ name: String,count: Int) -> some View {
        HStack(spacing:6) {
            Text(name).font(.system(size:11,weight:.semibold)).foregroundStyle(Color(nsColor:ScanTheme.muted))
            countBadge(count)
            Spacer()
        }.padding(.leading,8).frame(height:28)
    }
    private var empty: some View {
        VStack(spacing:16) {
            Spacer(); Image(systemName:"tablecells").font(.system(size:46,weight:.ultraLight)).foregroundStyle(Color.scanAccent)
            Text("A closer look at your data.").font(.system(size:24,weight:.medium))
            Text("Drop a CSV, TSV, JSON, Parquet, Excel, SQLite or DuckDB file, or a folder of them").foregroundStyle(.secondary)
            Text("or open a remote file by URL, including Hugging Face datasets").font(.callout).foregroundStyle(.tertiary)
            HStack(spacing:10) {
                Button("Open File…") { model.choose() }.keyboardShortcut("o").buttonStyle(.borderedProminent)
                Button("Open URL…") { model.chooseRemote() }
            }.padding(.top,6)
            let recent = NSDocumentController.shared.recentDocumentURLs.prefix(5)
            if !recent.isEmpty { VStack(alignment:.leading,spacing:8) { Text("RECENT").font(.caption).foregroundStyle(.secondary); ForEach(Array(recent),id:\.self) { url in Button(url.lastPathComponent) { model.open([url]) }.buttonStyle(AccentLinkStyle()) } }.padding(.top,24) }
            Spacer(); Text("Local files. Native speed. Always read-only.").font(.caption).foregroundStyle(.secondary).padding(.bottom,28)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct DocumentView: View {
    @Environment(\.accentRevision) private var accentRevision
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
    private static let iconSpacing: CGFloat = 6
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
                            // A query's rows take the table's place; the table stays loaded underneath.
                            if let result = model.queryResult { QueryResultView(model:model,result:result).transition(.opacity) }
                        }.panelCard()
                        // The table keeps at least 150 points, so a short window shrinks the SQL panel instead,
                        // down to its header and a line of editor, rather than pushing past the window's edge.
                        let room = max(0,proxy.size.height - 150 - 6)
                        let lowest = min(190,max(112,room))
                        ResizablePanel(edge:.bottom,size:$sqlHeight,isOpen:$model.sqlOpen,range:lowest...max(lowest,min(560,room)),gap:6) { SQLPanel(model:model,focused:$sqlFocused,collapse:closeSQL) }
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
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanToggleSQL"))) { note in if note.object as? UUID == model.id { if model.sqlOpen { closeSQL() } else { openSQL(model.console.mode) } } }
        .onReceive(NotificationCenter.default.publisher(for:.init("ScanGoToRow"))) { note in if note.object as? UUID == model.id { goToRow = true } }
        .sheet(isPresented:$goToRow) { VStack(alignment:.leading,spacing:16) { Text("Go to row").font(.headline); TextField("Row number",text:$rowNumber).onSubmit { jump() }; HStack { Button("Cancel") { goToRow = false }; Spacer(); Button("Go") { jump() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(24).frame(width:300).tint(Color.scanAccent) }
    }
    /// The filter chip, then the view's tools. Icons share the rail's 28-point grid and spacing, and the
    /// last one sits directly above the rail's column.
    private var toolbar: some View {
        HStack(spacing:Self.iconSpacing) {
            filterChip.padding(.trailing,8)
            Spacer(minLength:0)
            tool("arrow.clockwise","Reload from disk (⌘R)") { model.open() }
            if model.hasSavedView {
                tool("arrow.uturn.backward","Reset view: forget this file's saved filter, sorts, columns, widths and heatmaps") { model.resetView() }
                    .transition(.opacity.combined(with:.scale(scale:0.7)))
            }
            separator(vertical:true)
            IconMenu(icon:"arrow.up.arrow.down",active:!model.state.sorts.isEmpty,help:"Add sort column; Shift-click headers for multi-column sorting") {
                ForEach(model.schema) { col in Button(col.name) { model.state.sorts.append(SortKey(col.name)); model.reload() } }
                Divider(); Button("Clear Sort") { model.state.sorts = []; model.reload() }
            }
            IconMenu(icon:"thermometer.medium",active:!model.heatColumns.isEmpty,help:"Color numeric columns as a heatmap, green at the minimum to red at the maximum") {
                let numbers = model.state.columns.filter { $0.kind == .number }
                if numbers.isEmpty { Text("No numeric columns") }
                ForEach(numbers) { col in Toggle(col.name,isOn:Binding(get:{ model.heatColumns.contains(col.name) },set:{ _ in model.toggleHeatmap(col.name) })) }
                if !model.heatColumns.isEmpty { Divider(); Button("Clear Heatmaps") { for name in model.heatColumns { model.toggleHeatmap(name) } } }
            }
            tool("line.3.horizontal.decrease.circle","Filter builder",active:builder) { builder.toggle() }.popover(isPresented:$builder) { FilterBuilder(model:model).frame(width:480).padding(20) }
            separator(vertical:true)
            tool("square.and.arrow.up","Export view (⇧⌘E)") { model.export() }.disabled(model.busy)
        }
        .padding(.leading,Self.gutter).padding(.trailing,Self.gutter)
        .frame(height:IconButtonStyle.size+Self.gutter*2)
        .animation(Motion.hover,value:model.hasSavedView)
    }
    /// The active filter, or the way into the SQL panel when there is none.
    private var filterChip: some View {
        let active = !model.state.filter.isEmpty
        let accent = Color.scanAccent
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
        VStack(spacing:Self.iconSpacing) {
            railButton("doc.text.magnifyingglass","Cell (⌘I)","Cell")
            railButton("rectangle.split.3x1","Columns","Columns")
            railButton("chart.bar.xaxis","Column profile","Profile")
            railButton("square.stack.3d.up","Pivot","Pivot")
            separator(vertical:false)
            tool("terminal","SQL (⌘J)",active:model.sqlOpen) { if model.sqlOpen { closeSQL() } else { openSQL(model.console.mode) } }
            Spacer(minLength:0)
        }.padding(.horizontal,Self.gutter)
    }
    /// A hairline between groups of icons, taking the same room along the row or column as the spacing.
    private func separator(vertical: Bool) -> some View {
        Rectangle().fill(Color(nsColor:ScanTheme.line))
            .frame(width:vertical ? 1 : 16,height:vertical ? 16 : 1)
            .padding(vertical ? .horizontal : .vertical,2)
    }
    private func railButton(_ icon: String,_ help: String,_ tab: String) -> some View {
        tool(icon,help,active:model.inspector && model.inspectorTab == tab) { panel(tab) }
    }
    private var statusBar: some View {
        HStack(spacing:12) {
            if model.busy { ProgressView().controlSize(.small); Text(model.status); Button("Cancel") { model.cancel() }.buttonStyle(AccentLinkStyle()) }
            else {
                Image(systemName:"tablecells")
                if let result = model.queryResult {
                    Text("\(result.page.count.formatted(.number.locale(Locale(identifier:"en_US")))) result rows"); Divider().frame(height:12); Text("\(result.columns.count) columns")
                } else {
                Text("\(model.rowCount.formatted(.number.locale(Locale(identifier:"en_US")))) \(model.state.groups.isEmpty ? "rows" : "groups")").contentTransition(.numericText()).animation(.snappy,value:model.rowCount)
                Divider().frame(height:12); Text("\(model.state.columns.count) columns").contentTransition(.numericText()).animation(.snappy,value:model.state.columns.count)
                }
            }
            Spacer()
            if model.queryResult == nil, !model.state.sorts.isEmpty { Text(model.state.sorts.map { $0.column + ($0.ascending ? " ↑" : " ↓") }.joined(separator:", ")).lineLimit(1) }
            if !model.busy && !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary).lineLimit(1) }
        }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,14).frame(height:30)
    }
    /// Collapses the SQL panel and hands the keyboard back to the table, so the hidden editor keeps no focus.
    private func closeSQL() {
        withAnimation(Motion.panel) { model.sqlOpen = false }
        sqlFocused = false
        model.grid?.focus(row:model.selectedRow,column:model.selectedIndex)
    }
    private func openSQL(_ mode: SQLMode) {
        model.console.mode = mode
        withAnimation(Motion.panel) { model.sqlOpen = true }
        Task { try? await Task.sleep(for:.milliseconds(120)); sqlFocused = true }
    }
    private func jump() { if let row = Int(rowNumber.replacingOccurrences(of:",",with:"")) { model.grid?.focus(row:row-1,column:model.selectedIndex); goToRow = false } }
    private func tool(_ icon: String,_ help: String,active: Bool = false,action:@escaping ()->Void) -> some View { Button(action:action) { Image(systemName:icon) }.buttonStyle(IconButtonStyle(active:active)).help(help) }
    /// Opens the inspector on a tab, switches tabs when it is open on another one, and closes it otherwise.
    private func panel(_ tab: String) {
        if model.inspector && model.inspectorTab == tab { model.inspector = false }
        else { model.inspectorTab = tab; model.inspector = true; if tab == "Cell" { model.fetchCell() } }
    }
}

/// The window's tabs. The selected one shares the card's fill and flows into it; the others are
/// plain labels with a hover fill and thin dividers between them.
private struct TabStrip: View {
    let model: WindowModel
    /// How far right of the card's edge the strip starts, which sets the first tab's left foot.
    let join: CGFloat
    var body: some View {
        let tabs = model.tabs
        ScrollViewReader { scroll in
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:0) {
                    ForEach(Array(tabs.enumerated()),id:\.element.id) { index, tab in
                        let selected = tab === model
                        // A divider separates two unselected tabs; it hides next to the selected one.
                        let divider = index + 1 < tabs.count && !selected && tabs[index + 1] !== model
                        TabItem(tab:tab,selected:selected,join:index == 0 ? join : 1000,divider:divider)
                            .id(tab.id)
                    }
                    // New tab, right after the last tab.
                    Button { model.newTab() } label: { Image(systemName:"plus").font(.system(size:12,weight:.medium)) }
                        .buttonStyle(IconButtonStyle()).help("New tab (⌘T)").accessibilityLabel("New tab")
                        .padding(.leading,4)
                }
                .padding(.horizontal,TabMetrics.foot)
                // Room below the tabs, inside the scroll view's clip, for the selected tab to cover the card's top border.
                .padding(.bottom,TabMetrics.overlap)
                .frame(height:WorkspaceView.titleHeight + TabMetrics.overlap,alignment:.bottom)
            }
            .onAppear { scroll.scrollTo(model.id) }
            .onChange(of:NativeWindows.shared.revision) { withAnimation(Motion.panel) { scroll.scrollTo(model.id) } }
        }
    }
}

private struct TabItem: View {
    let tab: WindowModel
    let selected: Bool
    let join: CGFloat
    let divider: Bool
    @State private var hovering = false
    var body: some View {
        let title = tab.active?.title ?? "New Tab"
        HStack(spacing:7) {
            FileIcon(url:tab.active?.url)
            Text(title).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color(nsColor:ScanTheme.primary) : Color.secondary)
            Spacer(minLength:0)
            Button { NativeWindows.shared.closeTab(tab) } label: {
                Image(systemName:"xmark").font(.system(size:9,weight:.semibold)).frame(width:18,height:18)
            }
            .buttonStyle(HoverButtonStyle())
            .opacity(selected || hovering ? 1 : 0)
            .help("Close tab").accessibilityLabel("Close \(title)")
        }
        .font(.system(size:12,weight:selected ? .medium : .regular))
        .padding(.leading,12).padding(.trailing,8)
        .frame(minWidth:120,maxWidth:220,minHeight:TabMetrics.height,maxHeight:TabMetrics.height)
        .background {
            if selected {
                ZStack {
                    TabShape(join:join).fill(Color(nsColor:ScanTheme.chrome))
                    TabShape(join:join,closed:false).stroke(Color(nsColor:ScanTheme.line),lineWidth:1)
                }
            } else {
                RoundedRectangle(cornerRadius:8,style:.continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)).padding(.vertical,3).padding(.horizontal,2)
            }
        }
        .overlay(alignment:.trailing) {
            Rectangle().fill(Color(nsColor:ScanTheme.line)).frame(width:1,height:14).opacity(divider && !hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { NativeWindows.shared.select(tab) }
        .onHover { hovering = $0 }
        .animation(Motion.hover,value:hovering)
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
                    guard let dragged = NativeWindows.shared.models.first(where: { $0.id == id }), dragged !== tab else { return }
                    NativeWindows.shared.move(dragged,before:tab)
                }
            }
            return true
        }
    }
}

/// A symbol and tint for a file's format, shown in tabs and the sidebar. Compressed files use the inner format.
struct FileIcon: View {
    @Environment(\.accentRevision) private var accentRevision
    let url: URL?
    var body: some View {
        let (symbol,tint) = Self.style(for:url)
        Image(systemName:symbol).foregroundStyle(tint).frame(width:16)
    }
    static func style(for url: URL?) -> (String,Color) {
        guard let url else { return ("doc",.secondary) }
        if url.isFileURL && (url.hasDirectoryPath || (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true) {
            return ("folder",Color.scanAccent)
        }
        switch FileKind.guess(name:url.lastPathComponent)?.format {
        case .delimited?: return ("tablecells",.green)
        case .excel?: return ("tablecells.badge.ellipsis",.green)
        case .jsonLines?, .json?: return ("curlybraces",.orange)
        case .geoJSON?: return ("map",.orange)
        case .parquet?: return ("rectangle.split.3x1",Color.scanAccent)
        case .sqlite?, .duckdb?: return ("cylinder.split.1x2",.purple)
        default: return ("doc.text",.secondary)
        }
    }
}

struct AccentRevisionKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues { var accentRevision: String { get { self[AccentRevisionKey.self] } set { self[AccentRevisionKey.self] = newValue } } }
