import Foundation

/// A value that may appear in an analytics parameter. Deliberately a *closed*
/// set of harmless scalars — there is no case that can hold `Data`,
/// `FaceEmbedding`, or arbitrary objects. This makes it structurally impossible
/// to log biometric data: the type system rejects it at the call site.
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

/// A funnel/analytics event: a name plus safe scalar parameters. Constructed
/// only through the factory methods below, so the instrumented funnel is
/// enumerable and auditable in one place.
public struct AnalyticsEvent: Equatable, Sendable {
    public let name: String
    public let parameters: [String: AnalyticsValue]

    private init(_ name: String, _ parameters: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.parameters = parameters
    }

    // MARK: Acquisition / viral loop
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

    // MARK: Signup / onboarding
    public static func signupCompleted() -> Self { .init("signup_completed") }
    public static func selfieCompleted() -> Self { .init("selfie_completed") }
    public static func permissionGranted(kind: String, granted: Bool) -> Self {
        .init("permission_result", ["kind": .string(kind), "granted": .bool(granted)])
    }

    // MARK: Conversion
    public static func joinConversion(eventId: String) -> Self {
        .init("join_conversion", ["event_id": .string(eventId)])
    }
    public static func firstSyncCompleted(eventId: String, matched: Int) -> Self {
        .init("first_sync_completed", ["event_id": .string(eventId), "matched": .int(matched)])
    }

    // MARK: NORTH STAR — did a joined user discover ≥1 new photo of themselves?
    public static func photoDiscovered(eventId: String, firstForUserInEvent: Bool) -> Self {
        .init("photo_discovered", [
            "event_id": .string(eventId),
            "first_for_user_in_event": .bool(firstForUserInEvent),
        ])
    }

    // MARK: Retention (episodic — nth event participation)
    public static func eventParticipation(ordinal: Int) -> Self {
        .init("event_participation", ["ordinal": .int(ordinal)])
    }

    // MARK: Scan lifecycle / value
    public static func scanStarted(source: AnalyticsScanSource) -> Self {
        .init("scan_started", ["source": .string(source.rawValue)])
    }

    public static func scanBackgrounded() -> Self {
        .init("scan_backgrounded")
    }

    public static func scanResumeAttempted() -> Self {
        .init("scan_resume_attempted")
    }

    public static func scanResumeSucceeded() -> Self {
        .init("scan_resume_succeeded")
    }

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

    public static func zeroMatchScanCompleted(
        source: AnalyticsScanSource,
        scanned: Int
    ) -> Self {
        .init("zero_match_scan_completed", [
            "source": .string(source.rawValue),
            "scanned": .int(max(0, scanned)),
        ])
    }

    public static func scanFailed(
        source: AnalyticsScanSource,
        reason: AnalyticsScanFailureReason
    ) -> Self {
        .init("scan_failed", [
            "source": .string(source.rawValue),
            "reason": .string(reason.rawValue),
        ])
    }

    /// Strict production egress policy.
    ///
    /// Older in-memory events intentionally still carry `event_id` so existing
    /// local tests/callers remain compatible, but production analytics must not
    /// transmit Event IDs or any other private identifiers. Unknown future event
    /// properties fail closed here until explicitly reviewed.
    var productionParameters: [String: AnalyticsValue] {
        let allowedKeys: Set<String>

        switch name {
        case "permission_result":
            allowedKeys = ["granted"]
        case "first_sync_completed":
            allowedKeys = ["matched"]
        case "photo_discovered":
            allowedKeys = ["first_for_user_in_event"]
        case "event_participation":
            allowedKeys = ["ordinal"]
        case "scan_started", "scan_retry_started":
            allowedKeys = ["source"]
        case "scan_interrupted":
            allowedKeys = ["reason"]
        case "scan_completed":
            allowedKeys = [
                "source",
                "scanned",
                "matched_photos",
                "remaining",
                "already_caught_up",
            ]
        case "scan_failed":
            allowedKeys = ["source", "reason"]
        case "zero_match_scan_completed":
            allowedKeys = ["source", "scanned"]
        default:
            allowedKeys = []
        }

        return parameters.filter { allowedKeys.contains($0.key) }
    }
}

/// Product analytics abstraction. Production currently uses PostHog; tests and
/// previews use in-memory/no-op sinks. Identity uses only SnapLoop's stable
/// internal user ID — never phone number, email, display name or biometric data.
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

/// Captures events and identity state for assertion in tests.
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
        lock.lock()
        defer { lock.unlock() }
        guard storedCollectionEnabled else { return }
        storedEvents.append(event)
    }

    public func identify(userId: String) {
        lock.lock()
        defer { lock.unlock() }
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
