import AppKit
import XCTest
import ScanQuery
@testable import ScanGrid

@MainActor final class GridTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, x: CGFloat, header: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:header.convert(NSPoint(x:x,y:12),to:nil),modifierFlags:[],timestamp:0,
                           windowNumber:header.window?.windowNumber ?? 0,context:nil,eventNumber:1,clickCount:clicks,pressure:1)!
    }
    func testDividerDragResizesWithoutSortingAndUpdatesAfterHorizontalScroll() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:300),styleMask:[.borderless],backing:.buffered,defer:false)
        let grid = ScanGrid(frame:NSRect(x:0,y:0,width:200,height:300)); window.contentView = grid
        let data = GridData(); data.columns = [Column("id","BIGINT"),Column("text","VARCHAR")]
        var sorts = 0; data.sort = { _,_ in sorts += 1 }
        grid.update(data); grid.layoutSubtreeIfNeeded()
        let header = grid.subviews.first { $0 !== grid.scroll }!
        let initial = grid.document.frame.width
        // Grab just to the right of the first divider, then widen by 50 points.
        header.mouseDown(with:event(.leftMouseDown,x:198,header:header))
        header.mouseDragged(with:event(.leftMouseDragged,x:248,header:header))
        header.mouseUp(with:event(.leftMouseUp,x:248,header:header))
        XCTAssertEqual(grid.document.frame.width,initial+50,accuracy:0.01); XCTAssertEqual(sorts,0)
        grid.scroll.contentView.scroll(to:NSPoint(x:100,y:0)); grid.scroll.reflectScrolledClipView(grid.scroll.contentView)
        // The divider is now at 146 in the fixed header.
        header.mouseDown(with:event(.leftMouseDown,x:144,header:header))
        header.mouseDragged(with:event(.leftMouseDragged,x:174,header:header))
        header.mouseUp(with:event(.leftMouseUp,x:174,header:header))
        XCTAssertEqual(grid.document.frame.width,initial+80,accuracy:0.01); XCTAssertEqual(sorts,0)
        header.mouseDown(with:event(.leftMouseDown,x:90,header:header))
        header.mouseUp(with:event(.leftMouseUp,x:90,header:header))
        XCTAssertEqual(sorts,1)
        window.contentView = nil
    }
}
