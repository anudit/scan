// Brings the target app's main window to front and posts scroll-wheel events over it.
// Usage: swift bench/scroll_stress.swift <OwnerName> [seconds=10] [linesPerTick=40]
// Needs Accessibility permission for the terminal (System Settings > Privacy > Accessibility).
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let owner = args.count > 1 ? args[1] : "Tad"
let seconds = args.count > 2 ? Double(args[2])! : 10
let lines = args.count > 3 ? Int32(args[3])! : 40

let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
guard let w = wins.first(where: {
    ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0
        && ((($0[kCGWindowBounds as String] as? [String: Double])?["Height"]) ?? 0) > 200
}), let pid = w[kCGWindowOwnerPID as String] as? pid_t,
    let b = w[kCGWindowBounds as String] as? [String: Double]
else { fputs("window for \(owner) not found\n", stderr); exit(1) }

NSRunningApplication(processIdentifier: pid)?.activate()
usleep(500_000)
let center = CGPoint(x: b["X"]! + b["Width"]! / 2, y: b["Y"]! + b["Height"]! / 2)
CGWarpMouseCursorPosition(center)

let hz = 60.0
let ticks = Int(seconds * hz)
for i in 0..<ticks {
    // scroll down for first half, up for second half
    let dir: Int32 = i < ticks / 2 ? -lines : lines
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dir, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
    usleep(UInt32(1_000_000 / hz))
}
print("posted \(ticks) scroll events to \(owner) pid \(pid)")
