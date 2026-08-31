import Foundation
import XCTest
@testable import SnapLoop

final class EventLifecycleDSTTests: XCTestCase {
    private var config = RemoteConfigValues.default

    private func torontoCalendar() -> Calendar {
        EventLifecycle.calendar(timeZone: TimeZone(identifier: "America/Toronto")!)
    }

    func testMaximumDurationAcceptsFifteenCalendarDaysAcrossSpringDST() throws {
        let calendar = torontoCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        let end = calendar.date(byAdding: .day, value: 15, to: start)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!

        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config,
            calendar: calendar
        ))
    }

    func testMaximumDurationAcceptsFifteenCalendarDaysAcrossFallDST() throws {
        let calendar = torontoCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let end = calendar.date(byAdding: .day, value: 15, to: start)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!

        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config,
            calendar: calendar
        ))
    }

    func testMaximumDurationRejectsSixteenCalendarDayDistance() throws {
        let calendar = torontoCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let end = calendar.date(byAdding: .day, value: 16, to: start)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!

        XCTAssertThrowsError(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config,
            calendar: calendar
        )) { error in
            XCTAssertEqual(
                error as? AppError,
                .eventDurationTooLong(maxDays: EventLifecycle.mvpMaximumDurationDays)
            )
        }
    }

    func testCanonicalBoundsCoverWholeSelectedDaysAcrossSpringDST() {
        let calendar = torontoCalendar()
        let selectedStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 15, minute: 30))!
        let selectedEnd = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 8))!
        let bounds = EventLifecycle.canonicalBounds(
            startsAt: selectedStart,
            endsAt: selectedEnd,
            calendar: calendar
        )

        let lower = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: bounds.lowerBound)
        let upper = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: bounds.upperBound)

        XCTAssertEqual(lower.year, 2026)
        XCTAssertEqual(lower.month, 3)
        XCTAssertEqual(lower.day, 7)
        XCTAssertEqual(lower.hour, 0)
        XCTAssertEqual(lower.minute, 0)
        XCTAssertEqual(lower.second, 0)

        XCTAssertEqual(upper.year, 2026)
        XCTAssertEqual(upper.month, 3)
        XCTAssertEqual(upper.day, 9)
        XCTAssertEqual(upper.hour, 23)
        XCTAssertEqual(upper.minute, 59)
        XCTAssertEqual(upper.second, 59)
        XCTAssertEqual(bounds.upperBound.timeIntervalSince1970 * 1000, floor(bounds.upperBound.timeIntervalSince1970 * 1000), accuracy: 0.01)
    }

    func testCivilDayNumberIncrementsByOneAcrossSpringDSTEvenThoughElapsedDayIs23Hours() {
        let calendar = torontoCalendar()
        let before = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0))!

        XCTAssertEqual(after.timeIntervalSince(before), 23 * 60 * 60, accuracy: 0.5)
        XCTAssertEqual(
            EventLifecycle.localDayNumber(after, calendar: calendar)
                - EventLifecycle.localDayNumber(before, calendar: calendar),
            1
        )
    }

    func testCivilDayNumberIncrementsByOneAcrossFallDSTEvenThoughElapsedDayIs25Hours() {
        let calendar = torontoCalendar()
        let before = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0))!

        XCTAssertEqual(after.timeIntervalSince(before), 25 * 60 * 60, accuracy: 0.5)
        XCTAssertEqual(
            EventLifecycle.localDayNumber(after, calendar: calendar)
                - EventLifecycle.localDayNumber(before, calendar: calendar),
            1
        )
    }

    func testDefaultEndDatePreservesLocalClockAcrossDST() {
        let calendar = torontoCalendar()
        var localConfig = config
        localConfig.defaultEventDurationDays = 15

        let start = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 25, hour: 12, minute: 30
        ))!
        let end = EventLifecycle.defaultEndDate(
            from: start,
            config: localConfig,
            calendar: calendar
        )
        let parts = calendar.dateComponents([.hour, .minute], from: end)

        XCTAssertEqual(parts.hour, 12)
        XCTAssertEqual(parts.minute, 30)
    }
}
