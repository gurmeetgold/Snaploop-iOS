import Foundation

/// Every tunable in SnapLoop lives here — nothing is hardcoded at a call site.
///
/// In production these values are hydrated from Firebase Remote Config
/// (see `RemoteConfigService`). `RemoteConfigValues.default` is the safe,
/// shipped-in fallback used before the first fetch completes and whenever a
/// key is missing. Business logic always receives an instance of this struct;
/// it never reaches for a global constant.
public struct RemoteConfigValues: Equatable, Sendable {

    // MARK: Face matching

    /// Minimum cosine similarity for a detected face to be considered a match
    /// for a participant. Tuned to favor **precision over recall** — we would
    /// rather miss a few photos than show someone a stranger.
    public var matchConfidenceThreshold: Double

    /// The best candidate must beat the second-best candidate by at least this
    /// margin, otherwise the face is treated as ambiguous and matched to nobody.
    /// This is the core precision guard against look-alikes.
    public var matchAmbiguityMargin: Double

    /// Faces smaller than this fraction of the image's shorter edge are ignored
    /// (background bystanders, crowd blur) to keep precision high.
    public var minFaceSizeFraction: Double

    // MARK: Scanning

    /// Maximum number of photo-library assets scanned in a single sync pass, so
    /// a huge library never blocks the UI. The next pass resumes where this left
    /// off via incremental scan state.
    public var maxAssetsPerSyncBatch: Int

    // MARK: Uploads / transfers

    /// Longest edge, in pixels, of the thumbnail uploaded for a matched photo.
    public var thumbnailMaxPixelSize: Int

    /// JPEG compression quality (0...1) for uploaded thumbnails.
    public var thumbnailJPEGQuality: Double

    /// Time-to-live, in hours, of a signed URL minted for an on-demand
    /// full-resolution original download.
    public var signedURLTTLHours: Int

    // MARK: Event limits

    /// Default event window in days from start (used when a creator does not set
    /// an explicit end date).
    public var defaultEventDurationDays: Int

    /// Hard cap on how long any single event may run.
    public var maxEventDurationDays: Int

    /// Grace period, in days, after an event's end date during which stragglers
    /// may still sync and everyone may still download.
    public var eventGracePeriodDays: Int

    /// Maximum number of participants in one event.
    public var maxParticipantsPerEvent: Int

    // MARK: AI feature flags (additive — the core loop works with all disabled)

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

    /// Shipped-in defaults. Deliberately conservative on the matching side.
    public static let `default` = RemoteConfigValues(
        matchConfidenceThreshold: 0.90,
        matchAmbiguityMargin: 0.04,
        minFaceSizeFraction: 0.045,
        maxAssetsPerSyncBatch: 400,
        thumbnailMaxPixelSize: 1024,
        thumbnailJPEGQuality: 0.72,
        signedURLTTLHours: 48,
        defaultEventDurationDays: 15,
        maxEventDurationDays: 30,
        eventGracePeriodDays: 3,
        maxParticipantsPerEvent: 250,
        aiBestShotEnabled: true,
        aiBlurFilterEnabled: true,
        aiHighlightsEnabled: true
    )
}

public extension RemoteConfigValues {
    /// Remote Config keys. Kept next to the struct so a new tunable is added in
    /// exactly one place.
    enum Key: String, CaseIterable {
        case matchConfidenceThreshold  = "match_confidence_threshold"
        case matchAmbiguityMargin      = "match_ambiguity_margin"
        case minFaceSizeFraction       = "min_face_size_fraction"
        case maxAssetsPerSyncBatch     = "max_assets_per_sync_batch"
        case thumbnailMaxPixelSize     = "thumbnail_max_pixel_size"
        case thumbnailJPEGQuality      = "thumbnail_jpeg_quality"
        case signedURLTTLHours         = "signed_url_ttl_hours"
        case defaultEventDurationDays  = "default_event_duration_days"
        case maxEventDurationDays      = "max_event_duration_days"
        case eventGracePeriodDays      = "event_grace_period_days"
        case maxParticipantsPerEvent   = "max_participants_per_event"
        case aiBestShotEnabled         = "ai_best_shot_enabled"
        case aiBlurFilterEnabled       = "ai_blur_filter_enabled"
        case aiHighlightsEnabled       = "ai_highlights_enabled"
    }
}
