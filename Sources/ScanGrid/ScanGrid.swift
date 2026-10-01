import AppKit
import CoreText
import ScanQuery
import ScanTheme

@MainActor public final class GridData {
    public var columns: [Column] = []
    public var rowCount = 0
    public var generation = 0
    public var rowHeight: CGFloat = 28
    public var page: (Int) -> RowPage? = { _ in nil }
    public var request: (Int) -> Void = { _ in }
    public var sort: (Int, Bool) -> Void = { _, _ in }
    public var select: (Int, Int) -> Void = { _, _ in }
    public var inspect: () -> Void = {}
    public var copy: (ClosedRange<Int>, ClosedRange<Int>, Bool) -> Void = { _, _, _ in }
    public var pivot: ((Int) -> (depth: Int, expanded: Bool, label: String)?) = { _ in nil }
    public var togglePivot: (Int) -> Void = { _ in }
    public var onFirstPaint: () -> Void = {}
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
        window?.invalidateCursorRects(for: header)
    }
    public func update(_ data: GridData) {
        if document.data.generation != data.generation || document.data.columns != data.columns { document.reset() }
        document.data = data
        if document.widths.count != data.columns.count { document.widths = data.columns.map { $0.kind == .number ? 140 : 260 } }
        needsLayout = true; document.resize(); header.needsDisplay = true; document.needsDisplay = true
    }
    public func refresh() { document.needsDisplay = true }
    @objc private func scrolled() { header.needsDisplay = true; window?.invalidateCursorRects(for: header); document.needsDisplay = true; document.requestVisible() }
    public func focus(row: Int, column: Int = 0) { window?.makeFirstResponder(document); document.move(row: row, column: column, extend: false) }
}

@MainActor public final class GridDocument: NSView {
    fileprivate var data = GridData()
    fileprivate var widths: [CGFloat] = []
    private var lines: [String: CTLine] = [:]
    private var focusRow = 0, focusColumn = 0, anchorRow = 0, anchorColumn = 0
    private var reportedPaint = false
    private let gutter: CGFloat = 56
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override init(frame: NSRect) { super.init(frame: frame); clipsToBounds = true; setAccessibilityRole(.table); setAccessibilityLabel("Data grid") }
    required init?(coder: NSCoder) { fatalError() }
    fileprivate func reset() { lines.removeAll(); focusRow = 0; focusColumn = 0; anchorRow = 0; anchorColumn = 0; reportedPaint = false }
    fileprivate func resize() {
        let viewport = enclosingScrollView?.contentSize ?? .zero
        setFrameSize(NSSize(width: max(viewport.width, gutter + widths.reduce(0,+)), height: max(viewport.height, min(8_000_000, CGFloat(data.rowCount) * data.rowHeight))))
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
    fileprivate func requestVisible() {
        guard data.rowCount > 0 else { return }
        let first = firstRow / 256, last = min(data.rowCount - 1, firstRow + visibleRows + 512) / 256
        for page in first...last { if data.page(page) == nil { data.request(page) } }
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
            if row == focusRow { NSColor(white: 0.16, alpha: 1).setFill(); rect.fill() }
            drawText(String(row + 1), kind: .number, rect: NSRect(x: 2, y: y(row), width: gutter - 10, height: data.rowHeight), color: ScanTheme.muted, right: true, context: context)
            for col in widths.indices {
                let cell = cellRect(row: row, column: col)
                guard cell.intersects(dirtyRect) else { continue }
                if (min(anchorRow, focusRow)...max(anchorRow, focusRow)).contains(row) && (min(anchorColumn,focusColumn)...max(anchorColumn,focusColumn)).contains(col) { ScanTheme.accent.withAlphaComponent(0.15).setFill(); cell.fill() }
                if let page = loaded[row/256], page.columns.indices.contains(col), page.columns[col].indices.contains(row - page.offset) {
                    let value = page.columns[col][row - page.offset]
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
            ScanTheme.accent.setStroke(); let ring = NSBezierPath(rect: cellRect(row: focusRow, column: focusColumn).insetBy(dx: 1, dy: 1)); ring.lineWidth = 1.5; ring.stroke()
        }
        requestVisible()
    }
    private func drawText(_ text: String, kind: CellKind, rect: NSRect, color: NSColor, right: Bool, context: CGContext) {
        let key = "\(kind.rawValue)|\(color.description)|\(text)"
        let line: CTLine
        if let cached = lines[key] { line = cached }
        else {
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " ↵ "), attributes: [.font: ScanTheme.font(for: kind), .foregroundColor: color]))
            if lines.count > 16000 { lines.removeAll(keepingCapacity: true) }; lines[key] = line
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
        var edge: CGFloat = 56 - document.visibleRect.minX
        for width in document.widths {
            edge += width
            let rect = NSRect(x:edge-6,y:0,width:12,height:bounds.height).intersection(bounds)
            if !rect.isEmpty { addCursorRect(rect,cursor:.resizeLeftRight) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        ScanTheme.chrome.setFill(); bounds.intersection(dirtyRect).fill()
        guard let document else { return }
        var x: CGFloat = 56 - document.visibleRect.minX
        for (i, column) in document.data.columns.enumerated() {
            let width = document.widths[i]
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (column.name as NSString).draw(in: NSRect(x:x+8,y:6,width:width-16,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:ScanTheme.primary,.paragraphStyle:style])
            (column.type.lowercased() as NSString).draw(in: NSRect(x:x+8,y:26,width:width-16,height:15),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:ScanTheme.muted,.paragraphStyle:style])
            ScanTheme.line.setFill(); NSRect(x:x+width-0.5,y:0,width:0.5,height:bounds.height).fill(); x += width
        }
    }
    override func mouseDown(with event: NSEvent) {
        resizeIndex = nil
        guard let document else { return }; let x = convert(event.locationInWindow,from:nil).x + document.visibleRect.minX
        var edge: CGFloat = 56
        for i in document.widths.indices {
            edge += document.widths[i]
            if abs(x-edge) <= 6 {
                resizeIndex = i; startX = event.locationInWindow.x; startWidth = document.widths[i]
                if event.clickCount == 2 { document.widths[i] = 280; startWidth = 280; document.resize(); document.needsDisplay = true; needsDisplay = true }
                NSCursor.resizeLeftRight.set(); window?.invalidateCursorRects(for:self)
                return
            }
        }
        edge = 56
        for i in document.widths.indices {
            edge += document.widths[i]
            if x < edge { document.data.sort(i,event.modifierFlags.contains(.shift)); return }
        }
    }
    override func mouseDragged(with event: NSEvent) { guard let document, let i = resizeIndex else { return }; document.widths[i] = max(70,min(1200,startWidth + event.locationInWindow.x-startX)); document.resize(); document.needsDisplay = true; needsDisplay = true; NSCursor.resizeLeftRight.set(); window?.invalidateCursorRects(for:self) }
    override func mouseUp(with event: NSEvent) { resizeIndex = nil; NSCursor.arrow.set(); window?.invalidateCursorRects(for:self) }
}
