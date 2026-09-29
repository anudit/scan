import AppKit
import SwiftUI
import ScanQuery
public enum ScanTheme {
    public static let grid = NSColor(hex: 0x151515)
    public static let chrome = NSColor(hex: 0x1F1F23)
    public static let line = NSColor(hex: 0x2F2F2F)
    public static let accent = NSColor(hex: 0x489BF0)
    public static let primary = NSColor(hex: 0xECECEC)
    // Raised from the plan's #77767A / #5A5A5A to satisfy its 4.5:1 contrast requirement.
    public static let muted = NSColor(hex: 0x99989C)
    public static let faint = NSColor(hex: 0x8B8B8B)
    public static let danger = NSColor(hex: 0xEB6B60)
    public static let null = NSColor(hex: 0xEB6B60)
    public static func color(for kind: CellKind, value: String?) -> NSColor {
        guard let value else { return null }
        guard !value.isEmpty else { return faint }
        switch kind {
        case .number: return NSColor(hex: 0x9AC8FF)
        case .boolean: return value == "true" ? NSColor(hex: 0x8FD19E) : muted
        case .temporal: return NSColor(hex: 0x7FD3C9)
        case .nested: return NSColor(hex: 0xC3A6FF)
        default: return primary
        }
    }
    public static func font(for kind: CellKind) -> NSFont { kind == .text ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12.5, weight: .regular) }
}
public extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
}
