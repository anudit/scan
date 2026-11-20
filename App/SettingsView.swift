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
        switch self { case .general: "gearshape"; case .performance: "speedometer"; case .huggingFace: "face.smiling"; case .cloud: "cloud"; case .storage: "internaldrive" }
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

/// Settings as a page: a sidebar of sections, and the chosen section's groups on the right.
struct ScanSettings: View {
    @State private var section = SettingsSection.general
    @AppStorage("accentHex") private var accentHex = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    Button { withAnimation(Motion.hover) { section = item } } label: {
                        HStack(spacing: 9) {
                            SettingsTile(icon: item.icon, selected: section == item)
                            Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.frame(height: 32).rowHighlight(selected: section == item)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Scan only reads your files. Nothing here changes them.").font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.bottom, 4)
            }
            .padding(12).frame(width: 206).background(Color(nsColor: ScanTheme.chrome))
            Rectangle().fill(Color(nsColor: ScanTheme.line)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SettingsTile(icon: section.icon, selected: true, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.system(size: 20, weight: .semibold))
                        Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch section {
                        case .general: GeneralSettings()
                        case .performance: PerformanceSettings()
                        case .huggingFace: HuggingFaceSettings()
                        case .cloud: CloudSettings()
                        case .storage: StorageSettings()
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: ScanTheme.grid))
        }
        .frame(width: 740, height: 620)
        .tint(Color(nsColor: ScanTheme.accent)).environment(\.accentRevision, accentHex)
    }
}

/// A rounded icon tile, filled with the accent color when it marks the current section.
private struct SettingsTile: View {
    let icon: String
    var selected = false
    var size: CGFloat = 24
    var body: some View {
        let accent = Color(nsColor: ScanTheme.accent)
        Image(systemName: icon).font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(selected ? Color.white : accent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(selected ? AnyShapeStyle(LinearGradient(colors: [accent, accent.opacity(0.75)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(accent.opacity(0.14))))
    }
}

/// A titled card that holds rows.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Color(nsColor: ScanTheme.muted)).padding(.leading, 4) }
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: ScanTheme.line).opacity(0.9)))
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: 250, alignment: .leading)
                Spacer(minLength: 8)
                control()
            }.padding(.horizontal, 14).padding(.vertical, 11)
            if divider { Rectangle().fill(Color(nsColor: ScanTheme.line).opacity(0.6)).frame(height: 1).padding(.leading, 14) }
        }
    }
}
/// A text field with the same inset fill as the search fields.
private struct SettingsField: View {
    let prompt: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 270
    @State private var revealed = false
    var body: some View {
        HStack(spacing: 4) {
            Group {
                if secure && !revealed { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }.textFieldStyle(.plain)
            if secure {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 12)).frame(width: 20, height: 20)
                        .foregroundStyle(Color(nsColor: ScanTheme.muted)).contentShape(Rectangle())
                }.buttonStyle(.plain).help(revealed ? "Hide" : "Show")
            }
        }
        .font(.system(size: 12.5, design: .monospaced)).padding(.leading, 9).padding(.trailing, secure ? 5 : 9).frame(width: width, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}
private struct SettingsButton: View {
    let title: String
    var prominent = false
    var role: ButtonRole?
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 26).fixedSize()
                .background(Capsule().fill(prominent ? Color(nsColor: ScanTheme.accent).opacity(0.18) : Color.primary.opacity(0.07)))
                .foregroundStyle(prominent ? Color(nsColor: ScanTheme.accent) : role == .destructive ? Color(nsColor: ScanTheme.danger) : Color(nsColor: ScanTheme.primary))
        }.buttonStyle(.plain)
    }
}
/// A segmented choice with an icon on each option.
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
                        Text(option.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Color(nsColor: ScanTheme.primary) : Color.secondary)
                    .padding(.horizontal, 11).frame(height: 24)
                    .background { if selected { Capsule().fill(Color.primary.opacity(0.11)).matchedGeometryEffect(id: "pill", in: pill) } }
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(2).background(Capsule().fill(Color.primary.opacity(0.05))).fixedSize()
    }
}

private struct GeneralSettings: View {
    @AppStorage("rowHeight") private var rowHeight = 28.0
    @AppStorage("appearance") private var appearance = ScanAppearance.dark.rawValue
    @AppStorage("accentHex") private var accentHex = ""
    @AppStorage("autoUpdateCheck") private var autoUpdate = true
    private static let presets: [(name: String, hex: String)] = [("Blue", ""), ("Purple", "#9B7BFF"), ("Pink", "#F26AA8"), ("Red", "#EB6B60"), ("Orange", "#F0903A"), ("Green", "#4FC27A"), ("Teal", "#3CC4B7")]
    private var accentBinding: Binding<Color> {
        Binding(get: { Color(nsColor: ScanTheme.accent) }, set: { accentHex = NSColor($0).hexString })
    }
    var body: some View {
        SettingsGroup(title: "Display") {
            SettingsRow(title: "Accent color", detail: "Used for selection, focus, highlights and the panel resize glow.") {
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.name) { preset in
                        let color = NSColor(storedHex: preset.hex) ?? ScanTheme.defaultAccent, chosen = accentHex.caseInsensitiveCompare(preset.hex) == .orderedSame
                        Button { accentHex = preset.hex } label: {
                            Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(chosen ? 0.9 : 0.12), lineWidth: chosen ? 2 : 1).padding(chosen ? -3 : 0))
                        }.buttonStyle(.plain).help(preset.name)
                    }
                    ColorPicker("Custom", selection: accentBinding, supportsOpacity: false).labelsHidden()
                }
            }
            SettingsRow(title: "Appearance", detail: "Follow the system, or always use light or dark.") {
                SettingsSegments(options: [("System", "circle.lefthalf.filled", ScanAppearance.system.rawValue), ("Light", "sun.max", ScanAppearance.light.rawValue), ("Dark", "moon", ScanAppearance.dark.rawValue)], selection: $appearance)
            }
            SettingsRow(title: "Row density", detail: "How tall each table row is.", divider: false) {
                SettingsSegments(options: [("Compact", nil, 22.0), ("Default", nil, 28.0), ("Comfortable", nil, 34.0)], selection: $rowHeight)
            }
        }
        SettingsGroup(title: "Updates", footer: "Scan checks GitHub releases at most once a day. You can also run `scan upgrade` in Terminal.") {
            SettingsRow(title: "Check automatically", detail: "Version \(Updater.current)", divider: false) {
                HStack(spacing: 10) {
                    SettingsButton(title: "Check Now") { Task { await Updater.check(manual: true) } }
                    Toggle("", isOn: $autoUpdate).labelsHidden().toggleStyle(.switch)
                }
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
                Picker("Initial memory per file", selection: $memory) { ForEach([128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) MB").tag($0) } }
                    .labelsHidden().fixedSize()
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
