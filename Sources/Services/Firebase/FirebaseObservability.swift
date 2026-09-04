import Foundation
import FirebaseCrashlytics
import FirebasePerformance

/// Firebase observability controls that are safe to call repeatedly as Remote
/// Config changes. Product analytics remains owned by `AnalyticsService`.
enum FirebaseObservability {
    static func apply(_ values: RemoteConfigValues) {
        let performance = Performance.sharedInstance()
        performance.isInstrumentationEnabled = values.performanceMonitoringEnabled
        performance.isDataCollectionEnabled = values.performanceMonitoringEnabled

        // These are coarse operational flags only; they contain no user/event/
        // photo identifiers and help interpret crash reports during rollouts.
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCustomValue(values.analyticsEnabled, forKey: "analytics_enabled")
        crashlytics.setCustomValue(values.performanceMonitoringEnabled, forKey: "performance_monitoring_enabled")
        crashlytics.setCustomValue(false, forKey: "session_replay_active")
    }

    /// Record a sanitized non-fatal diagnostic. Callers provide a stable code,
    /// not raw localized error text, URLs, paths, tokens, identifiers or payloads.
    static func recordNonFatal(code: String, context: [String: AnalyticsValue] = [:]) {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else { return }

        let crashlytics = Crashlytics.crashlytics()
        for (key, value) in context {
            crashlytics.setCustomValue(value.crashlyticsValue, forKey: key)
        }

        let error = NSError(
            domain: "com.gurmeetchhiber.snaploop.observability",
            code: stableCode(for: normalizedCode),
            userInfo: ["diagnostic_code": normalizedCode]
        )
        crashlytics.record(error: error)
    }

    private static func stableCode(for value: String) -> Int {
        // Deterministic, non-cryptographic code so the same diagnostic groups
        // consistently without including any sensitive runtime material.
        value.utf8.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1) }
    }
}

private extension AnalyticsValue {
    var crashlyticsValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        }
    }
}
