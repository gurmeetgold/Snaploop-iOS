import Foundation

public enum EventLifecycle {
    public static let mvpMaximumDurationDays = 15
    public static let mvpDateWindowDays = 15
    public static let photoWindowVersion = Event.canonicalPhotoWindowVersion

    public enum Status: String, Equatable, Sendable {
        case upcoming
        case active
        case grace
        case expired
    }

    /// Product date semantics are Gregorian civil days in an explicit timezone.
    /// This avoids elapsed-second/DST drift and keeps server/client calculations
    /// mirrorable. Callers editing a canonical Event should pass the Event's
    /// persisted photo-window timezone rather than the device's new timezone.
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func graceEnd(
        for event: Event,
        config: RemoteConfigValues,
        calendar explicitCalendar: Calendar? = nil
    ) -> Date {
        let days = max(0, config.eventGracePeriodDays)
        let calendar = explicitCalendar ?? event.photoWindowCalendar
        let eventEnd = event.dateRange.upperBound
        return calendar.date(byAdding: .day, value: days, to: eventEnd)
            ?? eventEnd.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public static func status(for event: Event, clock: Clock, config: RemoteConfigValues) -> Status {
        guard event.status == .active else { return .expired }
        let now = clock.now()
        let range = event.dateRange
        if now < range.lowerBound { return .upcoming }
        if now <= range.upperBound { return .active }
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
        let dayAfterUpper = calendar.date(byAdding: .day, value: 1, to: upperDay)
            ?? upperDay.addingTimeInterval(86_400)
        return lower...dayAfterUpper.addingTimeInterval(-0.001)
    }

    public static func maximumEndDate(
        from startsAt: Date,
        config: RemoteConfigValues,
        calendar: Calendar = .current
    ) -> Date {
        let days = min(mvpMaximumDurationDays, max(1, config.maxEventDurationDays))
        let startDay = calendar.startOfDay(for: startsAt)
        return calendar.date(byAdding: .day, value: days, to: startDay)
            ?? startDay.addingTimeInterval(TimeInterval(days) * 86_400)
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

        let today = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: startsAt)
        let endDay = calendar.startOfDay(for: endsAt)
        let lower = calendar.date(byAdding: .day, value: -mvpDateWindowDays, to: today) ?? today
        let upper = calendar.date(byAdding: .day, value: mvpDateWindowDays, to: today) ?? today

        guard startDay >= lower, startDay <= upper, endDay >= lower, endDay <= upper else {
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
        let startDay = calendar.startOfDay(for: startsAt)
        let endDay = calendar.startOfDay(for: endsAt)
        guard endDay >= startDay else { throw AppError.invalidEventDates }

        let maxDays = min(mvpMaximumDurationDays, max(1, config.maxEventDurationDays))
        let dayDistance = calendar.dateComponents([.day], from: startDay, to: endDay).day
        guard let dayDistance, dayDistance >= 0 else { throw AppError.invalidEventDates }
        if dayDistance > maxDays {
            throw AppError.eventDurationTooLong(maxDays: maxDays)
        }
    }

    /// Converts user-selected civil dates into one authoritative inclusive photo
    /// window. The last selected date ends at 23:59:59.999 in the chosen Event
    /// timezone; PhotoKit and backend publish validation then use the same bounds.
    public static func canonicalBounds(
        startsAt: Date,
        endsAt: Date,
        calendar: Calendar
    ) -> ClosedRange<Date> {
        let lower = calendar.startOfDay(for: startsAt)
        let endDay = calendar.startOfDay(for: endsAt)
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
            ?? endDay.addingTimeInterval(86_400)
        let upper = dayAfterEnd.addingTimeInterval(-0.001)
        return lower...max(lower, upper)
    }

    /// Civil-day ordinal mirrored by functions/eventDateSemantics.js. It is
    /// deliberately based on Y/M/D components rather than elapsed local seconds,
    /// so DST changes cannot alter a day identity.
    public static func localDayNumber(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnightUTC = utc.date(from: components) else {
            return Int(floor(date.timeIntervalSince1970 / 86_400))
        }
        return Int(floor(midnightUTC.timeIntervalSince1970 / 86_400))
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
