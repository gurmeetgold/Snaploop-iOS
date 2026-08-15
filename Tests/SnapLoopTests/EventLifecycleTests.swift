import XCTest
@testable import SnapLoop

final class EventLifecycleTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private var config = RemoteConfigValues.default   // grace = 3 days by default

    private func event(start: Date, end: Date) -> Event {
        Event(id: "e", joinCode: "ABC234", creatorUserId: "u", name: "Party",
              startsAt: start, endsAt: end, createdAt: start)
    }

    private func lifecycleStatus(at now: Date, start: Date, end: Date) -> EventLifecycle.Status {
        EventLifecycle.status(for: event(start: start, end: end),
                              clock: FixedClock(now), config: config)
    }

    func testUpcomingBeforeStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let s = lifecycleStatus(at: start.addingTimeInterval(-1), start: start, end: start + 5 * day)
        XCTAssertEqual(s, .upcoming)
    }

    func testActiveWithinWindowInclusiveOfBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        XCTAssertEqual(lifecycleStatus(at: start, start: start, end: end), .active)
        XCTAssertEqual(lifecycleStatus(at: start + 2 * day, start: start, end: end), .active)
        XCTAssertEqual(lifecycleStatus(at: end, start: start, end: end), .active)
    }

    func testGraceAfterEndWithinWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        // grace = 3 days
        let s = lifecycleStatus(at: end + 2 * day, start: start, end: end)
        XCTAssertEqual(s, .grace)
    }

    func testExpiredPastGrace() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let s = lifecycleStatus(at: end + 3 * day + 1, start: start, end: end)
        XCTAssertEqual(s, .expired)
    }

    func testGraceEndBoundaryIsInclusive() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let graceEnd = end + 3 * day
        XCTAssertEqual(lifecycleStatus(at: graceEnd, start: start, end: end), .grace)
        XCTAssertEqual(lifecycleStatus(at: graceEnd + 1, start: start, end: end), .expired)
    }

    // MARK: Capability gates

    func testCanSyncDuringActiveAndGraceOnly() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let e = event(start: start, end: end)
        XCTAssertFalse(EventLifecycle.canSync(e, clock: FixedClock(start - 1), config: config))
        XCTAssertTrue(EventLifecycle.canSync(e, clock: FixedClock(start + day), config: config))
        XCTAssertTrue(EventLifecycle.canSync(e, clock: FixedClock(end + day), config: config))    // grace
        XCTAssertFalse(EventLifecycle.canSync(e, clock: FixedClock(end + 4 * day), config: config)) // expired
    }

    func testCanDownloadThroughGraceButNotAfter() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let e = event(start: start, end: end)
        XCTAssertTrue(EventLifecycle.canDownload(e, clock: FixedClock(end + 3 * day), config: config))
        XCTAssertFalse(EventLifecycle.canDownload(e, clock: FixedClock(end + 3 * day + 1), config: config))
    }

    // MARK: Validation

    func testValidateDatesRejectsEndBeforeStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start, endsAt: start - day, config: config)) { error in
            XCTAssertEqual(error as? AppError, .invalidEventDates)
        }
    }

    func testValidateDatesRejectsOverlongEvent() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let tooLong = start + TimeInterval(config.maxEventDurationDays + 1) * day
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start, endsAt: tooLong, config: config)) { error in
            XCTAssertEqual(error as? AppError, .eventDurationTooLong(maxDays: config.maxEventDurationDays))
        }
    }

    func testValidateDatesAcceptsInRange() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ok = start + TimeInterval(config.defaultEventDurationDays) * day
        XCTAssertNoThrow(try EventLifecycle.validateDates(startsAt: start, endsAt: ok, config: config))
    }

    func testDefaultEndDateUsesConfiguredDuration() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = EventLifecycle.defaultEndDate(from: start, config: config)
        XCTAssertEqual(end.timeIntervalSince(start),
                       TimeInterval(config.defaultEventDurationDays) * day, accuracy: 0.5)
    }
}
