import SwiftUI
import AppKit
import ScanEngine
import ScanTheme

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, performance, huggingFace, cloud, storage
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .performance: "Performance"; case .huggingFace: "Hugging Face"; case .cloud: "Cloud Storage"; case .storage: "Storage" }
    }
    var icon: String {
        switch self { case .general: "gearshape"; case .performance: "gauge.with.dots.needle.33percent"; case .huggingFace: "face.smiling"; case .cloud: "cloud"; case .storage: "internaldrive" }
    }
    var subtitle: String {
        switch self {
        case .general: "How Scan looks and how dense its tables are."
        case .performance: "How much memory each open file starts with."
        case .huggingFace: "Access gated and private datasets by URL."
        case .cloud: "Keys for s3://, gs:// and r2:// files."
        case .storage: "Files Scan keeps on this Mac for remote data."
        }
    }
}

/// Settings laid out like a Scan window: sections in a sidebar on the window frame, under the
/// traffic lights, and the chosen section on a rounded card.
struct ScanSettings: View {
    @Environment(\.accentRevision) private var accentRevision
    @State private var section = SettingsSection.general
    @AppStorage("accentHex") private var accentHex = ""
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color(nsColor: ScanTheme.line)).frame(width: 1)
            content.background(Color(nsColor: ScanTheme.chrome))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: ScanTheme.frame))
        .ignoresSafeArea()
        .tint(Color.scanAccent).environment(\.accentRevision, accentHex)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                let selected = section == item
                Button { withAnimation(Motion.hover) { section = item } } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                            .foregroundStyle(selected ? Color.scanAccent : Color.secondary)
                        Text(item.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color(nsColor: ScanTheme.primary) : Color.secondary)
                        Spacer(minLength: 0)
                    }.frame(height: 30).rowHighlight(selected: selected)
                }.buttonStyle(.plain)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "lock.shield").font(.system(size: 11))
                Text("Scan only reads your files. Nothing here changes them.").fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.horizontal, 8)
        }
        .padding(.horizontal, 10).padding(.top, 48).padding(.bottom, 16)
        .frame(width: 196)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.system(size: 20, weight: .semibold))
                Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
            .id(section).transition(.opacity)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch section {
                    case .general: GeneralSettings()
                    case .performance: PerformanceSettings()
                    case .huggingFace: HuggingFaceSettings()
                    case .cloud: CloudSettings()
                    case .storage: StorageSettings()
                    }
                }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The Settings window. Scan makes it itself rather than through SwiftUI's Settings scene, whose
/// window keeps an opaque title bar; this one has a transparent title bar, so the sidebar runs to
/// the top edge under the traffic lights, as in the main window.
@MainActor enum SettingsWindow {
    static let size = CGSize(width: 720, height: 560)
    private static var window: NSWindow?
    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ScanSettings())
        // The window sets the size, title bar included, and the view fills it.
        host.sizingOptions = []
        window.contentViewController = host
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.title = "Scan Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = ScanTheme.frame
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A titled card that holds rows. The footer may use Markdown, such as `code`.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2) }
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: ScanTheme.line).opacity(0.8)))
            if let footer {
                Text(LocalizedStringKey(footer)).font(.system(size: 11)).foregroundStyle(Color(nsColor: ScanTheme.muted))
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}
/// One row of a group: a label with an optional description, and its control.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var control: () -> Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13))
                    if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: 260, alignment: .leading)
                Spacer(minLength: 8)
                control()
            }.padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 48)
            if divider { Rectangle().fill(Color(nsColor: ScanTheme.line).opacity(0.6)).frame(height: 1).padding(.horizontal, 14) }
        }
    }
}
/// A text field with the same inset fill as the search fields, and an accent ring while focused.
private struct SettingsField: View {
    @Environment(\.accentRevision) private var accentRevision
    let prompt: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 260
    @State private var revealed = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Group {
                if secure && !revealed { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }.textFieldStyle(.plain).focused($focused)
            if secure {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 12)).frame(width: 20, height: 20)
                        .foregroundStyle(Color(nsColor: ScanTheme.muted)).contentShape(Rectangle())
                }.buttonStyle(.plain).help(revealed ? "Hide" : "Show")
            }
        }
        .font(.system(size: 12, design: .monospaced)).padding(.leading, 9).padding(.trailing, secure ? 5 : 9).frame(width: width, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(focused ? 0.07 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focused ? Color.scanAccent.opacity(0.7) : Color.primary.opacity(0.07)))
        .animation(Motion.hover, value: focused)
    }
}
private struct SettingsButton: View {
    @Environment(\.accentRevision) private var accentRevision
    let title: String
    var prominent = false
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(role: role, action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 26).fixedSize()
                .background(Capsule().fill(prominent ? Color.scanAccent.opacity(hovering ? 0.26 : 0.18) : Color.primary.opacity(hovering ? 0.11 : 0.07)))
                .foregroundStyle(prominent ? Color.scanAccent : role == .destructive ? Color(nsColor: ScanTheme.danger) : Color(nsColor: ScanTheme.primary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.animation(Motion.hover, value: hovering)
    }
}
/// A segmented choice with an optional icon on each option.
private struct SettingsSegments<Value: Hashable>: View {
    let options: [(label: String, icon: String?, value: Value)]
    @Binding var selection: Value
    @Namespace private var pill
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], selected = option.value == selection
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option.value } } label: {
                    HStack(spacing: 5) {
                        if let icon = option.icon { Image(systemName: icon).font(.system(size: 11)) }
                        Text(option.label).font(.system(size: 12, weight: selected ? .medium : .regular))
                    }
                    .foregroundStyle(selected ? Color(nsColor: ScanTheme.primary) : Color.secondary)
                    .padding(.horizontal, 11).frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: ScanTheme.grid))
                                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06))).fixedSize()
    }
}

/// Opens the system color panel and saves the color it picks as the accent.
@MainActor private final class AccentColorPanel: NSObject {
    static let shared = AccentColorPanel()
    func show() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = ScanTheme.accent.resolved(for: NSApp.effectiveAppearance)
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }
    @objc func changed(_ sender: NSColorPanel) { UserDefaults.standard.set(sender.color.hexString, forKey: "accentHex") }
}

/// Accent swatches. The chosen one has a ring in its own color; the last opens the color panel and
/// shows a custom color once one is picked.
private struct AccentSwatches: View {
    @Environment(\.accentRevision) private var accentRevision
    @Binding var hex: String
    static let presets: [(name: String, hex: String)] = [("Blue", ""), ("Purple", "#9B7BFF"), ("Pink", "#F26AA8"), ("Red", "#EB6B60"), ("Orange", "#F0903A"), ("Green", "#4FC27A"), ("Teal", "#3CC4B7")]
    var body: some View {
        let custom = !Self.presets.contains { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
        HStack(spacing: 6) {
            ForEach(Self.presets, id: \.name) { preset in
                let color = Color(nsColor: NSColor(storedHex: preset.hex) ?? ScanTheme.defaultAccent)
                swatch(color, chosen: preset.hex.caseInsensitiveCompare(hex) == .orderedSame) { hex = preset.hex }.help(preset.name)
            }
            swatch(custom ? Color.scanAccent : nil, chosen: custom) { AccentColorPanel.shared.show() }.help("Custom color…")
        }
    }
    private func swatch(_ color: Color?, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if let color { Circle().fill(color) }
                else { Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red], center: .center)) }
                Circle().strokeBorder(Color.black.opacity(0.12))
            }
            .frame(width: 18, height: 18)
            .padding(3)
            .overlay(Circle().strokeBorder((color ?? Color.primary).opacity(chosen ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(Circle())
            .animation(Motion.hover, value: chosen)
        }.buttonStyle(.plain)
    }
}

/// Appearance as three small window previews.
private struct AppearancePicker: View {
    @Environment(\.accentRevision) private var accentRevision
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 12) {
            tile(.system, "System"); tile(.light, "Light"); tile(.dark, "Dark")
        }
    }
    private func tile(_ value: ScanAppearance, _ label: String) -> some View {
        let chosen = selection == value.rawValue
        return Button { selection = value.rawValue } label: {
            VStack(spacing: 6) {
                Group {
                    switch value {
                    case .light: preview(dark: false)
                    case .dark: preview(dark: true)
                    case .system: HStack(spacing: 0) { preview(dark: false); preview(dark: true) }.frame(width: 64).clipped()
                    }
                }
                .frame(width: 64, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.scanAccent.opacity(chosen ? 1 : 0), lineWidth: 2))
                Text(label).font(.system(size: 11, weight: chosen ? .medium : .regular)).foregroundStyle(chosen ? Color(nsColor: ScanTheme.primary) : Color.secondary)
            }
            .contentShape(Rectangle())
            .animation(Motion.hover, value: chosen)
        }.buttonStyle(.plain)
    }
    /// A tiny window: frame, sidebar lines, and a content card with an accent row.
    private func preview(dark: Bool) -> some View {
        let frame = Color(white: dark ? 0.08 : 0.88), card = Color(white: dark ? 0.15 : 1), ink = Color(white: dark ? 0.35 : 0.75)
        return ZStack(alignment: .topLeading) {
            frame
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in Capsule().fill(ink).frame(width: i == 1 ? 10 : 13, height: 2.5) }
            }.padding(.leading, 5).padding(.top, 10)
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(card)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(Color.scanAccent).frame(width: 26, height: 3)
                        Capsule().fill(ink).frame(width: 34, height: 2.5)
                        Capsule().fill(ink).frame(width: 22, height: 2.5)
                    }.padding(5)
                }
                .padding(.leading, 22).padding(.top, 6).padding([.trailing, .bottom], 4)
        }
        .frame(width: 64, height: 42)
    }
}

private struct GeneralSettings: View {
    @AppStorage("rowHeight") private var rowHeight = 28.0
    @AppStorage("appearance") private var appearance = ScanAppearance.dark.rawValue
    @AppStorage("accentHex") private var accentHex = ""
    @AppStorage("autoUpdateCheck") private var autoUpdate = true
    @AppStorage("autoFormat") private var autoFormat = true
    var body: some View {
        SettingsGroup(title: "Appearance") {
            SettingsRow(title: "Theme", detail: "Follow the system, or always use light or dark.") {
                AppearancePicker(selection: $appearance)
            }
            SettingsRow(title: "Accent color", detail: "Selection, focus, links and highlights.", divider: false) {
                AccentSwatches(hex: $accentHex)
            }
        }
        SettingsGroup(title: "Tables") {
            SettingsRow(title: "Row density", detail: "How tall each table row is.") {
                SettingsSegments(options: [("Compact", nil, 22.0), ("Default", nil, 28.0), ("Comfortable", nil, 34.0)], selection: $rowHeight)
            }
            SettingsRow(title: "Format detected values", detail: "Show UUIDs, timestamps, dates, links and emails stored as text in a readable form. The data is unchanged.", divider: false) {
                Toggle("", isOn: $autoFormat).labelsHidden().toggleStyle(AccentSwitchStyle())
            }
        }
        SettingsGroup(title: "Updates", footer: "Scan checks GitHub releases at most once a day. You can also run `scan upgrade` in Terminal.") {
            SettingsRow(title: "Version \(Updater.current)") {
                SettingsButton(title: "Check Now") { Task { await Updater.check(manual: true) } }
            }
            SettingsRow(title: "Check automatically", divider: false) {
                Toggle("", isOn: $autoUpdate).labelsHidden().toggleStyle(AccentSwitchStyle())
            }
        }
        .onChange(of: appearance) { NSApp.appearance = ScanAppearance.current.nsAppearance }
    }
}
private struct PerformanceSettings: View {
    @AppStorage("memoryMB") private var memory = 512
    var body: some View {
        SettingsGroup(title: "Memory", footer: "Applies to newly opened files. If a query needs more memory, Scan reduces parallel work and can raise the limit to at most 4 GB or one eighth of this Mac's RAM, whichever is smaller, without lowering your initial setting. Large queries spill to a private temporary database.") {
            SettingsRow(title: "Initial memory per file", detail: "The limit each file's query engine starts with.", divider: false) {
                SettingsSegments(options: [128, 256, 512, 1024, 2048].map { ($0 < 1024 ? "\($0) MB" : "\($0 / 1024) GB", nil, $0) }, selection: $memory)
            }
        }
    }
}
private struct HuggingFaceSettings: View {
    @State private var token = HuggingFaceToken.load() ?? ""
    @State private var saved = false
    var body: some View {
        SettingsGroup(title: "Access token", footer: "Used for gated or private Hugging Face datasets when a URL is opened. The HF_TOKEN environment variable takes precedence. Tokens are stored in the login keychain.") {
            SettingsRow(title: "Token", detail: "Create one at huggingface.co/settings/tokens.", divider: false) {
                HStack(spacing: 8) {
                    SettingsField(prompt: "hf_…", text: $token, secure: true, width: 190)
                    SettingsButton(title: saved ? "Saved" : "Save", prominent: !saved) { _ = HuggingFaceToken.save(token); saved = true }
                }.onChange(of: token) { saved = false }
            }
        }
    }
}
/// Keys for s3://, gs:// and r2:// URLs, kept in the login keychain per provider.
struct CloudSettings: View {
    @State private var provider = CloudProvider.s3
    @State private var credentials = CloudCredentials.load(.s3) ?? CloudCredentials()
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Provider") {
                SettingsRow(title: "Service", detail: "Keys are kept separately for each one.", divider: false) {
                    SettingsSegments(options: CloudProvider.allCases.map { ($0.title, nil, $0) }, selection: $provider)
                }
            }
            .onChange(of: provider) { credentials = CloudCredentials.load(provider) ?? CloudCredentials(); saved = false }
            SettingsGroup(title: "Credentials", footer: note) {
                if provider == .r2 { SettingsRow(title: "Account ID") { SettingsField(prompt: "Account ID", text: $credentials.accountID) } }
                SettingsRow(title: provider == .gcs ? "HMAC access ID" : "Access key ID") { SettingsField(prompt: "AKIA…", text: $credentials.accessKeyID) }
                SettingsRow(title: provider == .gcs ? "HMAC secret" : "Secret access key", divider: provider == .s3) { SettingsField(prompt: "••••••••", text: $credentials.secretAccessKey, secure: true) }
                if provider == .s3 {
                    SettingsRow(title: "Region", detail: "Found automatically when empty.") { SettingsField(prompt: "us-east-1", text: $credentials.region) }
                    SettingsRow(title: "Endpoint", detail: "For S3-compatible servers.") { SettingsField(prompt: "https://…", text: $credentials.endpoint) }
                    SettingsRow(title: "Session token", detail: "Optional.", divider: false) { SettingsField(prompt: "Optional", text: $credentials.sessionToken, secure: true) }
                }
            }
            .onChange(of: credentials) { saved = false }
            HStack {
                Spacer()
                SettingsButton(title: "Remove", role: .destructive) { CloudCredentials.save(CloudCredentials(), for: provider); credentials = CloudCredentials(); saved = false }
                SettingsButton(title: saved ? "Saved" : "Save", prominent: !saved) { saved = CloudCredentials.save(credentials, for: provider) }
            }
        }
    }
    private var note: String {
        switch provider {
        case .s3: "Opens s3://bucket/key. Public buckets need no keys. AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION and AWS_ENDPOINT_URL take precedence. Use an endpoint for S3-compatible servers such as MinIO."
        case .gcs: "Opens gs://bucket/object. Public objects need no keys. Create HMAC keys under Cloud Storage → Settings → Interoperability. GCS_ACCESS_KEY_ID and GCS_SECRET_ACCESS_KEY take precedence."
        case .r2: "Opens r2://bucket/key. Create an R2 API token with read access. R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY take precedence."
        }
    }
}
private struct StorageSettings: View {
    @State private var cacheBytes = RemoteParquet.cacheSize()
    var body: some View {
        SettingsGroup(title: "Remote download cache", footer: "Downloaded Parquet row groups are kept here, so opening the same remote file again only fetches what is missing. Other remote files are downloaded here in full each time they are opened. The cache is limited to 5 GB and the oldest files are removed first.") {
            SettingsRow(title: "Cache size", detail: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file) + " used", divider: false) {
                SettingsButton(title: "Clear Cache", role: .destructive) { _ = RemoteParquet.clearCache(); cacheBytes = 0 }
                    .disabled(cacheBytes == 0).opacity(cacheBytes == 0 ? 0.45 : 1)
            }
        }
    }
}
