import AppKit

/// Checks GitHub releases for a newer Scan and offers the download.
@MainActor enum Updater {
    static let repository = "anudit/scan"
    struct Release: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        /// The disk image when the release has one, else the zip, else the release page.
        var download: URL {
            (assets.first { $0.name.hasSuffix(".dmg") } ?? assets.first { $0.name.hasSuffix(".zip") })?.browser_download_url ?? html_url
        }
    }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// True when `a` is a newer dotted version than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }, y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data)
    }
    /// `manual` checks report "up to date" and errors; automatic ones stay silent and run at most daily.
    static func check(manual: Bool) async {
        let defaults = UserDefaults.standard
        if !manual {
            guard defaults.object(forKey: "autoUpdateCheck") as? Bool ?? true else { return }
            if let last = defaults.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        }
        do {
            let release = try await latest()
            defaults.set(Date(), forKey: "lastUpdateCheck")
            if isNewer(release.version, than: current) {
                if !manual, defaults.string(forKey: "skippedUpdate") == release.version { return }
                present(release)
            } else if manual {
                let alert = NSAlert(); alert.messageText = "Scan is up to date"; alert.informativeText = "You have the latest version, \(current)."; alert.runModal()
            }
        } catch {
            guard manual else { return }
            let alert = NSAlert(); alert.messageText = "Couldn't check for updates"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    private static func present(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Scan \(release.version) is available"
        alert.informativeText = "You have \(current). Download the new version, or run `scan upgrade` in Terminal."
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 140)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.string = notes; text.font = .systemFont(ofSize: 12)
            text.textContainerInset = NSSize(width: 6, height: 6); text.autoresizingMask = [.width]; scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.download)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.html_url)
        case NSApplication.ModalResponse(rawValue: 1003): UserDefaults.standard.set(release.version, forKey: "skippedUpdate")
        default: break
        }
    }
}
