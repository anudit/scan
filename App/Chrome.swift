import SwiftUI
import AppKit
import ScanTheme

/// Shared motion for panels and controls: quick, slightly springy, never bouncy enough to distract.
enum Motion {
    static let panel = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// The snap back after a drag past a panel's limits, with a little overshoot.
    static let release = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let hover = Animation.easeOut(duration: 0.14)
}

/// A side panel with a draggable edge. The edge glows on hover, stretches with resistance past the
/// panel's limits, collapses the panel when dragged well below its minimum, and collapses it on a click.
struct ResizablePanel<Content: View>: View {
    enum Side { case leading, trailing }
    let side: Side
    @Binding var width: Double
    @Binding var isOpen: Bool
    var range: ClosedRange<Double>
    var background: Color = Color(nsColor: ScanTheme.chrome)
    @ViewBuilder var content: () -> Content

    @State private var live: Double?
    @State private var base: Double = 0
    @State private var hovering = false
    @State private var dragging = false
    @State private var moved = false
    @State private var cursorPushed = false
    /// The pointer's height along the edge, where the glow is brightest.
    @State private var pointerY: CGFloat = 0
    @State private var dragStartY: CGFloat = 0

    /// How far past the minimum a drag must go before release collapses the panel.
    private let collapseDistance = 70.0

    private var shown: Double { isOpen ? (live ?? width) : 0 }
    var body: some View {
        HStack(spacing: 0) {
            if side == .trailing { handle }
            content()
                .frame(width: max(shown, range.lowerBound))
                .frame(width: shown, alignment: side == .leading ? .trailing : .leading)
                .clipped()
                // The content fades as the panel narrows below its minimum width.
                .opacity(min(1, max(0, shown / range.lowerBound * 1.4 - 0.4)))
                .background(background)
                .allowsHitTesting(isOpen)
            if side == .leading { handle }
        }
        .animation(live == nil ? Motion.panel : nil, value: isOpen)
        .animation(live == nil ? Motion.release : nil, value: width)
    }

    private var handle: some View {
        let active = (hovering || dragging) && isOpen
        return ZStack {
            Rectangle().fill(Color(nsColor: ScanTheme.line)).frame(width: 1)
            // The glow: an accent segment centered on the pointer that fades out above and below it,
            // over a soft halo. It grows while dragging.
            GeometryReader { proxy in
                let accent = Color(nsColor: ScanTheme.accent)
                let length: CGFloat = dragging ? 320 : 220
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: accent.opacity(0), location: 0),
                                                 .init(color: accent.opacity(0.55), location: 0.3),
                                                 .init(color: accent, location: 0.5),
                                                 .init(color: accent.opacity(0.55), location: 0.7),
                                                 .init(color: accent.opacity(0), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: dragging ? 2 : 1.5, height: length)
                    .shadow(color: accent.opacity(0.85), radius: dragging ? 6 : 4)
                    .position(x: proxy.size.width / 2, y: min(max(pointerY, 0), proxy.size.height))
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: pointerY)
                    .animation(Motion.hover, value: dragging)
            }
            .opacity(active ? 1 : 0)
            .animation(Motion.hover, value: active)
        }
        .frame(width: isOpen ? 1 : 0)
        .opacity(isOpen ? 1 : 0)
        .overlay {
            if isOpen {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                        if !inside && !dragging && cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let location) = phase, !dragging { pointerY = location.y }
                    }
                    .gesture(drag)
                    .help("Drag to resize · Click to collapse")
            }
        }
        .zIndex(1)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let delta = side == .leading ? value.translation.width : -value.translation.width
                if !dragging { dragging = true; base = width; moved = false; dragStartY = pointerY }
                pointerY = dragStartY + value.translation.height
                if abs(delta) >= 2 { moved = true }
                guard moved else { return }
                live = stretched(base + delta)
            }
            .onEnded { value in
                let delta = side == .leading ? value.translation.width : -value.translation.width
                let raw = base + delta
                dragging = false
                if !hovering && cursorPushed { NSCursor.pop(); cursorPushed = false }
                if !moved || raw < range.lowerBound - collapseDistance {
                    // A click, or a drag well past the minimum, collapses the panel; it reopens at its last width.
                    withAnimation(Motion.panel) { live = nil; isOpen = false }
                    if cursorPushed { NSCursor.pop(); cursorPushed = false }
                    hovering = false
                    return
                }
                let target = min(range.upperBound, max(range.lowerBound, raw))
                // Hand the stretched width to the spring so the panel settles from where it was released.
                width = live ?? width
                live = nil
                withAnimation(Motion.release) { width = target }
            }
    }

    /// Follows the pointer inside the limits; past them, the panel stretches with growing resistance.
    private func stretched(_ raw: Double) -> Double {
        func resist(_ excess: Double, limit: Double) -> Double { limit * (1 - 1 / (excess / limit * 0.55 + 1)) }
        if raw > range.upperBound { return range.upperBound + resist(raw - range.upperBound, limit: 60) }
        if raw < range.lowerBound { return max(0, range.lowerBound - resist(range.lowerBound - raw, limit: 90)) }
        return raw
    }
}

/// An icon button with a rounded hover fill and a slight press-in.
struct HoverButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, active: active) }
    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(active ? Color(nsColor: ScanTheme.accent) : (hovering ? Color(nsColor: ScanTheme.primary) : Color.secondary))
                .padding(.horizontal, 3)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color(nsColor: ScanTheme.accent).opacity(0.14) : Color.primary.opacity(hovering ? 0.08 : 0))
                }
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.hover, value: hovering)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// A full-width list row with a soft hover fill and a stronger fill when selected.
struct RowHighlight: ViewModifier {
    var selected = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.09 : hovering ? 0.05 : 0))
            }
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.hover, value: selected)
    }
}
extension View {
    func rowHighlight(selected: Bool = false) -> some View { modifier(RowHighlight(selected: selected)) }
}

/// A segmented control whose selection pill slides between segments.
struct SlidingPicker: View {
    let options: [String]
    @Binding var selection: String
    @Namespace private var pill
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option } } label: {
                    Text(option)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color(nsColor: ScanTheme.primary) : Color.secondary)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.11))
                                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// A search field with an inset fill and an accent glow while focused.
struct SoftSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(focused ? 0.07 : 0.045)))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color(nsColor: ScanTheme.accent).opacity(0.7) : Color.primary.opacity(0.06), lineWidth: 1)
                .shadow(color: Color(nsColor: ScanTheme.accent).opacity(focused ? 0.45 : 0), radius: 5)
        }
        .animation(Motion.hover, value: focused)
        .animation(Motion.hover, value: text.isEmpty)
    }
}

/// The heatmap scale as a small capsule, used for heatmap toggles and markers.
struct HeatSwatch: View {
    var on = true
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [0, 0.5, 1].map { Color(nsColor: ScanTheme.heat($0).withAlphaComponent(1)) }, startPoint: .leading, endPoint: .trailing))
            .frame(width: 16, height: 6)
            .saturation(on ? 1 : 0)
            .opacity(on ? 1 : 0.35)
    }
}
