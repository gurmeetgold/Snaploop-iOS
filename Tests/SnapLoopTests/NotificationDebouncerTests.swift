import XCTest
@testable import SnapLoop

final class NotificationDebouncerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func batch(count: Int, first: Date, last: Date) -> MatchNotificationBatch {
        MatchNotificationBatch(eventId: "e1", eventName: "Montreal", userId: "u1",
                               newPhotoCount: count, firstMatchAt: first, lastMatchAt: last)
    }

    func testDoesNotSendEmptyBatch() {
        let d = NotificationDebouncer()
        XCTAssertFalse(d.shouldSend(batch(count: 0, first: t0, last: t0),
                                    now: t0.addingTimeInterval(3600)))
    }

    func testWaitsDuringActiveTrickle() {
        let d = NotificationDebouncer(quietWindow: 12 * 60, maxWait: 60 * 60)
        // Last match 5 min ago, first 5 min ago → still within quiet window, under cap.
        let b = batch(count: 3, first: t0.addingTimeInterval(-5 * 60), last: t0.addingTimeInterval(-5 * 60))
        XCTAssertFalse(d.shouldSend(b, now: t0))
    }

    func testSendsAfterQuietWindow() {
        let d = NotificationDebouncer(quietWindow: 12 * 60, maxWait: 60 * 60)
        let b = batch(count: 3, first: t0.addingTimeInterval(-20 * 60), last: t0.addingTimeInterval(-13 * 60))
        XCTAssertTrue(d.shouldSend(b, now: t0))
    }

    func testSendsWhenMaxWaitCapReachedEvenIfStillActive() {
        let d = NotificationDebouncer(quietWindow: 12 * 60, maxWait: 60 * 60)
        // Steady trickle: last match just now, but first was 61 min ago.
        let b = batch(count: 40, first: t0.addingTimeInterval(-61 * 60), last: t0.addingTimeInterval(-1 * 60))
        XCTAssertTrue(d.shouldSend(b, now: t0))
    }

    func testCopyIsHumanAndPluralizes() {
        let d = NotificationDebouncer()
        let single = d.payload(for: batch(count: 1, first: t0, last: t0), inviteToken: nil)
        XCTAssertEqual(single.body, "We found 1 new photo of you in Montreal.")
        let many = d.payload(for: batch(count: 37, first: t0, last: t0), inviteToken: nil)
        XCTAssertEqual(many.body, "We found 37 new photos of you in Montreal.")
        XCTAssertTrue(many.deepLinkPath.contains("my-photos"))
    }
}
