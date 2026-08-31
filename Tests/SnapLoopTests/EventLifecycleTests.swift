import XCTest
@testable import SnapLoop

final class EventLifecycleTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var config = RemoteConfigValues.default
    private var utcCalendar: Calendar {
        EventLifecycle.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func event(startDay: Date, endDay: Date) -> Event {
        let bounds = EventLifecycle.canonicalBounds(
            startsAt: startDay,
            endsAt: endDay,
            calendar: utcCalendar
        )
        return Event(
            id: "e",
            joinCode: "ABC234",
            creatorUserId: "u",
            name: "Party",
            startsAt: bounds.lowerBound,
            endsAt: bounds.upperBound,
            photoWindowVersion: Event.canonicalPhotoWindowVersion,
            photoWindowTimeZoneId: "GMT",
            photoWindowStartDayNumber: EventLifecycle.localDayNumber(startDay, calendar: utcCalendar),
            photoWindowEndDayNumber: EventLifecycle.localDayNumber(endDay, calendar: utcCalendar),
            createdAt: bounds.lowerBound
        )
    }

    func testUpcomingBeforeCanonicalStartBoundary() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 15))
        XCTAssertEqual(
            EventLifecycle.status(for: e, clock: FixedClock(e.dateRange.lowerBound.addingTimeInterval(-0.001)), config: config),
            .upcoming
        )
    }

    func testActiveWithinCanonicalWindowInclusiveOfBoundaries() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 15))
        XCTAssertEqual(EventLifecycle.status(for: e, clock: FixedClock(e.dateRange.lowerBound), config: config), .active)
        XCTAssertEqual(EventLifecycle.status(for: e, clock: FixedClock(date(2026, 8, 12)), config: config), .active)
        XCTAssertEqual(EventLifecycle.status(for: e, clock: FixedClock(e.dateRange.upperBound), config: config), .active)
    }

    func testGraceWindowStartsAfterLastMillisecondOfSelectedEndDate() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 15))
        XCTAssertEqual(
            EventLifecycle.status(for: e, clock: FixedClock(e.dateRange.upperBound.addingTimeInterval(0.001)), config: config),
            .grace
        )
    }

    func testGraceEndBoundaryIsInclusive() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 15))
        let graceEnd = EventLifecycle.graceEnd(for: e, config: config)
        XCTAssertEqual(EventLifecycle.status(for: e, clock: FixedClock(graceEnd), config: config), .grace)
        XCTAssertEqual(EventLifecycle.status(for: e, clock: FixedClock(graceEnd.addingTimeInterval(0.001)), config: config), .expired)
    }

    func testCanSyncOnlyDuringEventAndGraceWindow() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 15))
        let graceEnd = EventLifecycle.graceEnd(for: e, config: config)
        XCTAssertFalse(EventLifecycle.canSync(e, clock: FixedClock(e.dateRange.lowerBound - 1), config: config))
        XCTAssertTrue(EventLifecycle.canSync(e, clock: FixedClock(date(2026, 8, 12)), config: config))
        XCTAssertTrue(EventLifecycle.canSync(e, clock: FixedClock(graceEnd), config: config))
        XCTAssertFalse(EventLifecycle.canSync(e, clock: FixedClock(graceEnd + 1), config: config))
    }

    func testCanDownloadThroughGraceWindowButNotAfter() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 15))
        let graceEnd = EventLifecycle.graceEnd(for: e, config: config)
        XCTAssertTrue(EventLifecycle.canDownload(e, clock: FixedClock(graceEnd), config: config))
        XCTAssertFalse(EventLifecycle.canDownload(e, clock: FixedClock(graceEnd + 1), config: config))
    }

    // MARK: Validation

    func testValidateDatesAllowsSameCivilDayEvent() {
        let now = date(2026, 8, 10)
        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: date(2026, 8, 10, hour: 8),
            endsAt: date(2026, 8, 10, hour: 20),
            now: now,
            config: config,
            calendar: utcCalendar
        ))
    }

    func testValidateDatesRejectsEndOnPreviousCivilDay() {
        let now = date(2026, 8, 10)
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: date(2026, 8, 10),
            endsAt: date(2026, 8, 9),
            now: now,
            config: config,
            calendar: utcCalendar
        )) { error in
            XCTAssertEqual(error as? AppError, .invalidEventDates)
        }
    }

    func testValidateDatesRejectsSixteenDayDistance() {
        let now = date(2026, 8, 10)
        let start = date(2026, 8, 1)
        let tooLong = utcCalendar.date(byAdding: .day, value: 16, to: start)!
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: tooLong,
            now: now,
            config: config,
            calendar: utcCalendar
        )) { error in
            XCTAssertEqual(error as? AppError, .eventDurationTooLong(maxDays: EventLifecycle.mvpMaximumDurationDays))
        }
    }

    func testPlusMinusFifteenDayBoundaryIsInclusive() {
        let now = date(2026, 8, 16)
        let lower = utcCalendar.date(byAdding: .day, value: -15, to: now)!
        let upper = utcCalendar.date(byAdding: .day, value: 15, to: now)!

        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: lower,
            endsAt: now,
            now: now,
            config: config,
            calendar: utcCalendar
        ))
        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: now,
            endsAt: upper,
            now: now,
            config: config,
            calendar: utcCalendar
        ))
    }

    func testValidateDatesRejectsSixteenDaysBeforeToday() {
        let now = date(2026, 8, 16)
        let start = utcCalendar.date(byAdding: .day, value: -16, to: now)!
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: now,
            now: now,
            config: config,
            calendar: utcCalendar
        )) { error in
            XCTAssertEqual(error as? AppError, .eventDatesOutsideAllowedWindow(days: 15))
        }
    }

    func testValidateDatesRejectsSixteenDaysAfterToday() {
        let now = date(2026, 8, 16)
        let end = utcCalendar.date(byAdding: .day, value: 16, to: now)!
        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: now,
            endsAt: end,
            now: now,
            config: config,
            calendar: utcCalendar
        )) { error in
            XCTAssertEqual(error as? AppError, .eventDurationTooLong(maxDays: 15))
        }
    }

    func testCanonicalEventDateRangeIsAlreadyThePersistedAbsoluteWindow() {
        let e = event(startDay: date(2026, 8, 10), endDay: date(2026, 8, 12))
        XCTAssertTrue(e.usesCanonicalPhotoWindow)
        XCTAssertEqual(e.dateRange.lowerBound, e.startsAt)
        XCTAssertEqual(e.dateRange.upperBound, e.endsAt)
        XCTAssertEqual(e.photoWindowCalendar.timeZone.identifier, "GMT")
    }

    func testDefaultEndDateNeverExceedsFifteenDayDistance() {
        var longConfig = config
        longConfig.defaultEventDurationDays = 30
        let start = date(2026, 8, 1)
        let end = EventLifecycle.defaultEndDate(from: start, config: longConfig, calendar: utcCalendar)
        XCTAssertEqual(
            utcCalendar.dateComponents([.day], from: start, to: end).day,
            EventLifecycle.mvpMaximumDurationDays
        )
    }
}
