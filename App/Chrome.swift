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

/// A panel with a draggable edge, laid out beside its neighbors rather than over them. The gap
/// between the panel and the content next to it is the drag handle: it glows on hover, stretches with
/// resistance past the panel's limits, collapses the panel when dragged well below its minimum, and
/// collapses it on a click. A collapsed panel animates its size to zero and gives the space back.
struct ResizablePanel<Content: View>: View {
    enum Edge { case leading, trailing, bottom }
    let edge: Edge
    /// The panel's width (leading and trailing) or height (bottom).
    @Binding var size: Double
    @Binding var isOpen: Bool
    var range: ClosedRange<Double>
    /// The space between the panel and its neighbor, which is also the drag handle.
    var gap: CGFloat = 10
    @ViewBuilder var content: () -> Content

    @State private var live: Double?
    @State private var base: Double = 0
    @State private var hovering = false
    @State private var dragging = false
    @State private var moved = false
    @State private var cursorPushed = false
    /// The pointer's position along the edge, where the glow is brightest.
    @State private var pointer: CGFloat = 0
    @State private var dragStart: CGFloat = 0

    /// How far past the minimum a drag must go before release collapses the panel.
    private let collapseDistance = 70.0
    private var horizontal: Bool { edge != .bottom }
    /// Never larger than the range allows, even if a saved size predates a smaller window.
    private var shown: Double { isOpen ? (live ?? min(size, range.upperBound)) : 0 }
    private var cursor: NSCursor { horizontal ? .resizeLeftRight : .resizeUpDown }

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if edge == .trailing || edge == .bottom { handle }
            panel
            if edge == .leading { handle }
        }
        .animation(live == nil ? Motion.panel : nil, value: isOpen)
        .animation(live == nil ? Motion.release : nil, value: size)
    }

    private var panel: some View {
        let minimum = range.lowerBound
        return content()
            .frame(width: horizontal ? max(shown, minimum) : nil, height: horizontal ? nil : max(shown, minimum))
            .frame(width: horizontal ? shown : nil, height: horizontal ? nil : shown,
                   alignment: edge == .leading ? .trailing : edge == .trailing ? .leading : .top)
            .clipped()
            // The content fades as the panel narrows below its minimum.
            .opacity(min(1, max(0, shown / minimum * 1.4 - 0.4)))
            .allowsHitTesting(isOpen)
    }

    private var handle: some View {
        let active = (hovering || dragging) && isOpen
        let thickness: CGFloat = isOpen ? gap : 0
        return GeometryReader { proxy in
            let accent = Color(nsColor: ScanTheme.accent)
            let length: CGFloat = dragging ? 320 : 220
            let stops: [Gradient.Stop] = [.init(color: accent.opacity(0), location: 0), .init(color: accent.opacity(0.55), location: 0.3),
                                          .init(color: accent, location: 0.5), .init(color: accent.opacity(0.55), location: 0.7), .init(color: accent.opacity(0), location: 1)]
            let along = horizontal ? proxy.size.height : proxy.size.width
            Capsule()
                .fill(LinearGradient(stops: stops, startPoint: horizontal ? .top : .leading, endPoint: horizontal ? .bottom : .trailing))
                .frame(width: horizontal ? (dragging ? 2.5 : 2) : length, height: horizontal ? length : (dragging ? 2.5 : 2))
                .shadow(color: accent.opacity(0.85), radius: dragging ? 6 : 4)
                .position(x: horizontal ? proxy.size.width / 2 : min(max(pointer, 0), along),
                          y: horizontal ? min(max(pointer, 0), along) : proxy.size.height / 2)
                .animation(Motion.hover, value: dragging)
                .opacity(active ? 1 : 0)
                .animation(Motion.hover, value: active)
        }
        // The glow spreads sideways but is cut at the ends of the gap, and the sidebar's gap also skips the toolbar row.
        .mask(Rectangle().padding(horizontal ? EdgeInsets(top: edge == .leading ? 42 : 0, leading: -16, bottom: 0, trailing: -16) : EdgeInsets(top: -16, leading: 0, bottom: -16, trailing: 0)))
        .frame(width: horizontal ? thickness : nil, height: horizontal ? nil : thickness)
        .contentShape(Rectangle())
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .onHover { inside in
            hovering = inside
            if inside && !cursorPushed { cursor.push(); cursorPushed = true }
            if !inside && !dragging && cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let location) = phase, !dragging { pointer = horizontal ? location.y : location.x }
        }
        .gesture(drag)
        .help("Drag to resize · Click to collapse")
        .zIndex(1)
    }

    private func delta(_ translation: CGSize) -> Double {
        switch edge { case .leading: translation.width; case .trailing: -translation.width; case .bottom: -translation.height }
    }
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !dragging { dragging = true; base = size; moved = false; dragStart = pointer }
                pointer = dragStart + (horizontal ? value.translation.height : value.translation.width)
                if abs(delta(value.translation)) >= 2 { moved = true }
                guard moved else { return }
                live = stretched(base + delta(value.translation))
            }
            .onEnded { value in
                let raw = base + delta(value.translation)
                dragging = false
                if !hovering && cursorPushed { NSCursor.pop(); cursorPushed = false }
                if !moved || raw < range.lowerBound - collapseDistance {
                    // A click, or a drag well past the minimum, collapses the panel; it reopens at its last size.
                    withAnimation(Motion.panel) { live = nil; isOpen = false }
                    if cursorPushed { NSCursor.pop(); cursorPushed = false }
                    hovering = false
                    return
                }
                let target = min(range.upperBound, max(range.lowerBound, raw))
                // Hand the stretched size to the spring so the panel settles from where it was released.
                size = live ?? size
                live = nil
                withAnimation(Motion.release) { size = target }
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

/// The rounded, bordered surface that panels and the table sit on, inset from the window edge.
struct PanelCard: ViewModifier {
    var fill: Color = Color(nsColor: ScanTheme.grid)
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(nsColor: ScanTheme.line).opacity(0.9), lineWidth: 1))
    }
}
extension View {
    func panelCard(fill: Color = Color(nsColor: ScanTheme.grid), radius: CGFloat = 12) -> some View { modifier(PanelCard(fill: fill, radius: radius)) }
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
