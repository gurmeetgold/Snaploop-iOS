import Foundation
import PostHog

/// Production product-analytics sink. SnapLoop captures only explicitly defined
/// events from `AnalyticsEvent`; PostHog autocapture, screen capture, push hooks,
/// feature-flag events and Session Replay remain disabled in v1.
public final class PostHogAnalyticsService: AnalyticsService, @unchecked Sendable {
    private let isEnabled: () -> Bool

    public init(
        projectToken: String,
        host: String,
        isEnabled: @escaping () -> Bool
    ) {
        self.isEnabled = isEnabled
        PostHogBootstrap.configureIfNeeded(projectToken: projectToken, host: host)
        registerPrivacyDefaults()
    }

    /// Prevent PostHog from using the request IP to enrich events with
    /// city, postal code, coordinates, region or other GeoIP properties.
    /// This is separate from PostHog's server-side "discard client IP"
    /// setting, which discards the raw IP only after enrichment.
    private func registerPrivacyDefaults() {
        PostHogSDK.shared.register(["$geoip_disable": true])
    }

    public func log(_ event: AnalyticsEvent) {
        guard isEnabled() else { return }
        PostHogSDK.shared.capture(
            event.name,
            properties: event.productionParameters.mapValues { $0.postHogValue }
        )
    }

    public func identify(userId: String) {
        guard isEnabled() else { return }
        let normalized = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        PostHogSDK.shared.identify(normalized)
    }

    /// Always reset identity, even while collection is disabled, so one account
    /// can never inherit another account's local PostHog identity on this device.
    public func reset() {
        PostHogSDK.shared.reset()

        // reset() clears registered PostHog properties, so restore the
        // privacy guard before the next account/session emits events.
        registerPrivacyDefaults()
    }

    /// Remote Config kill switch. PostHog persists this state, so an emergency
    /// disable continues to suppress capture until SnapLoop explicitly enables
    /// collection again from the current/cached Remote Config policy.
    public func setCollectionEnabled(_ enabled: Bool) {
        if enabled {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
    }

    /// Release builds receive the client-side PostHog project token through the
    /// generated Info.plist. Debug intentionally has an empty token so unit/local
    /// debug work cannot pollute production analytics.
    public static func fromBundle(
        _ bundle: Bundle = .main,
        isEnabled: @escaping () -> Bool
    ) -> AnalyticsService {
        let token = (bundle.object(forInfoDictionaryKey: "SnapLoopPostHogProjectToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return NoopAnalytics() }

        let configuredHost = (bundle.object(forInfoDictionaryKey: "SnapLoopPostHogHost") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = configuredHost.isEmpty ? "https://us.i.posthog.com" : configuredHost

        return PostHogAnalyticsService(
            projectToken: token,
            host: host,
            isEnabled: isEnabled
        )
    }
}

private enum PostHogBootstrap {
    private static let lock = NSLock()
    private static var didConfigure = false

    static func configureIfNeeded(projectToken: String, host: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !didConfigure else { return }

        let config = PostHogConfig(projectToken: projectToken, host: host)

        // V1 is intentionally explicit-only and privacy-minimized.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.sessionReplay = false
        config.enableSwizzling = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.sendFeatureFlagEvent = false
        config.preloadFeatureFlags = false
        config.personProfiles = .identifiedOnly
        config.debug = false

        PostHogSDK.shared.setup(config)
        didConfigure = true
    }
}

private extension AnalyticsValue {
    var postHogValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        }
    }
}
