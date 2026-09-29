import SwiftUI
import AppKit
import ScanEngine

@MainActor @Observable final class WindowModel {
    var documents: [DocumentModel] = []
    var selection: UUID?
    var sidebar = true
    var active: DocumentModel? { documents.first { $0.id == selection } }
    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = documents.first(where: { $0.url == url }) { selection = existing.id; continue }
            let doc = DocumentModel(url:url); documents.append(doc); selection = doc.id; doc.open()
        }
    }
    func choose() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.message = "Open CSV, TSV, gzip, Parquet, SQLite or DuckDB files"; if panel.runModal() == .OK { open(panel.urls) } }
    func close(_ id: UUID) { documents.first { $0.id == id }?.close(); documents.removeAll { $0.id == id }; if selection == id { selection = documents.last?.id } }
    func cycle(_ delta: Int) { guard !documents.isEmpty else { return }; let index = documents.firstIndex { $0.id == selection } ?? 0; selection = documents[(index + delta + documents.count) % documents.count].id }
}
struct WindowKey: FocusedValueKey { typealias Value = WindowModel }
extension FocusedValues { var scanWindow: WindowModel? { get { self[WindowKey.self] } set { self[WindowKey.self] = newValue } } }
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingURLs: [URL] = []
    private var launchWindow: NSWindow?
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named:.darkAqua)
        NSWindow.allowsAutomaticWindowTabbing = false
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI does not create WindowGroup's first window when Launch Services
        // delivers an open-file event during launch. Ensure CLI/Finder opens show UI.
        DispatchQueue.main.async { [self] in
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:820),
                                      styleMask:[.titled,.closable,.miniaturizable,.resizable],
                                      backing:.buffered,defer:false)
                window.contentViewController = NSHostingController(rootView: WorkspaceView()
                    .frame(minWidth:850,minHeight:500).preferredColorScheme(.dark))
                window.center()
                window.makeKeyAndOrderFront(nil)
                launchWindow = window
            }
            NSApp.activate(ignoringOtherApps:true)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) { Self.pendingURLs += urls; NotificationCenter.default.post(name:.init("ScanOpenFiles"),object:urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct ScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(id:"workspace") { WorkspaceView().frame(minWidth:850,minHeight:500).preferredColorScheme(.dark) }
            .defaultSize(width:1320,height:820)
            .commands { ScanCommands() }
        Settings { ScanSettings() }
    }
}
struct ScanCommands: Commands {
    @FocusedValue(\.scanWindow) var window
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing:.newItem) {
            Button("Open…") { window?.choose() }.keyboardShortcut("o")
            Button("Open in New Tab…") { window?.choose() }.keyboardShortcut("t")
            Button("New Window") { openWindow(id:"workspace") }.keyboardShortcut("n")
            Button("Close Tab") { if let id = window?.selection { window?.close(id) } }.keyboardShortcut("w")
        }
        CommandGroup(after:.saveItem) { Button("Export View…") { window?.active?.export() }.keyboardShortcut("e",modifiers:[.command,.shift]) }
        CommandMenu("Data") {
            Button("Reload from Disk") { window?.active?.open() }.keyboardShortcut("r")
            Button("Cancel Query") { window?.active?.cancel() }.keyboardShortcut(".")
            Button("Inspect Cell") { window?.active?.inspect() }.keyboardShortcut("i")
            Button("Go to Row…") { NotificationCenter.default.post(name:.init("ScanGoToRow"),object:window?.active?.id) }.keyboardShortcut("l")
            Button("Focus Filter") { NotificationCenter.default.post(name:.init("ScanFocusFilter"),object:window?.active?.id) }.keyboardShortcut("f")
            Button("Sort Focused Column") { if let doc = window?.active { doc.sort(doc.selectedIndex,add:false) } }.keyboardShortcut("s",modifiers:[.command,.option])
            Button("Group by Focused Column") { if let doc = window?.active, doc.state.columns.indices.contains(doc.selectedIndex) { doc.group(doc.state.columns[doc.selectedIndex]) } }.keyboardShortcut("g",modifiers:[.command,.option])
            Button("Hide Focused Column") { if let doc = window?.active, doc.state.columns.indices.contains(doc.selectedIndex) { doc.hide(doc.state.columns[doc.selectedIndex]) } }.keyboardShortcut("h",modifiers:[.command,.option])
        }
        CommandGroup(after:.sidebar) {
            Button("Toggle Sidebar") { window?.sidebar.toggle() }.keyboardShortcut("0")
            Button("Next Tab") { window?.cycle(1) }.keyboardShortcut(.tab,modifiers:.control)
            Button("Previous Tab") { window?.cycle(-1) }.keyboardShortcut(.tab,modifiers:[.control,.shift])
        }
    }
}
struct ScanSettings: View {
    @AppStorage("memoryMB") var memory = 512
    @AppStorage("rowHeight") var rowHeight = 28.0
    var body: some View { Form {
        Picker("Row density",selection:$rowHeight) { Text("Compact").tag(22.0); Text("Default").tag(28.0); Text("Comfortable").tag(34.0) }
        Picker("Engine memory per file",selection:$memory) { ForEach([128,256,512,1024,2048],id:\.self) { Text("\($0) MB").tag($0) } }
        Text("Memory settings apply to newly opened files. Large queries spill to a private temporary database.").font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(width:420) }
}
