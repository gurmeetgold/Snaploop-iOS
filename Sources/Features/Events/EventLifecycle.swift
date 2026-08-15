import Foundation

/// Pure event-lifecycle logic. Turns an event's dates + the configured grace
/// window into a status and a set of capability gates (can I still sync? can I
/// still download?). Everything time-related takes an injected `Clock` so it's
/// deterministic in tests.
public enum EventLifecycle {

    /// Where an event sits in its life. Ordered from earliest to latest phase.
    public enum Status: String, Equatable, Sendable {
        case upcoming     // before startsAt
        case active       // within [startsAt, endsAt]
        case grace        // after endsAt but within the grace window
        case expired      // past the grace window
    }

    /// The end of the grace window for an event, given config.
    public static func graceEnd(for event: Event, config: RemoteConfigValues) -> Date {
        let days = max(0, config.eventGracePeriodDays)
        return event.endsAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// Current status of an event.
    public static func status(
        for event: Event,
        clock: Clock,
        config: RemoteConfigValues
    ) -> Status {
        let now = clock.now()
        if now < event.startsAt { return .upcoming }
        if now <= event.endsAt { return .active }
        if now <= graceEnd(for: event, config: config) { return .grace }
        return .expired
    }

    /// Whether a device may sync new photos into the event right now.
    /// Allowed while active and during grace (stragglers), never once expired
    /// or before it has started.
    public static func canSync(_ event: Event, clock: Clock, config: RemoteConfigValues) -> Bool {
        switch status(for: event, clock: clock, config: config) {
        case .active, .grace: return true
        case .upcoming, .expired: return false
        }
    }

    /// Whether participants may still download originals/thumbnails. Allowed up
    /// to (and including) the end of the grace window.
    public static func canDownload(_ event: Event, clock: Clock, config: RemoteConfigValues) -> Bool {
        clock.now() <= graceEnd(for: event, config: config)
    }

    // MARK: - Validation (used when creating/editing an event)

    /// Validates a proposed start/end pair against config limits. Throws a typed
    /// `AppError` the UI can translate. Editing name/cover never calls this with
    /// changed dates unless the user actually moved the dates.
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

    /// The default end date for a new event when the creator gives only a start.
    public static func defaultEndDate(from startsAt: Date, config: RemoteConfigValues) -> Date {
        startsAt.addingTimeInterval(TimeInterval(max(1, config.defaultEventDurationDays)) * 86_400)
    }
}
