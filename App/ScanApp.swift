import SwiftUI
import AppKit
import ScanEngine
import ScanTheme

/// Each title-bar tab owns its document and retained hosting controller.
@MainActor @Observable final class WindowModel: Identifiable {
    let id = UUID()
    var document: DocumentModel?
    var sidebar = true
    weak var window: NSWindow?
    @ObservationIgnored var tabResponder: NativeTabResponder?
    var active: DocumentModel? { document }
    var tabs: [WindowModel] {
        _ = NativeWindows.shared.revision
        return NativeWindows.shared.models.filter { $0.window === window }
    }
    var documents: [DocumentModel] { tabs.compactMap(\.document) }
    var selection: UUID? {
        get { document?.id }
        set {
            guard let model = NativeWindows.shared.models.first(where: { $0.document?.id == newValue }) else { return }
            NativeWindows.shared.select(model)
        }
    }
    func open(_ urls: [URL]) {
        var target = self
        for url in urls {
            if let existing = documents.first(where: { $0.url == url }) {
                selection = existing.id
                continue
            }
            if target.document != nil { target = NativeWindows.shared.create(tabbedWith: target.window) }
            let doc = DocumentModel(url:url)
            target.document = doc
            target.window?.title = doc.title
            doc.open()
            NativeWindows.shared.select(target)
        }
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // A folder opens as one table of its Parquet, CSV or JSON Lines files.
        panel.canChooseDirectories = true
        panel.message = "Open CSV, TSV, JSON, JSONL, GeoJSON (gzip or zstd), Parquet, Excel, SQLite or DuckDB files, or a folder of data files"
        if panel.runModal() == .OK { open(panel.urls) }
    }
    /// Opens a remote file URL after normalizing Hugging Face /blob/ links to /resolve/.
    func chooseRemote() {
        guard let input = OpenURLPanel.run() else { return }
        do {
            let url = try RemoteFile.normalizedURL(input)
            open([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot Open URL"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    func newTab() { NativeWindows.shared.create(tabbedWith: window) }
    /// Shows or hides the sidebar in every tab of this window, so switching tabs keeps the layout.
    func setSidebar(_ open: Bool) { for tab in tabs where tab.sidebar != open { tab.sidebar = open }; sidebar = open }
    func close(_ id: UUID) {
        if let model = NativeWindows.shared.models.first(where: { $0.document?.id == id }) { NativeWindows.shared.closeTab(model) }
    }
    func cycle(_ delta: Int) {
        let tabs = tabs
        guard let index = tabs.firstIndex(where: { $0 === self }), !tabs.isEmpty else { return }
        NativeWindows.shared.select(tabs[(index + delta + tabs.count) % tabs.count])
    }
}

/// Handles the standard AppKit + button through the window's responder chain.
@MainActor final class NativeTabResponder: NSResponder {
    weak var window: NSWindow?
    init(model: WindowModel) { self.window = model.window; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func newWindowForTab(_ sender: Any?) { NativeWindows.shared.activeModel(for:window)?.newTab() }
}

@MainActor @Observable final class NativeWindows {
    static let shared = NativeWindows()
    var models: [WindowModel] = []
    var revision = 0
    @ObservationIgnored private var controllers: [NSWindowController] = []
    @ObservationIgnored private var hosts: [UUID:NSViewController] = [:]
    @ObservationIgnored private var selected: [ObjectIdentifier:UUID] = [:]
    @ObservationIgnored private var consumedLaunchURLs = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.closed(window) }
        })
    }

    func activeModel(for window: NSWindow?) -> WindowModel? {
        guard let window else { return nil }
        return models.first { $0.id == selected[ObjectIdentifier(window)] }
    }

    func attach(_ model: WindowModel, to window: NSWindow) {
        guard model.window !== window else { return }
        model.window = window
        window.tabbingMode = .disallowed
        WindowChrome.apply(to:window)
        window.title = model.active?.title ?? "Scan"
        let responder = NativeTabResponder(model:model)
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
        model.tabResponder = responder
        if !models.contains(where: { $0 === model }) { models.append(model) }
        selected[ObjectIdentifier(window)] = model.id
        if let host = window.contentViewController { hosts[model.id] = host }
        else if let content = window.contentView { let host = NSViewController(); host.view = content; hosts[model.id] = host }
        if !consumedLaunchURLs {
            consumedLaunchURLs = true
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.compactMap { argument -> URL? in
                if let url = URL(string: argument), RemoteFile.isRemote(url) {
                    return url
                }
                let url = URL(fileURLWithPath: argument)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            let urls = args + AppDelegate.pendingURLs
            AppDelegate.pendingURLs = []
            DispatchQueue.main.async { [weak model] in model?.open(urls) }
        }
    }

    @discardableResult func create(tabbedWith parent: NSWindow? = nil) -> WindowModel {
        let model = WindowModel()
        let host = NSHostingController(rootView:WorkspaceView(model:model))
        hosts[model.id] = host
        if let parent, let current = activeModel(for:parent) {
            // Retain each tab's view, including its grid scroll and focus state.
            if let existing = parent.contentViewController { hosts[current.id] = existing }
            model.window = parent
            model.sidebar = current.sidebar
            models.append(model)
            select(model)
        } else {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:820),
                                  styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],
                                  backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width:850,height:500)
            window.tabbingMode = .disallowed
            let controller = NSWindowController(window:window)
            controllers.append(controller)
            window.contentViewController = host
            attach(model,to:window)
            window.setContentSize(NSSize(width:1320,height:820))
            window.center()
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
        revision += 1
        return model
    }

    func select(_ model: WindowModel) {
        guard let window = model.window else { return }
        if activeModel(for:window) !== model {
            if let current = activeModel(for:window), let host = window.contentViewController { hosts[current.id] = host }
            let frame = window.frame
            selected[ObjectIdentifier(window)] = model.id
            if let host = hosts[model.id] { window.contentViewController = host; window.setFrame(frame,display:true) }
        }
        window.title = model.active?.title ?? "Scan"
        window.makeKeyAndOrderFront(nil)
        revision += 1
    }

    func closeTab(_ model: WindowModel) {
        guard let window = model.window else { return }
        let tabs = model.tabs
        guard tabs.count > 1 else { window.performClose(nil); return }
        if activeModel(for:window) === model, let index = tabs.firstIndex(where: { $0 === model }) {
            select(tabs[index == tabs.count - 1 ? index - 1 : index + 1])
        }
        model.document?.close()
        model.document = nil
        hosts.removeValue(forKey:model.id)
        models.removeAll { $0 === model }
        revision += 1
    }

    func move(_ model: WindowModel, before target: WindowModel) {
        guard model !== target, let source = model.window, let destination = target.window else { return }
        if source !== destination {
            let others = model.tabs.filter { $0 !== model }
            if activeModel(for:source) === model, let next = others.first { select(next) }
            model.window = destination
            model.sidebar = target.sidebar
            if others.isEmpty { source.performClose(nil) }
        }
        models.removeAll { $0 === model }
        if let index = models.firstIndex(where: { $0 === target }) { models.insert(model,at:index) }
        select(model)
    }

    func detach(_ model: WindowModel) {
        guard model.tabs.count > 1 else { return }
        let destination = create()
        destination.document = model.document
        destination.sidebar = model.sidebar
        model.document = nil
        closeTab(model)
        select(destination)
    }

    func closed(_ window: NSWindow) {
        let tabs = models.filter { $0.window === window }
        for model in tabs { model.document?.close(); model.document = nil; hosts.removeValue(forKey:model.id) }
        models.removeAll { $0.window === window }
        selected.removeValue(forKey:ObjectIdentifier(window))
        controllers.removeAll { $0.window === window }
        revision += 1
    }
}

/// Re-attaches a workspace if AppKit moves its view to another window.
struct NativeWindowBridge: NSViewRepresentable {
    let model: WindowModel
    func makeNSView(context: Context) -> WindowAttachmentView { WindowAttachmentView(model:model) }
    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        if let window = view.window { NativeWindows.shared.attach(model,to:window) }
    }
}
final class WindowAttachmentView: NSView {
    let model: WindowModel
    init(model: WindowModel) { self.model = model; super.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { NativeWindows.shared.attach(model,to:window) }
    }
}
struct WindowKey: FocusedValueKey { typealias Value = WindowModel }
extension FocusedValues { var scanWindow: WindowModel? { get { self[WindowKey.self] } set { self[WindowKey.self] = newValue } } }
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    private var launched = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = ScanAppearance.current.nsAppearance
        NSWindow.allowsAutomaticWindowTabbing = false
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { try? await Task.sleep(for: .seconds(3)); await Updater.check(manual: false) }
        launched = true
        // Every window, including the first, comes from NativeWindows so it gets the titlebar
        // tabs. Creating it attaches the tab model, which opens URLs that arrived during launch.
        if NativeWindows.shared.models.isEmpty { NativeWindows.shared.create() }
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NativeWindows.shared.create() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { Self.pendingURLs += urls; return }
        let model = NativeWindows.shared.activeModel(for:NSApp.keyWindow)
            ?? NativeWindows.shared.activeModel(for:NativeWindows.shared.models.first?.window)
            ?? NativeWindows.shared.create()
        model.open(urls)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct ScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // No WindowGroup: SwiftUI would claim Finder's open-file events for it and configure its
        // window outside NativeWindows. AppDelegate creates every workspace window instead.
        // Settings opens a window Scan makes itself (see SettingsWindow); this scene only satisfies App.
        Settings { EmptyView() }
            .commands { ScanCommands() }
    }
}
struct ScanCommands: Commands {
    @FocusedValue(\.scanWindow) private var focusedWindow
    private var window: WindowModel? {
        _ = focusedWindow
        return NativeWindows.shared.activeModel(for:NSApp.keyWindow)
    }
    var body: some Commands {
        CommandGroup(replacing:.appSettings) {
            Button("Settings…") { SettingsWindow.show() }.keyboardShortcut(",")
        }
        CommandGroup(replacing:.newItem) {
            Button("Open…") { (window ?? NativeWindows.shared.create()).choose() }.keyboardShortcut("o")
            Button("Open URL…") { (window ?? NativeWindows.shared.create()).chooseRemote() }.keyboardShortcut("o",modifiers:[.command,.shift])
            Button("New Tab") { if let window { window.newTab() } else { NativeWindows.shared.create() } }.keyboardShortcut("t")
            Button("New Window") { NativeWindows.shared.create() }.keyboardShortcut("n")
            Button("Close Tab") { if let window { NativeWindows.shared.closeTab(window) } else { NSApp.keyWindow?.performClose(nil) } }.keyboardShortcut("w")
        }
        CommandGroup(after:.appInfo) { Button("Check for Updates…") { Task { await Updater.check(manual: true) } } }
        CommandGroup(after:.saveItem) { Button("Export View…") { window?.active?.export() }.keyboardShortcut("e",modifiers:[.command,.shift]) }
        CommandMenu("Data") {
            Button("Reload from Disk") { window?.active?.open() }.keyboardShortcut("r")
            Button("Cancel Query") { window?.active?.cancel() }.keyboardShortcut(".")
            Button("Inspect Cell") { window?.active?.inspect() }.keyboardShortcut("i")
            Button("Go to Row…") { NotificationCenter.default.post(name:.init("ScanGoToRow"),object:window?.active?.id) }.keyboardShortcut("l")
            Button("Focus Filter") { NotificationCenter.default.post(name:.init("ScanFocusFilter"),object:window?.active?.id) }.keyboardShortcut("f")
            Button("Toggle SQL Panel") { NotificationCenter.default.post(name:.init("ScanToggleSQL"),object:window?.active?.id) }.keyboardShortcut("j")
            Button("Sort Focused Column") { if let doc = window?.active { doc.sort(doc.selectedIndex,add:false) } }.keyboardShortcut("s",modifiers:[.command,.option])
            Button("Group by Focused Column") { if let doc = window?.active, doc.state.columns.indices.contains(doc.selectedIndex) { doc.group(doc.state.columns[doc.selectedIndex]) } }.keyboardShortcut("g",modifiers:[.command,.option])
            Button("Hide Focused Column") { if let doc = window?.active, doc.state.columns.indices.contains(doc.selectedIndex) { doc.hide(doc.state.columns[doc.selectedIndex]) } }.keyboardShortcut("h",modifiers:[.command,.option])
            Divider()
            Button("Clear Remote Download Cache") { _ = RemoteParquet.clearCache() }
        }
        CommandGroup(after:.sidebar) {
            Button("Toggle Sidebar") { if let window { window.setSidebar(!window.sidebar) } }.keyboardShortcut("0")
            Button("Next Tab") { window?.cycle(1) }.keyboardShortcut(.tab,modifiers:.control)
            Button("Previous Tab") { window?.cycle(-1) }.keyboardShortcut(.tab,modifiers:[.control,.shift])
        }
    }
}
/// Asks for a remote file URL. Hugging Face /blob/ links are accepted as well.
@MainActor enum OpenURLPanel {
    static func run() -> URL? {
        let alert = NSAlert()
        alert.messageText = "Open Remote File"
        alert.informativeText = "Paste an HTTPS, Hugging Face, s3://, gs:// or r2:// URL to a data file. Private buckets use the keys in Settings → Cloud Storage. For Parquet, only the parts needed for the current view are downloaded; other formats are downloaded in full."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        field.placeholderString = "https://huggingface.co/datasets/org/name/blob/main/file.parquet"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }
}

/// The window's title bar: transparent, in the frame color, with no separator, and as tall as the
/// tab row. The tabs are drawn by the workspace view under the title bar, so the selected tab can
/// merge into the content card. The traffic lights, the sidebar toggle, the app name and the tab
/// titles all share one center line, `centerY` points below the top edge.
@MainActor enum WindowChrome {
    static let titleHeight: CGFloat = 40
    static var centerY: CGFloat { titleHeight - TabMetrics.height / 2 }
    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.representedURL = nil
        window.toolbar = nil
        window.backgroundColor = ScanTheme.frame
        // An empty accessory sets the title bar's height. It ignores clicks, which pass to the tabs below it.
        if !window.titlebarAccessoryViewControllers.contains(where: { $0 is TitlebarSpacer }) {
            window.addTitlebarAccessoryViewController(TitlebarSpacer())
        }
        TrafficLights.attach(to:window)
    }
}

/// Keeps the traffic lights on the title row's center line. AppKit lays them out again during its
/// own layout passes (resizes, key changes, full screen), so a move made inside one of those passes
/// is overwritten. Each placement is therefore deferred to the next turn of the run loop, after the pass.
@MainActor final class TrafficLights {
    private static var attached = Set<ObjectIdentifier>()
    static func attach(to window: NSWindow) {
        defer { schedule(window) }
        guard attached.insert(ObjectIdentifier(window)).inserted else { return }
        var tokens: [NSObjectProtocol] = []
        let center = NotificationCenter.default
        for button in buttons(of:window) {
            button.postsFrameChangedNotifications = true
            tokens.append(center.addObserver(forName:NSView.frameDidChangeNotification,object:button,queue:.main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { schedule(window) } }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification] {
            tokens.append(center.addObserver(forName:name,object:window,queue:.main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { schedule(window) } }
            })
        }
        tokens.append(center.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { _ in
            for token in tokens { center.removeObserver(token) }
            MainActor.assumeIsolated { attached.remove(ObjectIdentifier(window)) }
        })
    }
    private static func buttons(of window: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }
    private static func schedule(_ window: NSWindow) {
        DispatchQueue.main.async { MainActor.assumeIsolated { place(window) } }
    }
    static func place(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        for button in buttons(of:window) {
            guard let superview = button.superview else { continue }
            // The center line in window coordinates, converted to the buttons' own view.
            let center = superview.convert(NSPoint(x:0,y:window.frame.height - WindowChrome.centerY),from:nil)
            let y = (center.y - button.frame.height / 2).rounded()
            if abs(button.frame.origin.y - y) > 0.5 { button.setFrameOrigin(NSPoint(x:button.frame.origin.x,y:y)) }
        }
    }
}
final class TitlebarSpacer: NSTitlebarAccessoryViewController {
    private final class PassThrough: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    override func loadView() { view = PassThrough(frame:NSRect(x:0,y:0,width:1,height:WindowChrome.titleHeight - 28)) }
    override init(nibName: NSNib.Name?, bundle: Bundle?) { super.init(nibName:nibName,bundle:bundle); layoutAttribute = .bottom }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
