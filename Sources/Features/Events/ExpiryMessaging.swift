import Foundation

/// Human, *specific* copy about where an event is in its life and what expiry
/// actually means — deliberately concrete ("Originals available until [date]")
/// instead of vague "your memories will vanish" anxiety.
public enum ExpiryMessaging {

    public struct Message: Equatable, Sendable {
        public let headline: String
        public let detail: String
    }

    public static func message(
        for event: Event,
        clock: Clock,
        config: RemoteConfigValues
    ) -> Message {
        let status = EventLifecycle.status(for: event, clock: clock, config: config)
        let graceEnd = EventLifecycle.graceEnd(for: event, config: config)
        let timeZone = event.photoWindowTimeZone

        switch status {
        case .upcoming:
            return Message(
                headline: "Starts \(DateFormatting.longDate(event.startsAt, timeZone: timeZone))",
                detail: "Once it begins, sync your camera to start finding your photos.")
        case .active:
            return Message(
                headline: "Happening now",
                detail: "Live until \(DateFormatting.longDate(event.endsAt, timeZone: timeZone)). Sync anytime to catch new photos of you.")
        case .grace:
            return Message(
                headline: "This event has wrapped up",
                detail: "You can still sync and download originals until \(DateFormatting.longDate(graceEnd, timeZone: timeZone)). After that, only thumbnails remain — so save anything you want to keep.")
        case .expired:
            return Message(
                headline: "This event has ended",
                detail: "Photos you already saved are yours to keep. Originals are no longer available to download.")
        }
    }
}
