import Foundation

/// Start with the user's budget; grow only after a query runs out of memory.
struct QueryBudget {
    private(set) var memoryMB: Int
    private(set) var threads: Int
    let ceilingMB: Int

    init(memoryMB: Int, threads: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.memoryMB = max(64,memoryMB)
        self.threads = max(1,threads)
        ceilingMB = max(self.memoryMB,min(4096,Int(physicalMemory / 8 / 1_000_000)))
    }

    mutating func recover() -> Bool {
        // Concurrent Parquet scans multiply decoding buffers. Preserve row order.
        if threads > 1 { threads = 1; return true }
        guard memoryMB < ceilingMB else { return false }
        memoryMB = min(ceilingMB,memoryMB * 2)
        return true
    }
}
