import AppKit
import CoreText
import ScanQuery
import ScanTheme

@MainActor public final class GridData {
    public var columns: [Column] = []
    public var rowCount = 0
    public var generation = 0
    public var rowHeight: CGFloat = 28
    public var sorts: [SortKey] = []
    public var page: (Int) -> RowPage? = { _ in nil }
    public var request: (Int) -> Void = { _ in }
    public var sort: (Int, Bool) -> Void = { _, _ in }
    public var select: (Int, Int) -> Void = { _, _ in }
    public var inspect: () -> Void = {}
    public var copy: (ClosedRange<Int>, ClosedRange<Int>, Bool) -> Void = { _, _, _ in }
    public var pivot: ((Int) -> (depth: Int, expanded: Bool, label: String)?) = { _ in nil }
    public var togglePivot: (Int) -> Void = { _ in }
    public var onFirstPaint: () -> Void = {}
    /// Numeric columns colored as a heatmap, by column index, with the range their colors span.
    public var heat: [Int: ClosedRange<Double>] = [:]
    public var toggleHeat: (Int) -> Void = { _ in }
    public var sortColumn: (Int, Bool) -> Void = { _, _ in }
    public var hideColumn: (Int) -> Void = { _ in }
    /// Column widths by name to start from, such as those saved with the file's view.
    public var savedWidths: [String: CGFloat] = [:]
    /// Called with every column's width when the user finishes resizing one.
    public var widthsChanged: ([String: CGFloat]) -> Void = { _ in }
    /// Distributions of numeric columns, by column index, drawn as sparklines in the header.
    public var sparklines: [Int: [Int]] = [:]
    /// Whether cells can be filtered on. Pivot results cannot.
    public var filterable = true
    /// Filters on the value of a cell: row, column and the kind of filter.
    public var filterCell: (Int, Int, ValueFilter) -> Void = { _, _, _ in }
    public var showProfile: (Int) -> Void = { _ in }
    public init() {}
}

@MainActor public final class ScanGrid: NSView {
    public let scroll = NSScrollView()
    public let document = GridDocument()
    private let header = GridHeader()
    public override var isFlipped: Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.backgroundColor = ScanTheme.grid
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll); addSubview(header)
        header.clipsToBounds = true
        header.document = document
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    public override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric) }
    public override func layout() {
        super.layout(); header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 48)
        scroll.frame = NSRect(x: 0, y: 48, width: bounds.width, height: max(0, bounds.height - 48)); document.resize()
        header.needsDisplay = true
        window?.invalidateCursorRects(for: header)
    }
    public func update(_ data: GridData) {
        let rebuilt = document.data.generation != data.generation || document.data.columns != data.columns
        if rebuilt { document.reset() }
        let previousHeat = Set(document.data.heat.keys)
        document.data = data
        document.animateHeat(from: previousHeat)
        // Widths follow column names, so reordering or hiding a column keeps everyone's width.
        if document.widthNames != data.columns.map(\.name) {
            var known = data.savedWidths
            for (name, width) in zip(document.widthNames, document.widths) { known[name] = width }
            document.widths = data.columns.map { known[$0.name] ?? ($0.kind == .number ? 140 : 260) }
            document.widthNames = data.columns.map(\.name)
        }
        needsLayout = true; document.resize(); header.needsDisplay = true; document.needsDisplay = true
        // A new filter, sort or column set starts at the first row.
        if rebuilt && scroll.contentView.bounds.minY > 0 {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    public func refresh() { document.needsDisplay = true }
    /// Forgets the widths set in this session; the next update starts from the saved widths.
    public func resetWidths() { document.widthNames = [] }
    private var lastScrollX: CGFloat = 0
    @objc private func scrolled() {
        let x = scroll.contentView.bounds.minX
        if x != lastScrollX { lastScrollX = x; header.needsDisplay = true; window?.invalidateCursorRects(for: header) }
        // The clip view moves what is already drawn, and AppKit asks only for the newly revealed
        // strip. Scaled tables place rows relative to the viewport, so they repaint in full.
        document.scrolled()
    }
    public func focus(row: Int, column: Int = 0) { window?.makeFirstResponder(document); document.move(row: row, column: column, extend: false) }
}

@MainActor public final class GridDocument: NSView {
    fileprivate var data = GridData()
    fileprivate var widths: [CGFloat] = []
    fileprivate var widthNames: [String] = []
    /// Laid-out text in two generations: when the newer one fills up it becomes the older one, so
    /// only lines unused for a whole generation are dropped, never everything at once.
    private var lines: [LineKey: CTLine] = [:]
    private var olderLines: [LineKey: CTLine] = [:]
    private static let linesPerGeneration = 8000
    private struct LineKey: Hashable { let kind: CellKind; let color: ObjectIdentifier; let text: String }
    private func clearLines() { lines.removeAll(); olderLines.removeAll() }
    /// The first visible row when pages were last requested, to tell which way the grid scrolls.
    private var lastFirstRow = 0
    private var direction = 0
    private var focusRow = 0, focusColumn = 0, anchorRow = 0, anchorColumn = 0
    private var reportedPaint = false
    private var hoverRow: Int?
    /// Fade-in progress of newly colored heatmap columns, from 0 to 1.
    private var heatFade: [Int: CGFloat] = [:]
    private var heatAnimating = false
    fileprivate func animateHeat(from previous: Set<Int>) {
        let added = Set(data.heat.keys).subtracting(previous)
        heatFade = heatFade.filter { data.heat[$0.key] != nil }
        guard !added.isEmpty else { return }
        for column in added { heatFade[column] = 0 }
        guard !heatAnimating else { return }
        heatAnimating = true
        stepHeat(start: CACurrentMediaTime())
    }
    /// One frame of the heatmap fade. Each frame schedules the next, so the fade stops with the view.
    private func stepHeat(start: CFTimeInterval) {
        // Ease-out over 0.35 s.
        let t = min(1, (CACurrentMediaTime() - start) / 0.35), eased = CGFloat(1 - pow(1 - t, 3))
        for key in heatFade.keys { heatFade[key] = max(heatFade[key] ?? 0, eased) }
        needsDisplay = true
        guard t < 1 else { heatFade.removeAll(); heatAnimating = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { [weak self] in self?.stepHeat(start: start) }
    }
    /// The row-number column grows with the largest row number.
    fileprivate var gutter: CGFloat { max(56, CGFloat(String(max(1, data.rowCount)).count) * 8.5 + 16) }
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override init(frame: NSRect) {
        super.init(frame: frame); clipsToBounds = true; setAccessibilityRole(.table); setAccessibilityLabel("Data grid")
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func mouseMoved(with event: NSEvent) {
        let (row, col) = location(event); setHover(row < data.rowCount ? row : nil)
        // A timestamp's tooltip shows the instant in the local time zone.
        var tip: String?
        if row >= 0, row < data.rowCount, data.columns.indices.contains(col), data.columns[col].kind == .temporal,
           let page = data.page(row / 256), page.isLoaded(col), page.columns[col].indices.contains(row - page.offset),
           let value = page.columns[col][row - page.offset] { tip = TemporalFormat.local(value) }
        if toolTip != tip { toolTip = tip }
    }
    public override func mouseExited(with event: NSEvent) { setHover(nil) }
    private func setHover(_ row: Int?) {
        guard row != hoverRow else { return }
        for old in [hoverRow, row].compactMap({ $0 }) { setNeedsDisplay(NSRect(x: visibleRect.minX, y: y(old), width: visibleRect.width, height: data.rowHeight)) }
        hoverRow = row
    }
    required init?(coder: NSCoder) { fatalError() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); clearLines(); needsDisplay = true }
    fileprivate func scrolled() {
        if scaled { needsDisplay = true }
        // The row under the pointer changes as rows move beneath it.
        if let window, hoverRow != nil || window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setHover(visibleRect.contains(point) ? row(at: point.y).flatMap { $0 < data.rowCount ? $0 : nil } : nil)
        }
        requestVisible()
    }
    fileprivate func reset() { clearLines(); lastFirstRow = 0; direction = 0; focusRow = 0; focusColumn = 0; anchorRow = 0; anchorColumn = 0; reportedPaint = false }
    fileprivate func resize() {
        let viewport = enclosingScrollView?.contentSize ?? .zero
        let size = NSSize(width: max(viewport.width, gutter + widths.reduce(0,+)), height: max(viewport.height, min(8_000_000, CGFloat(data.rowCount) * data.rowHeight)))
        // Panels animate the grid's width, so every size change repaints the newly exposed area.
        if size != frame.size { setFrameSize(size); needsDisplay = true }
    }
    private var scaled: Bool { CGFloat(data.rowCount) * data.rowHeight > 8_000_000 }
    fileprivate var firstRow: Int {
        if scaled { return max(0, min(max(0, data.rowCount - visibleRows), Int((visibleRect.minY / max(1, bounds.height - visibleRect.height)) * CGFloat(max(0, data.rowCount - visibleRows))))) }
        return max(0, Int(visibleRect.minY / data.rowHeight))
    }
    private var visibleRows: Int { Int(ceil(visibleRect.height / data.rowHeight)) }
    private func y(_ row: Int) -> CGFloat { scaled ? visibleRect.minY + CGFloat(row - firstRow) * data.rowHeight : CGFloat(row) * data.rowHeight }
    private func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(x: gutter + widths.prefix(column).reduce(0,+), y: y(row), width: widths.indices.contains(column) ? widths[column] : 0, height: data.rowHeight)
    }
    /// Requests the visible pages first, then reads ahead in the direction of scrolling: far
    /// ahead of it and only a little behind, so fast scrolling meets loaded rows.
    fileprivate func requestVisible() {
        guard data.rowCount > 0 else { return }
        let top = firstRow, bottom = min(data.rowCount - 1, top + visibleRows)
        if top != lastFirstRow { direction = top > lastFirstRow ? 1 : -1; lastFirstRow = top }
        let ahead = 1024, behind = direction == 0 ? 512 : 256
        let low = max(0, top - (direction < 0 ? ahead : behind)), high = min(data.rowCount - 1, bottom + (direction > 0 ? ahead : behind))
        var pages = Array((top / 256)...(bottom / 256))
        let after = Array((bottom / 256 + 1)...max(bottom / 256 + 1, high / 256)).filter { $0 <= high / 256 }
        let before = Array((low / 256)..<(top / 256)).reversed()
        pages += direction < 0 ? Array(before) + after : after + Array(before)
        for page in pages where data.page(page)?.isComplete != true { data.request(page) }
    }
    private func row(at y: CGFloat) -> Int? {
        guard y >= 0 else { return nil }
        return scaled ? firstRow + Int((y - visibleRect.minY) / data.rowHeight) : Int(y / data.rowHeight)
    }
    public override func draw(_ dirtyRect: NSRect) {
        ScanTheme.grid.setFill(); dirtyRect.fill()
        guard data.rowCount > 0, !widths.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let start = firstRow, end = min(data.rowCount, start + visibleRows + 2)
        var loaded: [Int: RowPage] = [:]
        for index in (start/256)...((max(start,end-1))/256) { loaded[index] = data.page(index) }
        if !reportedPaint, loaded[start/256] != nil {
            reportedPaint = true
            data.onFirstPaint()
        }
        for row in start..<end {
            let rect = NSRect(x: dirtyRect.minX, y: y(row), width: dirtyRect.width, height: data.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            if row == focusRow { ScanTheme.focusRow.setFill(); rect.fill() }
            else if row == hoverRow { ScanTheme.hoverRow.setFill(); rect.fill() }
            drawText(String(row + 1), kind: .number, rect: NSRect(x: 2, y: y(row), width: gutter - 10, height: data.rowHeight), color: ScanTheme.muted, right: true, context: context)
            for col in widths.indices {
                let cell = cellRect(row: row, column: col)
                guard cell.intersects(dirtyRect) else { continue }
                if (min(anchorRow, focusRow)...max(anchorRow, focusRow)).contains(row) && (min(anchorColumn,focusColumn)...max(anchorColumn,focusColumn)).contains(col) { ScanTheme.accent.withAlphaComponent(0.15).setFill(); cell.fill() }
                if let page = loaded[row/256], page.isLoaded(col), page.columns[col].indices.contains(row - page.offset) {
                    let value = page.columns[col][row - page.offset]
                    if let range = data.heat[col], let number = value.flatMap(Double.init), number.isFinite {
                        let span = range.upperBound - range.lowerBound
                        context.saveGState(); context.setAlpha(heatFade[col] ?? 1)
                        ScanTheme.heat(span > 0 ? (number - range.lowerBound) / span : 0.5).setFill(); cell.fill()
                        context.restoreGState()
                    }
                    let kind = data.columns[col].kind
                    var textRect = cell.insetBy(dx: 8, dy: 0)
                    var valueText = value ?? "NULL"
                    if valueText.isEmpty { valueText = "EMPTY" }
                    if col == 0, let node = data.pivot(row) {
                        textRect.origin.x += CGFloat(node.depth) * 16
                        textRect.size.width -= CGFloat(node.depth) * 16
                        valueText = (node.expanded ? "▾ " : "▸ ") + node.label
                    }
                    drawText(valueText, kind: kind, rect: textRect, color: ScanTheme.color(for: kind, value: value), right: kind == .number && value != nil && !(col == 0 && data.pivot(row) != nil), context: context)
                } else {
                    ScanTheme.line.setFill(); NSRect(x: cell.minX + 9, y: cell.midY - 2, width: cell.width * 0.4, height: 4).fill()
                }
                ScanTheme.line.setFill(); NSRect(x: cell.maxX - 0.5, y: cell.minY, width: 0.5, height: cell.height).fill()
            }
            ScanTheme.line.setFill(); NSRect(x: dirtyRect.minX, y: rect.maxY - 0.5, width: dirtyRect.width, height: 0.5).fill()
        }
        if focusRow >= start && focusRow < end && widths.indices.contains(focusColumn) {
            // A rounded ring with a soft glow, like a focused control.
            let ring = NSBezierPath(roundedRect: cellRect(row: focusRow, column: focusColumn).insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1.5
            context.saveGState()
            context.setShadow(offset: .zero, blur: 7, color: ScanTheme.accent.withAlphaComponent(0.55).cgColor)
            ScanTheme.accent.setStroke(); ring.stroke()
            context.restoreGState()
        }
        requestVisible()
    }
    private func drawText(_ text: String, kind: CellKind, rect: NSRect, color: NSColor, right: Bool, context: CGContext) {
        let key = LineKey(kind: kind, color: ObjectIdentifier(color), text: text)
        let line: CTLine
        if let cached = lines[key] { line = cached }
        else if let older = olderLines[key] { line = older; lines[key] = older }
        else {
            // Resolve the dynamic color now; the cache is cleared when the appearance changes.
            let attributes: [NSAttributedString.Key: Any] = [.font: ScanTheme.font(for: kind), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " ↵ "), attributes: attributes))
            lines[key] = line
        }
        if lines.count > Self.linesPerGeneration {
            olderLines = lines; lines = Dictionary(minimumCapacity: Self.linesPerGeneration)
        }
        context.saveGState(); context.clip(to: rect)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textMatrix = .identity
        context.translateBy(x: right ? max(rect.minX, rect.maxX - width) : rect.minX, y: rect.midY + 4.5)
        context.scaleBy(x: 1, y: -1); context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
    }
    private func location(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let row = scaled ? firstRow + Int((p.y - visibleRect.minY)/data.rowHeight) : Int(p.y/data.rowHeight)
        var x = gutter
        for (i, width) in widths.enumerated() { x += width; if p.x < x { return (row,i) } }
        return (row,max(0,widths.count - 1))
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); let (r,c) = location(event)
        move(row: r, column: c, extend: event.modifierFlags.contains(.shift))
        if c == 0 && data.pivot(r) != nil { data.togglePivot(r) }
        else if event.clickCount == 2 { data.inspect() }
    }
    public override func menu(for event: NSEvent) -> NSMenu? {
        let (row, column) = location(event)
        guard row < data.rowCount, data.columns.indices.contains(column) else { return nil }
        let selectedRows = min(anchorRow, focusRow)...max(anchorRow, focusRow), selectedColumns = min(anchorColumn, focusColumn)...max(anchorColumn, focusColumn)
        if !(selectedRows.contains(row) && selectedColumns.contains(column)) { window?.makeFirstResponder(self); move(row: row, column: column, extend: false) }
        let info = data.columns[column], menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: ""); let target = MenuAction(action)
            item.target = target; item.representedObject = target; return item
        }
        let page = data.page(row / 256)
        let loaded = page.map { $0.isLoaded(column) && $0.columns[column].indices.contains(row - $0.offset) } ?? false
        if data.filterable && loaded, let page {
            let value = page.columns[column][row - page.offset]
            var shown = (value ?? "NULL").replacingOccurrences(of: "\n", with: " ")
            if shown.count > 32 { shown = String(shown.prefix(31)) + "…" }
            if value?.isEmpty == true { shown = "EMPTY" }
            let filter = { (kind: ValueFilter) in { self.data.filterCell(row, column, kind) } }
            if value == nil {
                menu.addItem(item("Only NULL", filter(.isNull)))
                menu.addItem(item("Exclude NULL", filter(.isNotNull)))
            } else {
                menu.addItem(item("Only “\(shown)”", filter(.only)))
                menu.addItem(item("Exclude “\(shown)”", filter(.exclude)))
                if info.kind == .number || info.kind == .temporal {
                    menu.addItem(.separator())
                    for kind in [ValueFilter.greater, .greaterOrEqual, .less, .lessOrEqual] {
                        let symbol = switch kind { case .greater: ">"; case .greaterOrEqual: "≥"; case .less: "<"; default: "≤" }
                        menu.addItem(item("\(symbol) \(shown)", filter(kind)))
                    }
                } else if info.kind == .text {
                    menu.addItem(item("Contains “\(shown)”", filter(.contains)))
                }
                menu.addItem(.separator())
                menu.addItem(item("Exclude NULL", filter(.isNotNull)))
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Copy") { self.copy(nil) })
        menu.addItem(item("Inspect Value") { self.data.inspect() })
        if data.filterable { menu.addItem(item("Profile “\(info.name)”") { self.data.showProfile(column) }) }
        return menu
    }
    public override func mouseDragged(with event: NSEvent) { let (r,c) = location(event); move(row: r, column: c, extend: true); autoscroll(with: event) }
    fileprivate func move(row: Int, column: Int, extend: Bool) {
        let old = cellRect(row: focusRow,column: focusColumn)
        focusRow = max(0,min(data.rowCount - 1,row)); focusColumn = max(0,min(widths.count - 1,column))
        if !extend { anchorRow = focusRow; anchorColumn = focusColumn }
        if focusRow < firstRow || focusRow >= firstRow + visibleRows - 1 {
            let target = scaled ? CGFloat(focusRow) / CGFloat(max(1,data.rowCount - visibleRows)) * max(0,bounds.height - visibleRect.height) : CGFloat(max(0,focusRow - 1)) * data.rowHeight
            scroll(NSPoint(x: visibleRect.minX,y: target))
        }
        let rect = cellRect(row: focusRow,column: focusColumn)
        if rect.minX < visibleRect.minX || rect.maxX > visibleRect.maxX { scrollToVisible(rect) }
        if extend { needsDisplay = true } else { setNeedsDisplay(old); setNeedsDisplay(rect); needsDisplay = true }
        data.select(focusRow,focusColumn); requestVisible()
        setAccessibilityValue("Row \(focusRow + 1), column \(data.columns.indices.contains(focusColumn) ? data.columns[focusColumn].name : "")")
    }
    public override func keyDown(with event: NSEvent) {
        let extend = event.modifierFlags.contains(.shift), command = event.modifierFlags.contains(.command)
        var r = focusRow, c = focusColumn
        switch event.keyCode {
        case 123: if data.pivot(r) != nil { data.togglePivot(r); return }; c = command ? 0 : c - 1
        case 124: if data.pivot(r) != nil { data.togglePivot(r); return }; c = command ? widths.count - 1 : c + 1
        case 125: r = command ? data.rowCount - 1 : r + 1
        case 126: r = command ? 0 : r - 1
        case 116: r -= visibleRows
        case 121: r += visibleRows
        case 115: c = 0
        case 119: c = widths.count - 1
        case 48: c += extend ? -1 : 1; if c >= widths.count { c = 0; r += 1 }; if c < 0 { c = widths.count - 1; r -= 1 }
        case 49,36: data.inspect(); return
        default: super.keyDown(with: event); return
        }
        move(row:r,column:c,extend:extend && event.keyCode != 48)
    }
    @objc public func copy(_ sender: Any?) { guard data.rowCount > 0, !widths.isEmpty else { return }; data.copy(min(anchorRow,focusRow)...max(anchorRow,focusRow), min(anchorColumn,focusColumn)...max(anchorColumn,focusColumn), NSApp.currentEvent?.modifierFlags.contains(.option) == true) }
    @objc public override func selectAll(_ sender: Any?) { anchorRow = 0; anchorColumn = 0; focusRow = max(0,data.rowCount-1); focusColumn = max(0,widths.count-1); needsDisplay = true }
}

@MainActor private final class GridHeader: NSView {
    weak var document: GridDocument?
    private var resizeIndex: Int?, startX: CGFloat = 0, startWidth: CGFloat = 0
    override var isFlipped: Bool { true }
    override func resetCursorRects() {
        guard let document else { return }
        var edge: CGFloat = document.gutter - document.visibleRect.minX
        for width in document.widths {
            edge += width
            let rect = NSRect(x:edge-6,y:0,width:12,height:bounds.height).intersection(bounds)
            if !rect.isEmpty { addCursorRect(rect,cursor:.resizeLeftRight) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        ScanTheme.chrome.setFill(); bounds.intersection(dirtyRect).fill()
        guard let document else { return }
        var x: CGFloat = document.gutter - document.visibleRect.minX
        for (i, column) in document.data.columns.enumerated() {
            let width = document.widths[i]
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            var nameWidth = width - 16
            let sorts = document.data.sorts
            if let order = sorts.firstIndex(where: { $0.column == column.name }) {
                // Sorted columns carry a text badge: ASC or DESC, numbered when several sorts apply.
                let label = (sorts[order].ascending ? "ASC" : "DESC") + (sorts.count > 1 ? " \(order + 1)" : "")
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: ScanTheme.accent]
                let size = (label as NSString).size(withAttributes: attributes)
                let badge = NSRect(x: x + width - 10 - size.width - 10, y: 7, width: size.width + 10, height: 16)
                if badge.minX > x + 40 {
                    ScanTheme.accent.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
                    (label as NSString).draw(at: NSPoint(x: badge.minX + 5, y: badge.midY - size.height / 2), withAttributes: attributes)
                    nameWidth = badge.minX - x - 14
                }
            }
            (column.name as NSString).draw(in: NSRect(x:x+8,y:6,width:nameWidth,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:ScanTheme.primary,.paragraphStyle:style])
            var typeWidth = width - 16
            if let bins = document.data.sparklines[i], bins.count > 1, let peak = bins.max(), peak > 0, width >= 110 {
                // A small histogram of the column's values, right-aligned on the type line.
                let spark = NSRect(x: x + width - 8 - min(60, width * 0.36), y: 27, width: min(60, width * 0.36), height: 13)
                let step = spark.width / CGFloat(bins.count)
                ScanTheme.accent.withAlphaComponent(0.5).setFill()
                for (b, count) in bins.enumerated() where count > 0 {
                    let h = max(1.5, spark.height * sqrt(CGFloat(count) / CGFloat(peak)))
                    NSBezierPath(roundedRect: NSRect(x: spark.minX + CGFloat(b) * step + 0.5, y: spark.maxY - h, width: max(1, step - 1), height: h), xRadius: 0.75, yRadius: 0.75).fill()
                }
                typeWidth = spark.minX - x - 14
            }
            (column.type.lowercased() as NSString).draw(in: NSRect(x:x+8,y:26,width:typeWidth,height:15),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:ScanTheme.muted,.paragraphStyle:style])
            if document.data.heat[i] != nil, let context = NSGraphicsContext.current?.cgContext {
                // A thin gradient along the header's bottom edge marks a heatmap column and its scale.
                let bar = NSRect(x: x + 8, y: bounds.height - 5, width: max(0, width - 16), height: 2.5)
                let colors = [0, 0.5, 1].map { ScanTheme.heat($0).withAlphaComponent(1).cgColor } as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1]) {
                    context.saveGState(); context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)); context.clip()
                    context.drawLinearGradient(gradient, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
                    context.restoreGState()
                }
            }
            ScanTheme.line.setFill(); NSRect(x:x+width-0.5,y:0,width:0.5,height:bounds.height).fill(); x += width
        }
    }
    private func column(at event: NSEvent) -> Int? {
        guard let document else { return nil }
        let x = convert(event.locationInWindow,from:nil).x + document.visibleRect.minX
        var edge = document.gutter
        for i in document.widths.indices { edge += document.widths[i]; if x >= edge - document.widths[i] && x < edge { return i } }
        return nil
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document, let index = column(at: event), document.data.columns.indices.contains(index) else { return nil }
        let column = document.data.columns[index], menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: ""); let target = MenuAction(action)
            item.target = target; item.representedObject = target; return item
        }
        if document.data.filterable { menu.addItem(item("Show Profile") { document.data.showProfile(index) }); menu.addItem(.separator()) }
        menu.addItem(item("Sort Ascending") { document.data.sortColumn(index, true) })
        menu.addItem(item("Sort Descending") { document.data.sortColumn(index, false) })
        if column.kind == .number {
            menu.addItem(.separator())
            let heat = item("Color as Heatmap") { document.data.toggleHeat(index) }
            heat.state = document.data.heat[index] == nil ? .off : .on; menu.addItem(heat)
        }
        menu.addItem(.separator())
        menu.addItem(item("Hide Column") { document.data.hideColumn(index) })
        return menu
    }
    override func mouseDown(with event: NSEvent) {
        resizeIndex = nil
        guard let document else { return }; let x = convert(event.locationInWindow,from:nil).x + document.visibleRect.minX
        var edge: CGFloat = document.gutter
        for i in document.widths.indices {
            edge += document.widths[i]
            if abs(x-edge) <= 6 {
                resizeIndex = i; startX = event.locationInWindow.x; startWidth = document.widths[i]
                if event.clickCount == 2 { document.widths[i] = 280; startWidth = 280; document.resize(); document.needsDisplay = true; needsDisplay = true; reportWidths() }
                NSCursor.resizeLeftRight.set(); window?.invalidateCursorRects(for:self)
                return
            }
        }
        edge = document.gutter
        for i in document.widths.indices {
            edge += document.widths[i]
            if x < edge { document.data.sort(i,event.modifierFlags.contains(.shift)); return }
        }
    }
    override func mouseDragged(with event: NSEvent) { guard let document, let i = resizeIndex else { return }; document.widths[i] = max(70,min(1200,startWidth + event.locationInWindow.x-startX)); document.resize(); document.needsDisplay = true; needsDisplay = true; NSCursor.resizeLeftRight.set(); window?.invalidateCursorRects(for:self) }
    override func mouseUp(with event: NSEvent) {
        if resizeIndex != nil { reportWidths() }
        resizeIndex = nil; NSCursor.arrow.set(); window?.invalidateCursorRects(for:self)
    }
    private func reportWidths() {
        guard let document else { return }
        document.data.widthsChanged(Dictionary(zip(document.widthNames, document.widths), uniquingKeysWith: { a, _ in a }))
    }
}

/// Runs a closure from an AppKit menu item. The item keeps the target alive.
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Renders DuckDB temporal text in the local time zone. Values without an offset are read as UTC.
public enum TemporalFormat {
    public static func local(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 10, trimmed.contains(where: { $0 == ":" }) else { return nil }
        var value = trimmed.replacingOccurrences(of: " ", with: "T")
        // "+00" or "+05:30" offsets: normalise to ISO 8601.
        if let r = value.range(of: #"[+-]\d{2}$"#, options: .regularExpression), value.distance(from: value.startIndex, to: r.lowerBound) > 10 { value += ":00" }
        let hasZone = value.hasSuffix("Z") || value.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
        if !hasZone { value += "Z" }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else { return nil }
        let out = DateFormatter(); out.dateStyle = .full; out.timeStyle = .long; out.timeZone = .current
        return out.string(from: date)
    }
}
