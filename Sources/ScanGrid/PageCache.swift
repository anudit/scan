import Foundation
import ScanQuery
@MainActor public final class PageCache {
    private var pages: [Int: RowPage] = [:]
    private var recency: [Int] = []
    public private(set) var bytes = 0
    public var limit = 32 * 1024 * 1024
    public init() {}
    public func page(_ index: Int) -> RowPage? {
        guard let page = pages[index] else { return nil }
        recency.removeAll { $0 == index }; recency.append(index); return page
    }
    public func insert(_ page: RowPage, index: Int) {
        if let old = pages[index] { bytes -= old.byteCount }
        pages[index] = page; bytes += page.byteCount
        recency.removeAll { $0 == index }; recency.append(index)
        while bytes > limit, let key = recency.first { recency.removeFirst(); bytes -= pages.removeValue(forKey: key)?.byteCount ?? 0 }
    }
    public func removeAll() { pages.removeAll(); recency.removeAll(); bytes = 0 }
}
