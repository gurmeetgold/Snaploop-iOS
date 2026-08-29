import Foundation

public struct RemoteConfigValues: Equatable, Sendable {
    public var matchConfidenceThreshold: Double
    public var matchAmbiguityMargin: Double
    public var minFaceSizeFraction: Double
    public var maxAssetsPerSyncBatch: Int
    public var thumbnailMaxPixelSize: Int
    public var thumbnailJPEGQuality: Double
    public var signedURLTTLHours: Int
    public var defaultEventDurationDays: Int
    public var maxEventDurationDays: Int
    public var eventGracePeriodDays: Int
    public var maxParticipantsPerEvent: Int
    public var aiBestShotEnabled: Bool
    public var aiBlurFilterEnabled: Bool
    public var aiHighlightsEnabled: Bool

    public init(
        matchConfidenceThreshold: Double,
        matchAmbiguityMargin: Double,
        minFaceSizeFraction: Double,
        maxAssetsPerSyncBatch: Int,
        thumbnailMaxPixelSize: Int,
        thumbnailJPEGQuality: Double,
        signedURLTTLHours: Int,
        defaultEventDurationDays: Int,
        maxEventDurationDays: Int,
        eventGracePeriodDays: Int,
        maxParticipantsPerEvent: Int,
        aiBestShotEnabled: Bool = true,
        aiBlurFilterEnabled: Bool = true,
        aiHighlightsEnabled: Bool = true
    ) {
        self.matchConfidenceThreshold = matchConfidenceThreshold
        self.matchAmbiguityMargin = matchAmbiguityMargin
        self.minFaceSizeFraction = minFaceSizeFraction
        self.maxAssetsPerSyncBatch = maxAssetsPerSyncBatch
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize
        self.thumbnailJPEGQuality = thumbnailJPEGQuality
        self.signedURLTTLHours = signedURLTTLHours
        self.defaultEventDurationDays = defaultEventDurationDays
        self.maxEventDurationDays = maxEventDurationDays
        self.eventGracePeriodDays = eventGracePeriodDays
        self.maxParticipantsPerEvent = maxParticipantsPerEvent
        self.aiBestShotEnabled = aiBestShotEnabled
        self.aiBlurFilterEnabled = aiBlurFilterEnabled
        self.aiHighlightsEnabled = aiHighlightsEnabled
    }

    /// MVP previews are intentionally high quality because they are also the
    /// downloadable image until original-photo transfer ships. Events keep a
    /// 15-day post-event photo window so late members can still join and collect
    /// matched photos after the gathering has finished.
    public static let `default` = RemoteConfigValues(
        matchConfidenceThreshold: FaceModelPolicy.evaluationMatchThreshold,
        matchAmbiguityMargin: FaceModelPolicy.evaluationAmbiguityMargin,
        minFaceSizeFraction: 0.045,
        maxAssetsPerSyncBatch: 50,
        thumbnailMaxPixelSize: 2560,
        thumbnailJPEGQuality: 0.92,
        signedURLTTLHours: 48,
        defaultEventDurationDays: 15,
        maxEventDurationDays: 15,
        eventGracePeriodDays: 15,
        maxParticipantsPerEvent: 250,
        aiBestShotEnabled: true,
        aiBlurFilterEnabled: true,
        aiHighlightsEnabled: true
    )
}

public extension RemoteConfigValues {
    enum Key: String, CaseIterable {
        case matchConfidenceThreshold = "face_v5_match_confidence_threshold"
        case matchAmbiguityMargin = "face_v5_match_ambiguity_margin"
        case minFaceSizeFraction = "min_face_size_fraction"
        case maxAssetsPerSyncBatch = "max_assets_per_sync_batch"
        case thumbnailMaxPixelSize = "thumbnail_max_pixel_size"
        case thumbnailJPEGQuality = "thumbnail_jpeg_quality"
        case signedURLTTLHours = "signed_url_ttl_hours"
        case defaultEventDurationDays = "default_event_duration_days"
        case maxEventDurationDays = "max_event_duration_days"
        case eventGracePeriodDays = "event_grace_period_days"
        case maxParticipantsPerEvent = "max_participants_per_event"
        case aiBestShotEnabled = "ai_best_shot_enabled"
        case aiBlurFilterEnabled = "ai_blur_filter_enabled"
        case aiHighlightsEnabled = "ai_highlights_enabled"
    }
}
