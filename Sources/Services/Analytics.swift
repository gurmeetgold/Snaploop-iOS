import Foundation

/// A value that may appear in an analytics parameter. Deliberately a closed
/// set of harmless scalars so image data, embeddings and arbitrary objects
/// cannot enter the analytics contract.
public enum AnalyticsValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

public enum AnalyticsScanSource: String, Sendable {
    case manual
    case automatic
}

public enum AnalyticsScanFailureReason: String, Sendable {
    case sharingDisabled = "sharing_disabled"
    case retryableWork = "retryable_work"
    case appError = "app_error"
    case unexpected
}

public enum AnalyticsScanInterruptionReason: String, Sendable {
    case backgrounded
    case userStopped = "user_stopped"
    case memoryPressure = "memory_pressure"
    case systemCancellation = "system_cancellation"
}

public enum AnalyticsInvitationSource: String, Sendable {
    case token
    case code
    case unknown
}

public enum AnalyticsPhotoPermissionState: String, Sendable {
    case authorized
    case limited
    case denied
    case notDetermined = "not_determined"
}

public enum AnalyticsMatchedPhotosGalleryScope: String, Sendable {
    case event
    case allEvents = "all_events"
}

public enum AnalyticsPhotoSaveFailureReason: String, Sendable {
    case permissionDenied = "permission_denied"
    case unavailable
}

public struct AnalyticsEvent: Equatable, Sendable {
    public let name: String
    public let parameters: [String: AnalyticsValue]

    private init(_ name: String, _ parameters: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.parameters = parameters
    }

    public static func installOpened() -> Self { .init("install_opened") }
    public static func inviteLinkOpened(eventId: String) -> Self {
        .init("invite_link_opened", ["event_id": .string(eventId)])
    }
    public static func eventCreated(eventId: String, category: EventCategory) -> Self {
        .init("event_created", ["event_id": .string(eventId), "category": .string(category.rawValue)])
    }
    public static func inviteSent(eventId: String, channel: String) -> Self {
        .init("invite_sent", ["event_id": .string(eventId), "channel": .string(channel)])
    }
    public static func invitationOpened(source: AnalyticsInvitationSource) -> Self {
        .init("invitation_opened", ["source": .string(source.rawValue)])
    }
    public static func invitationAccepted(source: AnalyticsInvitationSource) -> Self {
        .init("invitation_accepted", ["source": .string(source.rawValue)])
    }
    public static func invitationDeclined(source: AnalyticsInvitationSource) -> Self {
        .init("invitation_declined", ["source": .string(source.rawValue)])
    }
    public static func eventJoined(source: AnalyticsInvitationSource) -> Self {
        .init("event_joined", ["source": .string(source.rawValue)])
    }

    public static func phoneVerificationStarted() -> Self { .init("phone_verification_started") }
    public static func phoneVerificationSucceeded() -> Self { .init("phone_verification_succeeded") }
    public static func phoneVerificationFailed() -> Self { .init("phone_verification_failed") }
    public static func signupCompleted() -> Self { .init("signup_completed") }
    public static func loginSucceeded() -> Self { .init("login_succeeded") }
    public static func selfieCompleted() -> Self { .init("selfie_completed") }
    public static func faceSetupStarted() -> Self { .init("face_setup_started") }
    public static func faceSetupCompleted(wasUpdate: Bool) -> Self {
        .init("face_setup_completed", ["was_update": .bool(wasUpdate)])
    }
    public static func faceSetupFailed() -> Self { .init("face_setup_failed") }
    public static func permissionGranted(kind: String, granted: Bool) -> Self {
        .init("permission_result", ["kind": .string(kind), "granted": .bool(granted)])
    }
    public static func photoPermissionRequested() -> Self { .init("photo_permission_requested") }
    public static func photoPermissionResult(state: AnalyticsPhotoPermissionState) -> Self {
        .init("photo_permission_result", ["state": .string(state.rawValue)])
    }

    public static func matchedPhotosGalleryViewed(scope: AnalyticsMatchedPhotosGalleryScope, photoCount: Int) -> Self {
        .init("matched_photos_gallery_viewed", [
            "scope": .string(scope.rawValue),
            "photo_count": .int(max(0, photoCount)),
        ])
    }
    public static func matchedPhotosDetailOpened(galleryCount: Int) -> Self {
        .init("matched_photos_detail_opened", ["gallery_count": .int(max(0, galleryCount))])
    }
    public static func matchedPhotosSaved(count: Int) -> Self {
        .init("matched_photos_saved", ["count": .int(max(0, count))])
    }
    public static func matchedPhotosSaveFailed(count: Int, reason: AnalyticsPhotoSaveFailureReason) -> Self {
        .init("matched_photos_save_failed", ["count": .int(max(0, count)), "reason": .string(reason.rawValue)])
    }
    public static func matchedPhotosShareOpened(count: Int) -> Self {
        .init("matched_photos_share_opened", ["count": .int(max(0, count))])
    }
    public static func matchedPhotosShared(count: Int) -> Self {
        .init("matched_photos_shared", ["count": .int(max(0, count))])
    }
    public static func matchedPhotosShareCancelled(count: Int) -> Self {
        .init("matched_photos_share_cancelled", ["count": .int(max(0, count))])
    }
    public static func matchedPhotosShareFailed(count: Int) -> Self {
        .init("matched_photos_share_failed", ["count": .int(max(0, count))])
    }
    public static func matchedPhotosFavoriteChanged(favorited: Bool, count: Int) -> Self {
        .init("matched_photos_favorite_changed", ["favorited": .bool(favorited), "count": .int(max(0, count))])
    }
    public static func matchedPhotoNotMeResult(succeeded: Bool) -> Self {
        .init("matched_photo_not_me_result", ["succeeded": .bool(succeeded)])
    }

    public static func joinConversion(eventId: String) -> Self {
        .init("join_conversion", ["event_id": .string(eventId)])
    }
    public static func firstSyncCompleted(eventId: String, matched: Int) -> Self {
        .init("first_sync_completed", ["event_id": .string(eventId), "matched": .int(max(0, matched))])
    }
    public static func photoDiscovered(eventId: String, firstForUserInEvent: Bool) -> Self {
        .init("photo_discovered", [
            "event_id": .string(eventId),
            "first_for_user_in_event": .bool(firstForUserInEvent),
        ])
    }
    public static func eventParticipation(ordinal: Int) -> Self {
        .init("event_participation", ["ordinal": .int(max(1, ordinal))])
    }

    public static func scanStarted(source: AnalyticsScanSource) -> Self {
        .init("scan_started", ["source": .string(source.rawValue)])
    }
    public static func scanBackgrounded() -> Self { .init("scan_backgrounded") }
    public static func scanResumeAttempted() -> Self { .init("scan_resume_attempted") }
    public static func scanResumeSucceeded() -> Self { .init("scan_resume_succeeded") }
    public static func scanInterrupted(reason: AnalyticsScanInterruptionReason) -> Self {
        .init("scan_interrupted", ["reason": .string(reason.rawValue)])
    }
    public static func scanRetryStarted(source: AnalyticsScanSource) -> Self {
        .init("scan_retry_started", ["source": .string(source.rawValue)])
    }
    public static func scanCompleted(
        source: AnalyticsScanSource,
        scanned: Int,
        matchedPhotos: Int,
        remaining: Int,
        alreadyCaughtUp: Bool
    ) -> Self {
        .init("scan_completed", [
            "source": .string(source.rawValue),
            "scanned": .int(max(0, scanned)),
            "matched_photos": .int(max(0, matchedPhotos)),
            "remaining": .int(max(0, remaining)),
            "already_caught_up": .bool(alreadyCaughtUp),
        ])
    }
    public static func zeroMatchScanCompleted(source: AnalyticsScanSource, scanned: Int) -> Self {
        .init("zero_match_scan_completed", ["source": .string(source.rawValue), "scanned": .int(max(0, scanned))])
    }
    public static func scanFailed(source: AnalyticsScanSource, reason: AnalyticsScanFailureReason) -> Self {
        .init("scan_failed", ["source": .string(source.rawValue), "reason": .string(reason.rawValue)])
    }

    /// Strict production egress allow-list. Event IDs may exist transiently for
    /// local funnel calculations/tests but are never transmitted to vendors.
    var productionParameters: [String: AnalyticsValue] {
        let allowedKeys: Set<String>
        switch name {
        case "event_created": allowedKeys = ["category"]
        case "invite_sent": allowedKeys = ["channel"]
        case "invitation_opened", "invitation_accepted", "invitation_declined", "event_joined": allowedKeys = ["source"]
        case "face_setup_completed": allowedKeys = ["was_update"]
        case "photo_permission_result": allowedKeys = ["state"]
        case "matched_photos_gallery_viewed": allowedKeys = ["scope", "photo_count"]
        case "matched_photos_detail_opened": allowedKeys = ["gallery_count"]
        case "matched_photos_saved", "matched_photos_share_opened", "matched_photos_shared", "matched_photos_share_cancelled", "matched_photos_share_failed": allowedKeys = ["count"]
        case "matched_photos_save_failed": allowedKeys = ["count", "reason"]
        case "matched_photos_favorite_changed": allowedKeys = ["favorited", "count"]
        case "matched_photo_not_me_result": allowedKeys = ["succeeded"]
        case "permission_result": allowedKeys = ["granted"]
        case "first_sync_completed": allowedKeys = ["matched"]
        case "photo_discovered": allowedKeys = ["first_for_user_in_event"]
        case "event_participation": allowedKeys = ["ordinal"]
        case "scan_started", "scan_retry_started": allowedKeys = ["source"]
        case "scan_interrupted": allowedKeys = ["reason"]
        case "scan_completed": allowedKeys = ["source", "scanned", "matched_photos", "remaining", "already_caught_up"]
        case "scan_failed": allowedKeys = ["source", "reason"]
        case "zero_match_scan_completed": allowedKeys = ["source", "scanned"]
        default: allowedKeys = []
        }
        return parameters.filter { allowedKeys.contains($0.key) }
    }
}

public protocol AnalyticsService: Sendable {
    func log(_ event: AnalyticsEvent)
    func identify(userId: String)
    func reset()
    func setCollectionEnabled(_ enabled: Bool)
}

public extension AnalyticsService {
    func identify(userId: String) {}
    func reset() {}
    func setCollectionEnabled(_ enabled: Bool) {}
}

public struct NoopAnalytics: AnalyticsService {
    public init() {}
    public func log(_ event: AnalyticsEvent) {}
}

public final class CompositeAnalytics: AnalyticsService, @unchecked Sendable {
    private let sinks: [AnalyticsService]
    public init(_ sinks: [AnalyticsService]) { self.sinks = sinks }
    public func log(_ event: AnalyticsEvent) { sinks.forEach { $0.log(event) } }
    public func identify(userId: String) { sinks.forEach { $0.identify(userId: userId) } }
    public func reset() { sinks.forEach { $0.reset() } }
    public func setCollectionEnabled(_ enabled: Bool) { sinks.forEach { $0.setCollectionEnabled(enabled) } }
}

public final class InMemoryAnalytics: AnalyticsService, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [AnalyticsEvent] = []
    private var storedIdentifiedUserId: String?
    private var storedCollectionEnabled = true

    public init() {}

    public var events: [AnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }
    public var identifiedUserId: String? {
        lock.lock(); defer { lock.unlock() }
        return storedIdentifiedUserId
    }
    public var isCollectionEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedCollectionEnabled
    }
    public func log(_ event: AnalyticsEvent) {
        lock.lock(); defer { lock.unlock() }
        guard storedCollectionEnabled else { return }
        storedEvents.append(event)
    }
    public func identify(userId: String) {
        lock.lock(); defer { lock.unlock() }
        guard storedCollectionEnabled else { return }
        storedIdentifiedUserId = userId
    }
    public func reset() {
        lock.lock(); storedIdentifiedUserId = nil; lock.unlock()
    }
    public func setCollectionEnabled(_ enabled: Bool) {
        lock.lock(); storedCollectionEnabled = enabled; lock.unlock()
    }
    public func names() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.map(\.name)
    }
}
