import XCTest
@testable import SnapLoop

private struct Row: Identifiable, Sendable, Equatable { let id: String }

final class PaginationTests: XCTestCase {

    private let rows = (0..<10).map { Row(id: "r\($0)") }

    func testFirstPageStartsAtBeginning() {
        let page = Paginator.page(from: rows, after: nil, limit: 4)
        XCTAssertEqual(page.items.map(\.id), ["r0", "r1", "r2", "r3"])
        XCTAssertEqual(page.nextCursor, "r3")
        XCTAssertTrue(page.hasMore)
    }

    func testSubsequentPageStartsAfterCursor() {
        let page = Paginator.page(from: rows, after: "r3", limit: 4)
        XCTAssertEqual(page.items.map(\.id), ["r4", "r5", "r6", "r7"])
        XCTAssertEqual(page.nextCursor, "r7")
    }

    func testLastPageHasNoCursor() {
        let page = Paginator.page(from: rows, after: "r7", limit: 4)
        XCTAssertEqual(page.items.map(\.id), ["r8", "r9"])
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    func testCursorPastEndYieldsEmpty() {
        let page = Paginator.page(from: rows, after: "r9", limit: 4)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    func testWholePageWhenLimitExceedsCount() {
        let page = Paginator.page(from: rows, after: nil, limit: 100)
        XCTAssertEqual(page.items.count, 10)
        XCTAssertNil(page.nextCursor)
    }
}
