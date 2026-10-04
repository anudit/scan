import AppKit
import SwiftUI
import ScanQuery
/// Colors resolve against the drawing appearance, so every view follows the Appearance setting.
public enum ScanTheme {
    public static let grid = NSColor(dark: 0x151515, light: 0xFFFFFF)
    public static let chrome = NSColor(dark: 0x1F1F23, light: 0xF4F4F6)
    public static let line = NSColor(dark: 0x2F2F2F, light: 0xE0E0E4)
    public static let accent = NSColor(dark: 0x489BF0, light: 0x1F6FD1)
    public static let primary = NSColor(dark: 0xECECEC, light: 0x1D1D1F)
    // Raised from the plan's #77767A / #5A5A5A to satisfy its 4.5:1 contrast requirement.
    public static let muted = NSColor(dark: 0x99989C, light: 0x67676C)
    public static let faint = NSColor(dark: 0x8B8B8B, light: 0x7A7A7F)
    public static let danger = NSColor(dark: 0xEB6B60, light: 0xC9372C)
    public static let null = NSColor(dark: 0xEB6B60, light: 0xC9372C)
    public static let focusRow = NSColor(dark: 0x292929, light: 0xEAF1FB)
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
    public static func font(for kind: CellKind) -> NSFont { kind == .text ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12.5, weight: .regular) }
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
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
    convenience init(dark: UInt32, light: UInt32) {
        let dark = NSColor(hex: dark), light = NSColor(hex: light)
        self.init(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}
