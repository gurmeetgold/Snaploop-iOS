import Foundation

public enum EventLifecycle {
    public static let mvpMaximumDurationDays = 15
    public static let mvpDateWindowDays = 15

    public enum Status: String, Equatable, Sendable {
        case upcoming
        case active
        case grace
        case expired
    }

    public static func graceEnd(
        for event: Event,
        config: RemoteConfigValues,
        calendar: Calendar = .current
    ) -> Date {
        let days = max(0, config.eventGracePeriodDays)
        return calendar.date(byAdding: .day, value: days, to: event.endsAt)
            ?? event.endsAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public static func status(for event: Event, clock: Clock, config: RemoteConfigValues) -> Status {
        guard event.status == .active else { return .expired }
        let now = clock.now()
        if now < event.startsAt { return .upcoming }
        if now <= event.endsAt { return .active }
        if now <= graceEnd(for: event, config: config) { return .grace }
        return .expired
    }

    public static func canSync(_ event: Event, clock: Clock, config: RemoteConfigValues) -> Bool {
        guard event.status == .active else { return false }
        switch status(for: event, clock: clock, config: config) {
        case .active, .grace: return true
        case .upcoming, .expired: return false
        }
    }

    public static func canDownload(_ event: Event, clock: Clock, config: RemoteConfigValues) -> Bool {
        event.status == .active && clock.now() <= graceEnd(for: event, config: config)
    }

    public static func allowedDateRange(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let lower = calendar.date(byAdding: .day, value: -mvpDateWindowDays, to: today) ?? today
        let upperDay = calendar.date(byAdding: .day, value: mvpDateWindowDays, to: today) ?? today
        let dayAfterUpper = calendar.date(byAdding: .day, value: 1, to: upperDay) ?? upperDay.addingTimeInterval(86_400)
        return lower...dayAfterUpper.addingTimeInterval(-1)
    }

    public static func maximumEndDate(
        from startsAt: Date,
        config: RemoteConfigValues,
        calendar: Calendar = .current
    ) -> Date {
        let days = min(mvpMaximumDurationDays, max(1, config.maxEventDurationDays))
        return calendar.date(byAdding: .day, value: days, to: startsAt)
            ?? startsAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public static func validateDates(
        startsAt: Date,
        endsAt: Date,
        now: Date,
        config: RemoteConfigValues,
        calendar: Calendar = .current
    ) throws {
        try validateDuration(
            startsAt: startsAt,
            endsAt: endsAt,
            config: config,
            calendar: calendar
        )
        let allowed = allowedDateRange(now: now, calendar: calendar)
        guard allowed.contains(startsAt), allowed.contains(endsAt) else {
            throw AppError.eventDatesOutsideAllowedWindow(days: mvpDateWindowDays)
        }
    }

    /// Compatibility overload used by older pure unit tests/call sites that do
    /// not inject a current date. Production Create/Edit flows use the overload
    /// above with their injectable clock and therefore enforce both constraints.
    public static func validateDates(
        startsAt: Date,
        endsAt: Date,
        config: RemoteConfigValues,
        calendar: Calendar = .current
    ) throws {
        try validateDuration(
            startsAt: startsAt,
            endsAt: endsAt,
            config: config,
            calendar: calendar
        )
    }

    private static func validateDuration(
        startsAt: Date,
        endsAt: Date,
        config: RemoteConfigValues,
        calendar: Calendar
    ) throws {
        guard endsAt > startsAt else { throw AppError.invalidEventDates }
        let maxDays = min(mvpMaximumDurationDays, max(1, config.maxEventDurationDays))
        let maximumEnd = calendar.date(byAdding: .day, value: maxDays, to: startsAt)
            ?? startsAt.addingTimeInterval(TimeInterval(maxDays) * 86_400)
        if endsAt > maximumEnd {
            throw AppError.eventDurationTooLong(maxDays: maxDays)
        }
    }

    public static func defaultEndDate(
        from startsAt: Date,
        config: RemoteConfigValues,
        calendar: Calendar = .current
    ) -> Date {
        let days = min(mvpMaximumDurationDays, max(1, config.defaultEventDurationDays))
        return calendar.date(byAdding: .day, value: days, to: startsAt)
            ?? startsAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}
