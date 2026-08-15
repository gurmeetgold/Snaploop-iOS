import Foundation

/// A running tally of new matches for one (event, user) pair, awaiting a
/// batched push. Accumulated server-side (Cloud Function) as matches land.
public struct MatchNotificationBatch: Equatable, Sendable {
    public let eventId: String
    public let eventName: String
    public let userId: String
    public var newPhotoCount: Int
    public var firstMatchAt: Date
    public var lastMatchAt: Date

    public init(eventId: String, eventName: String, userId: String,
                newPhotoCount: Int, firstMatchAt: Date, lastMatchAt: Date) {
        self.eventId = eventId
        self.eventName = eventName
        self.userId = userId
        self.newPhotoCount = newPhotoCount
        self.firstMatchAt = firstMatchAt
        self.lastMatchAt = lastMatchAt
    }
}

/// Decides *when* to fire a single batched notification instead of one push per
/// photo, and builds its copy. Pure and deterministic (time is passed in).
///
/// Fire rule: send once activity has been quiet for `quietWindow`, OR once
/// `maxWait` has elapsed since the first match (so a steady trickle still
/// notifies eventually). Never fires for an empty batch.
public struct NotificationDebouncer {
    public let quietWindow: TimeInterval   // e.g. 12 min of no new matches
    public let maxWait: TimeInterval       // e.g. cap at 60 min

    public init(quietWindow: TimeInterval = 12 * 60, maxWait: TimeInterval = 60 * 60) {
        self.quietWindow = quietWindow
        self.maxWait = maxWait
    }

    public func shouldSend(_ batch: MatchNotificationBatch, now: Date) -> Bool {
        guard batch.newPhotoCount > 0 else { return false }
        let quietElapsed = now.timeIntervalSince(batch.lastMatchAt) >= quietWindow
        let capReached = now.timeIntervalSince(batch.firstMatchAt) >= maxWait
        return quietElapsed || capReached
    }

    /// The push payload. Deep-links into the event's My Photos, never the
    /// generic home screen.
    public struct Payload: Equatable, Sendable {
        public let title: String
        public let body: String
        public let route: DeepLinkRoute?      // resolved to the event; nil if unknown
        public let deepLinkPath: String       // canonical in-app path
    }

    public func payload(for batch: MatchNotificationBatch, inviteToken: InviteToken?) -> Payload {
        let n = batch.newPhotoCount
        let noun = n == 1 ? "photo" : "photos"
        return Payload(
            title: batch.eventName,
            body: "We found \(n) new \(noun) of you in \(batch.eventName).",
            route: inviteToken.map { .joinEventByToken($0) },
            deepLinkPath: "snaploop://event/\(batch.eventId)/my-photos")
    }
}
