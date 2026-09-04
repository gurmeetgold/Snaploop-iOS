import Foundation
import FirebaseRemoteConfig

/// Firebase Remote Config backed implementation with safe shipped defaults.
public final class FirebaseRemoteConfigProvider: ConfigProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let remote: RemoteConfig
    private var values: RemoteConfigValues

    public init(remote: RemoteConfig = .remoteConfig()) {
        self.remote = remote
        self.values = .default

        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3600
        #endif
        remote.configSettings = settings
        remote.setDefaults(Self.defaultsDictionary)
        self.values = Self.read(from: remote)
    }

    public var current: RemoteConfigValues {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    public func refresh() async {
        await withCheckedContinuation { continuation in
            remote.fetchAndActivate { [weak self] _, _ in
                guard let self else {
                    continuation.resume()
                    return
                }
                let updated = Self.read(from: self.remote)
                self.lock.lock(); self.values = updated; self.lock.unlock()
                continuation.resume()
            }
        }
    }

    private static var defaultsDictionary: [String: NSObject] {
        let d = RemoteConfigValues.default
        return [
            RemoteConfigValues.Key.matchConfidenceThreshold.rawValue: NSNumber(value: d.matchConfidenceThreshold),
            RemoteConfigValues.Key.matchAmbiguityMargin.rawValue: NSNumber(value: d.matchAmbiguityMargin),
            RemoteConfigValues.Key.minFaceSizeFraction.rawValue: NSNumber(value: d.minFaceSizeFraction),
            RemoteConfigValues.Key.maxAssetsPerSyncBatch.rawValue: NSNumber(value: d.maxAssetsPerSyncBatch),
            RemoteConfigValues.Key.thumbnailMaxPixelSize.rawValue: NSNumber(value: d.thumbnailMaxPixelSize),
            RemoteConfigValues.Key.thumbnailJPEGQuality.rawValue: NSNumber(value: d.thumbnailJPEGQuality),
            RemoteConfigValues.Key.signedURLTTLHours.rawValue: NSNumber(value: d.signedURLTTLHours),
            RemoteConfigValues.Key.defaultEventDurationDays.rawValue: NSNumber(value: d.defaultEventDurationDays),
            RemoteConfigValues.Key.maxEventDurationDays.rawValue: NSNumber(value: d.maxEventDurationDays),
            RemoteConfigValues.Key.eventGracePeriodDays.rawValue: NSNumber(value: d.eventGracePeriodDays),
            RemoteConfigValues.Key.maxParticipantsPerEvent.rawValue: NSNumber(value: d.maxParticipantsPerEvent),
            RemoteConfigValues.Key.aiBestShotEnabled.rawValue: NSNumber(value: d.aiBestShotEnabled),
            RemoteConfigValues.Key.aiBlurFilterEnabled.rawValue: NSNumber(value: d.aiBlurFilterEnabled),
            RemoteConfigValues.Key.aiHighlightsEnabled.rawValue: NSNumber(value: d.aiHighlightsEnabled),
            RemoteConfigValues.Key.analyticsEnabled.rawValue: NSNumber(value: d.analyticsEnabled),
            RemoteConfigValues.Key.performanceMonitoringEnabled.rawValue: NSNumber(value: d.performanceMonitoringEnabled),
            RemoteConfigValues.Key.sessionReplayEnabled.rawValue: NSNumber(value: d.sessionReplayEnabled),
            RemoteConfigValues.Key.feedbackSurveysEnabled.rawValue: NSNumber(value: d.feedbackSurveysEnabled)
        ]
    }

    private static func read(from remote: RemoteConfig) -> RemoteConfigValues {
        // Until original-quality transfer ships, keep hard floors for the
        // matched-photo preview and manual scan batch. Critical thermal state
        // can still stop the scan for device safety.
        let requestedBatch = remote.configValue(forKey: RemoteConfigValues.Key.maxAssetsPerSyncBatch.rawValue).numberValue.intValue
        let requestedPixels = remote.configValue(forKey: RemoteConfigValues.Key.thumbnailMaxPixelSize.rawValue).numberValue.intValue
        let requestedQuality = remote.configValue(forKey: RemoteConfigValues.Key.thumbnailJPEGQuality.rawValue).numberValue.doubleValue
        let requestedGraceDays = remote.configValue(forKey: RemoteConfigValues.Key.eventGracePeriodDays.rawValue).numberValue.intValue

        return RemoteConfigValues(
            matchConfidenceThreshold: remote.configValue(forKey: RemoteConfigValues.Key.matchConfidenceThreshold.rawValue).numberValue.doubleValue,
            matchAmbiguityMargin: remote.configValue(forKey: RemoteConfigValues.Key.matchAmbiguityMargin.rawValue).numberValue.doubleValue,
            minFaceSizeFraction: remote.configValue(forKey: RemoteConfigValues.Key.minFaceSizeFraction.rawValue).numberValue.doubleValue,
            maxAssetsPerSyncBatch: max(100, requestedBatch),
            thumbnailMaxPixelSize: max(2560, requestedPixels),
            thumbnailJPEGQuality: min(1.0, max(0.92, requestedQuality)),
            signedURLTTLHours: remote.configValue(forKey: RemoteConfigValues.Key.signedURLTTLHours.rawValue).numberValue.intValue,
            defaultEventDurationDays: remote.configValue(forKey: RemoteConfigValues.Key.defaultEventDurationDays.rawValue).numberValue.intValue,
            maxEventDurationDays: remote.configValue(forKey: RemoteConfigValues.Key.maxEventDurationDays.rawValue).numberValue.intValue,
            // Launch policy: users may join/rejoin and recover photos for 15 days
            // after an Event ends. Keep this floor even if an older production
            // Remote Config value is still set to the previous 3-day window.
            eventGracePeriodDays: max(15, requestedGraceDays),
            maxParticipantsPerEvent: remote.configValue(forKey: RemoteConfigValues.Key.maxParticipantsPerEvent.rawValue).numberValue.intValue,
            aiBestShotEnabled: remote.configValue(forKey: RemoteConfigValues.Key.aiBestShotEnabled.rawValue).boolValue,
            aiBlurFilterEnabled: remote.configValue(forKey: RemoteConfigValues.Key.aiBlurFilterEnabled.rawValue).boolValue,
            aiHighlightsEnabled: remote.configValue(forKey: RemoteConfigValues.Key.aiHighlightsEnabled.rawValue).boolValue,
            analyticsEnabled: remote.configValue(forKey: RemoteConfigValues.Key.analyticsEnabled.rawValue).boolValue,
            performanceMonitoringEnabled: remote.configValue(forKey: RemoteConfigValues.Key.performanceMonitoringEnabled.rawValue).boolValue,
            sessionReplayEnabled: remote.configValue(forKey: RemoteConfigValues.Key.sessionReplayEnabled.rawValue).boolValue,
            feedbackSurveysEnabled: remote.configValue(forKey: RemoteConfigValues.Key.feedbackSurveysEnabled.rawValue).boolValue
        )
    }
}
