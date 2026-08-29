import XCTest
@testable import SnapLoop

final class EventLifecycleTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private var config = RemoteConfigValues.default

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

    func testPhotoWindowAfterEndWithinFifteenDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let s = lifecycleStatus(at: end + 10 * day, start: start, end: end)
        XCTAssertEqual(s, .grace)
    }

    func testExpiredPastFifteenDayPhotoWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let s = lifecycleStatus(at: end + 15 * day + 1, start: start, end: end)
        XCTAssertEqual(s, .expired)
    }

    func testPhotoWindowEndBoundaryIsInclusive() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let graceEnd = end + 15 * day
        XCTAssertEqual(lifecycleStatus(at: graceEnd, start: start, end: end), .grace)
        XCTAssertEqual(lifecycleStatus(at: graceEnd + 1, start: start, end: end), .expired)
    }

    func testCanSyncDuringActiveAndPhotoWindowOnly() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let e = event(start: start, end: end)
        XCTAssertFalse(EventLifecycle.canSync(e, clock: FixedClock(start - 1), config: config))
        XCTAssertTrue(EventLifecycle.canSync(e, clock: FixedClock(start + day), config: config))
        XCTAssertTrue(EventLifecycle.canSync(e, clock: FixedClock(end + 10 * day), config: config))
        XCTAssertFalse(EventLifecycle.canSync(e, clock: FixedClock(end + 16 * day), config: config))
    }

    func testCanDownloadThroughPhotoWindowButNotAfter() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start + 5 * day
        let e = event(start: start, end: end)
        XCTAssertTrue(EventLifecycle.canDownload(e, clock: FixedClock(end + 15 * day), config: config))
        XCTAssertFalse(EventLifecycle.canDownload(e, clock: FixedClock(end + 15 * day + 1), config: config))
    }

    // MARK: Validation

    func testValidateDatesRejectsEndBeforeStart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: now,
            endsAt: now - day,
            now: now,
            config: config
        )) { error in
            XCTAssertEqual(error as? AppError, .invalidEventDates)
        }
    }

    func testValidateDatesRejectsOverlongEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = now - 7 * day
        let tooLong = start + TimeInterval(EventLifecycle.mvpMaximumDurationDays + 1) * day
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: tooLong,
            now: now,
            config: config
        )) { error in
            XCTAssertEqual(error as? AppError, .eventDurationTooLong(maxDays: EventLifecycle.mvpMaximumDurationDays))
        }
    }

    func testValidateDatesAcceptsInRange() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = now - 2 * day
        let end = now + 3 * day
        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config
        ))
    }

    func testValidateDatesRejectsStartMoreThan15DaysAgo() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = now - 16 * day
        let end = now - 14 * day
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config
        )) { error in
            XCTAssertEqual(error as? AppError, .eventDatesOutsideAllowedWindow(days: 15))
        }
    }

    func testValidateDatesRejectsEndMoreThan15DaysAhead() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = now + 10 * day
        let end = now + 16 * day
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config
        )) { error in
            XCTAssertEqual(error as? AppError, .eventDatesOutsideAllowedWindow(days: 15))
        }
    }

    func testDefaultEndDateNeverExceeds15Days() {
        var longConfig = config
        longConfig.defaultEventDurationDays = 30
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = EventLifecycle.defaultEndDate(from: start, config: longConfig)
        XCTAssertEqual(end.timeIntervalSince(start), 15 * day, accuracy: 0.5)
    }
}
