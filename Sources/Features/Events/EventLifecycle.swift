import Foundation

/// Pure event-lifecycle logic. Persisted organizer actions always override the
/// date-derived phase, so the UI and server cannot disagree about an ended or
/// deleted event.
public enum EventLifecycle {
    public enum Status: String, Equatable, Sendable {
        case upcoming
        case active
        case grace
        case expired
    }

    public static func graceEnd(for event: Event, config: RemoteConfigValues) -> Date {
        let days = max(0, config.eventGracePeriodDays)
        return event.endsAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public static func status(
        for event: Event,
        clock: Clock,
        config: RemoteConfigValues
    ) -> Status {
        // Explicit organizer/server lifecycle state wins over the calendar.
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

    public static func validateDates(
        startsAt: Date,
        endsAt: Date,
        config: RemoteConfigValues
    ) throws {
        guard endsAt > startsAt else { throw AppError.invalidEventDates }
        let maxSeconds = TimeInterval(max(1, config.maxEventDurationDays)) * 86_400
        if endsAt.timeIntervalSince(startsAt) > maxSeconds {
            throw AppError.eventDurationTooLong(maxDays: config.maxEventDurationDays)
        }
    }

    public static func defaultEndDate(from startsAt: Date, config: RemoteConfigValues) -> Date {
        startsAt.addingTimeInterval(TimeInterval(max(1, config.defaultEventDurationDays)) * 86_400)
    }
}
