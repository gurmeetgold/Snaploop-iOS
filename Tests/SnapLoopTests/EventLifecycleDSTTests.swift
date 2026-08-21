import Foundation
import XCTest
@testable import SnapLoop

final class EventLifecycleDSTTests: XCTestCase {
    private var config = RemoteConfigValues.default

    func testMaximumDurationAcceptsFifteenCalendarDaysAcrossSpringDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!

        let start = calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 1, hour: 12
        ))!
        let end = calendar.date(byAdding: .day, value: 15, to: start)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 10, hour: 12
        ))!

        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config,
            calendar: calendar
        ))
    }

    func testMaximumDurationAcceptsFifteenCalendarDaysAcrossFallDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!

        let start = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 25, hour: 12
        ))!
        let end = calendar.date(byAdding: .day, value: 15, to: start)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 1, hour: 12
        ))!

        XCTAssertNoThrow(try EventLifecycle.validateDates(
            startsAt: start,
            endsAt: end,
            now: now,
            config: config,
            calendar: calendar
        ))
    }

    func testMaximumDurationRejectsAnythingPastFifteenCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!

        let start = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 25, hour: 12
        ))!
        let maximum = calendar.date(byAdding: .day, value: 15, to: start)!
        let end = maximum.addingTimeInterval(1)
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 1, hour: 12
        ))!

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

    func testDefaultEndDatePreservesLocalClockAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
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
