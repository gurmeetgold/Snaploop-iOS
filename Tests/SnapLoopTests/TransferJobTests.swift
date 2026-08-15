import XCTest
@testable import SnapLoop

final class TransferJobTests: XCTestCase {

    private func job(_ status: TransferStatus = .queued) -> TransferJob {
        TransferJob(id: "t1", eventId: "e1", photoId: "p1", sourceUserId: "s",
                    requestingUserId: "r", status: status,
                    requestedAt: Date(timeIntervalSince1970: 1))
    }

    func testHappyPathTransitions() throws {
        var j = job()
        try j.advance(to: .sourceNotified)
        try j.advance(to: .uploading)
        try j.advance(to: .ready)
        try j.advance(to: .downloading)
        try j.advance(to: .completed)
        XCTAssertEqual(j.status, .completed)
        XCTAssertTrue(j.status.isTerminal)
    }

    func testIllegalTransitionThrows() {
        var j = job()
        XCTAssertThrowsError(try j.advance(to: .completed)) { error in
            guard case AppError.backend = error else { return XCTFail("wrong error") }
        }
        XCTAssertEqual(j.status, .queued, "State unchanged after illegal transition")
    }

    func testSameStateIsIdempotentNoop() throws {
        var j = job(.uploading)
        try j.advance(to: .uploading)   // duplicate/retried message
        XCTAssertEqual(j.status, .uploading)
    }

    func testFailureCanRetryByRequeue() throws {
        var j = job(.uploading)
        try j.advance(to: .failed)
        try j.advance(to: .queued)      // retry
        XCTAssertEqual(j.status, .queued)
    }

    func testTerminalStatesAllowNoFurtherTransitions() {
        for terminal in [TransferStatus.completed, .expired] {
            var j = job(terminal)
            XCTAssertThrowsError(try j.advance(to: .downloading))
            XCTAssertEqual(j.status, terminal)
        }
    }

    func testReadyCanExpire() throws {
        var j = job(.ready)
        try j.advance(to: .expired)
        XCTAssertEqual(j.status, .expired)
    }

    func testUserStatusIsHumanNeverTechnical() {
        let waiting = job(.sourceNotified).userStatus(sourceName: "Priya")
        XCTAssertTrue(waiting.contains("Priya"))
        XCTAssertFalse(waiting.lowercased().contains("upload path"))
    }
}
