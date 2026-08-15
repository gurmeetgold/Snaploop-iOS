import Foundation

/// A single page of results plus an opaque cursor for the next page. Keeps
/// photo-feed queries bounded (50–100 per page) so a client never pulls
/// thousands of rows at once.
public struct Page<Item: Identifiable & Sendable>: Sendable where Item.ID == String {
    public let items: [Item]
    public let nextCursor: String?     // pass back to fetch the next page; nil = last page
    public var hasMore: Bool { nextCursor != nil }

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Pure, cursor-based pagination over an already-ordered array. Firestore does
/// the real paging in production; this backs the in-memory repository, tests,
/// and any client-side slicing, with identical semantics.
public enum Paginator {
    public static func page<Item: Identifiable & Sendable>(
        from ordered: [Item],
        after cursor: String?,
        limit: Int
    ) -> Page<Item> where Item.ID == String {
        let capped = max(1, limit)
        let startIndex: Int
        if let cursor, let idx = ordered.firstIndex(where: { $0.id == cursor }) {
            startIndex = ordered.index(after: idx)
        } else {
            startIndex = ordered.startIndex
        }
        guard startIndex < ordered.endIndex else { return Page(items: [], nextCursor: nil) }
        let endIndex = min(startIndex + capped, ordered.endIndex)
        let slice = Array(ordered[startIndex..<endIndex])
        let next = endIndex < ordered.endIndex ? slice.last?.id : nil
        return Page(items: slice, nextCursor: next)
    }
}
