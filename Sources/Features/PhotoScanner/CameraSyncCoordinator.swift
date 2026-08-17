import Foundation

/// Orchestrates one "Sync My Camera" pass, on demand, for a single event.
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

    public struct Summary: Equatable, Sendable {
        public let scanned: Int
        public let matchedPhotos: Int
        public let remaining: Int
        public let alreadyCaughtUp: Bool
        public var hasMore: Bool { remaining > 0 }
    }

    public func sync(
        event: Event,
        participants: [EventParticipant],
        currentUserId: String,
        onProgress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> Summary {
        let values = config.current
        onProgress?(SyncProgress(phase: .preparing))
        guard EventLifecycle.canSync(event, clock: clock, config: values) else { throw AppError.eventExpired }
        guard faceDetection.isReadyForMatching else { throw AppError.faceRecognitionNotReady }

        if !photoLibrary.authorizationStatus().canRead {
            let status = await photoLibrary.requestAuthorization()
            guard status.canRead else { throw AppError.photoLibraryAccessDenied }
        }

        let assets = try await photoLibrary.assets(in: event.dateRange)
        // Account + event + scan-generation isolation. A different user on the
        // same iPhone or any recognition-pipeline revision gets an independent
        // scan state. v5.1 intentionally rescans assets processed by v5.0.
        let scanStateKey = [event.id, currentUserId, FaceModelPolicy.scanGeneration]
            .joined(separator: "::")
        var state = scanStateStore.load(eventId: scanStateKey)
        let plan = ScanPlanner(config: values).plan(assets: assets, event: event, state: state)

        if plan.isEmpty {
            state.lastSyncedAt = clock.now()
            scanStateStore.save(state)
            return Summary(scanned: 0, matchedPhotos: 0, remaining: 0, alreadyCaughtUp: true)
        }

        let matcher = FaceMatcher(config: values)
        let totalThisPass = plan.toScan.count
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
                processedIds.append(asset.id)
                onProgress?(SyncProgress(
                    phase: .scanning,
                    checked: processedIds.count,
                    matched: matchedCount,
                    remaining: (totalThisPass - processedIds.count) + plan.remaining
                ))
            } catch {
                Log.scanner.error("Skipping asset during sync: \(String(describing: error), privacy: .public)")
            }
        }

        onProgress?(SyncProgress(phase: .finishing, checked: processedIds.count,
                                 matched: matchedCount, remaining: plan.remaining))
        state.markScanned(processedIds)
        state.lastSyncedAt = clock.now()
        scanStateStore.save(state)

        return Summary(scanned: processedIds.count, matchedPhotos: matchedCount,
                       remaining: plan.remaining, alreadyCaughtUp: false)
    }

    private func process(
        asset: PhotoAsset,
        event: Event,
        participants: [EventParticipant],
        currentUserId: String,
        matcher: FaceMatcher,
        values: RemoteConfigValues
    ) async throws -> Bool {
        // v5.1 uses a 2048px recognition working image. The old 1024px input
        // discarded too many pixels from distant faces before Vision even saw
        // them. Upload thumbnails remain independently capped at the configured
        // size, so this does not increase cloud thumbnail size.
        let working = try await photoLibrary.imageData(
            for: asset.id,
            maxPixelSize: max(values.thumbnailMaxPixelSize, 2048)
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
