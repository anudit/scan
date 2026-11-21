import AppKit
import SwiftUI
import ScanQuery
/// Colors resolve against the drawing appearance, so every view follows the Appearance setting.
public enum ScanTheme {
    public static let grid = NSColor(dark: 0x151515, light: 0xFFFFFF)
    public static let chrome = NSColor(dark: 0x1F1F23, light: 0xF4F4F6)
    /// The window frame behind the content card: the title bar, tabs and sidebar share it.
    public static let frame = NSColor(dark: 0x131315, light: 0xE6E6EA)
    public static let line = NSColor(dark: 0x2F2F2F, light: 0xE0E0E4)
    /// The default accent; the "accentHex" user default replaces it in both appearances.
    public static let defaultAccent = NSColor(dark: 0x489BF0, light: 0x1F6FD1)
    public static let accent = NSColor(name: nil) { appearance in
        if let custom = NSColor(storedHex: UserDefaults.standard.string(forKey: "accentHex")) { return custom }
        return defaultAccent.resolved(for: appearance)
    }
    public static let primary = NSColor(dark: 0xECECEC, light: 0x1D1D1F)
    // Raised from the plan's #77767A / #5A5A5A to satisfy its 4.5:1 contrast requirement.
    public static let muted = NSColor(dark: 0x99989C, light: 0x67676C)
    public static let faint = NSColor(dark: 0x8B8B8B, light: 0x7A7A7F)
    public static let danger = NSColor(dark: 0xEB6B60, light: 0xC9372C)
    public static let null = NSColor(dark: 0xEB6B60, light: 0xC9372C)
    /// The focused row: neutral in dark, a faint accent wash over white in light.
    public static let focusRow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x292929)
            : NSColor(hex: 0xFFFFFF).blended(withFraction: 0.09, of: accent.resolved(for: appearance)) ?? NSColor(hex: 0xF0F0F2)
    }
    /// The accent at a given opacity, resolved each time it is drawn so it follows the accent setting.
    public static func accent(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { accent.resolved(for: $0).withAlphaComponent(alpha) }
    }
    public static let stripe = NSColor(dark: 0x1A1A1A, light: 0xF8F8FA)
    public static func color(for kind: CellKind, value: String?) -> NSColor {
        guard let value else { return null }
        guard !value.isEmpty else { return faint }
        switch kind {
        case .number: return number
        case .boolean: return value == "true" ? boolean : muted
        case .temporal: return temporal
        case .nested: return nested
        default: return primary
        }
    }
    private static let number = NSColor(dark: 0x9AC8FF, light: 0x1F5FBF)
    private static let boolean = NSColor(dark: 0x8FD19E, light: 0x2E7D3E)
    private static let temporal = NSColor(dark: 0x7FD3C9, light: 0x0E7A6E)
    private static let nested = NSColor(dark: 0xC3A6FF, light: 0x7349C2)
    /// SQL syntax colors, drawn from the same palette as the cell types.
    public static let syntaxKeyword = accent
    public static let syntaxString = NSColor(dark: 0x8FD19E, light: 0x2E7D3E)
    public static let syntaxNumber = NSColor(dark: 0xE5B26B, light: 0xA5600A)
    public static let syntaxIdentifier = NSColor(dark: 0x7FD3C9, light: 0x0E7A6E)
    public static let syntaxFunction = NSColor(dark: 0xC3A6FF, light: 0x7349C2)
    public static let syntaxComment = NSColor(dark: 0x7D7C80, light: 0x8C8C91)
    /// The fill of the row under the pointer.
    public static let hoverRow = NSColor(dark: 0x1D1D1F, light: 0xF5F5F7)
    /// Heatmap cell fills from the column minimum (green) through amber to the maximum (red),
    /// as translucent washes so row focus and selection stay visible beneath them.
    public static let heatSteps: [NSColor] = (0...32).map { step in
        let t = Double(step) / 32
        let dark = ramp(t, [0x2EA043, 0xD29922, 0xE5534B]), light = ramp(t, [0x2DA44E, 0xD4A72C, 0xCF222E])
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.withAlphaComponent(0.30) : light.withAlphaComponent(0.20) }
    }
    /// The heatmap fill for a value's position in [0, 1] between the column minimum and maximum.
    public static func heat(_ position: Double) -> NSColor {
        heatSteps[Int((min(1, max(0, position.isFinite ? position : 0)) * 32).rounded())]
    }
    private static func ramp(_ t: Double, _ stops: [UInt32]) -> NSColor {
        let scaled = t * Double(stops.count - 1), index = min(stops.count - 2, Int(scaled)), f = scaled - Double(index)
        func channel(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 255) / 255 }
        let a = stops[index], b = stops[index + 1]
        return NSColor(srgbRed: channel(a,16) + (channel(b,16) - channel(a,16)) * f,
                       green: channel(a,8) + (channel(b,8) - channel(a,8)) * f,
                       blue: channel(a,0) + (channel(b,0) - channel(a,0)) * f, alpha: 1)
    }
    public static func font(for kind: CellKind) -> NSFont { kind == .text ? textFont : monoFont }
    nonisolated(unsafe) public static let textFont = NSFont.systemFont(ofSize: 13)
    nonisolated(unsafe) public static let monoFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    /// Links and emails read as links; UUIDs recede, since they are rarely read in full.
    public static var link: NSColor { accent }
    public static let identifier = NSColor(dark: 0xA9A8B4, light: 0x5D5D68)
    /// The color for a value whose meaning was detected, such as a UUID or a timestamp in a text column.
    public static func color(for semantic: ColumnSemantic) -> NSColor {
        switch semantic {
        case .uuid: identifier
        case .timestamp, .date: temporal
        case .url, .email: link
        }
    }
}
/// The Appearance setting, stored under "appearance" in user defaults.
public enum ScanAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var nsAppearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
    public static var current: ScanAppearance { ScanAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark }
}
public extension NSColor {
    /// "#RRGGBB" (or "RRGGBB") text, nil when empty or malformed.
    convenience init?(storedHex: String?) {
        guard var text = storedHex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    func resolved(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = NSColor(cgColor: self.cgColor) ?? self }
        return result
    }
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
    convenience init(dark: UInt32, light: UInt32) {
        let dark = NSColor(hex: dark), light = NSColor(hex: light)
        self.init(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}
