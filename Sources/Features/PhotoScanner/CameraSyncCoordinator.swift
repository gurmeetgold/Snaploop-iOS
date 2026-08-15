import Foundation

/// Orchestrates one "Sync My Camera" pass, on demand, for a single event.
///
/// This is the seam where all the pure engines meet the device services:
///   plan (ScanPlanner) → load image → detect faces → match (FaceMatcher)
///   → encode thumbnail → upload → record scan state.
///
/// Rules it upholds (all delegated to the pure pieces it composes):
///   • Only this device's own library, only the event's date window.
///   • Never rescans an asset already in `ScanState`.
///   • Only matched photos upload; only thumbnail + metadata, never originals.
///   • Refuses to run when the event's lifecycle forbids syncing.
///
/// Every asset in the batch is marked scanned whether or not it matched, so a
/// non-matching photo is never re-processed.
public struct CameraSyncCoordinator {

    private let config: ConfigProviding
    private let clock: Clock
    private let photoLibrary: PhotoLibraryService
    private let faceDetection: FaceDetectionService
    private let thumbnailEncoder: ThumbnailEncoder
    private let matches: MatchRepository
    private let scanStateStore: ScanStateStore

    public init(
        config: ConfigProviding,
        clock: Clock,
        photoLibrary: PhotoLibraryService,
        faceDetection: FaceDetectionService,
        thumbnailEncoder: ThumbnailEncoder,
        matches: MatchRepository,
        scanStateStore: ScanStateStore
    ) {
        self.config = config
        self.clock = clock
        self.photoLibrary = photoLibrary
        self.faceDetection = faceDetection
        self.thumbnailEncoder = thumbnailEncoder
        self.matches = matches
        self.scanStateStore = scanStateStore
    }

    /// Outcome of one pass — enough for the UI to say something human
    /// ("Found 3 new photos of you", "You're all caught up").
    public struct Summary: Equatable, Sendable {
        public let scanned: Int          // assets processed this pass
        public let matchedPhotos: Int    // photos with ≥1 participant appearance
        public let remaining: Int        // eligible assets left for the next pass
        public let alreadyCaughtUp: Bool // nothing new to scan at all

        public var hasMore: Bool { remaining > 0 }
    }

    /// Runs a single incremental pass for `event` on behalf of `currentUserId`.
    public func sync(
        event: Event,
        participants: [EventParticipant],
        currentUserId: String
    ) async throws -> Summary {
        let values = config.current

        // Lifecycle gate.
        guard EventLifecycle.canSync(event, clock: clock, config: values) else {
            throw AppError.eventExpired
        }

        // Permission gate.
        guard photoLibrary.authorizationStatus().canRead else {
            let status = await photoLibrary.requestAuthorization()
            guard status.canRead else { throw AppError.photoLibraryAccessDenied }
        }

        // Plan the batch.
        let assets = try await photoLibrary.assets(in: event.dateRange)
        var state = scanStateStore.load(eventId: event.id)
        let plan = ScanPlanner(config: values).plan(assets: assets, event: event, state: state)

        if plan.isEmpty {
            state.lastSyncedAt = clock.now()
            scanStateStore.save(state)
            return Summary(scanned: 0, matchedPhotos: 0, remaining: 0, alreadyCaughtUp: true)
        }

        let matcher = FaceMatcher(config: values)
        var matchedCount = 0
        var processedIds: [String] = []

        for asset in plan.toScan {
            do {
                let matched = try await process(
                    asset: asset,
                    event: event,
                    participants: participants,
                    currentUserId: currentUserId,
                    matcher: matcher,
                    values: values
                )
                if matched { matchedCount += 1 }
                // Mark scanned whether or not it matched — never reprocess it.
                processedIds.append(asset.id)
            } catch {
                // One bad asset must not abort the whole pass. Leave it
                // unmarked so a later pass retries it, and move on.
                Log.scanner.error("Skipping asset during sync: \(String(describing: error), privacy: .public)")
            }
        }

        state.markScanned(processedIds)
        state.lastSyncedAt = clock.now()
        scanStateStore.save(state)

        return Summary(
            scanned: processedIds.count,
            matchedPhotos: matchedCount,
            remaining: plan.remaining,
            alreadyCaughtUp: false
        )
    }

    /// Processes one asset. Returns whether it matched at least one participant.
    private func process(
        asset: PhotoAsset,
        event: Event,
        participants: [EventParticipant],
        currentUserId: String,
        matcher: FaceMatcher,
        values: RemoteConfigValues
    ) async throws -> Bool {
        // Load a working image sized for detection (thumbnail size is plenty for
        // on-device face detection at MVP quality).
        let working = try await photoLibrary.imageData(
            for: asset.id,
            maxPixelSize: max(values.thumbnailMaxPixelSize, 1024)
        )

        let faces = try await faceDetection.detectFaces(in: working)
        let appearances = matcher.appearances(in: faces, participants: participants)
        guard !appearances.isEmpty else { return false }

        let thumbnail = try thumbnailEncoder.encodeJPEG(
            from: working,
            maxPixelSize: values.thumbnailMaxPixelSize,
            quality: values.thumbnailJPEGQuality
        )

        let match = PhotoMatch(
            eventId: event.id,
            ownerUserId: currentUserId,
            assetLocalId: asset.id,
            appearances: appearances,
            capturedAt: asset.creationDate,
            matchedAt: clock.now()
        )

        try await matches.upload(match: match, thumbnailJPEG: thumbnail)
        return true
    }
}
