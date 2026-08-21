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

    /// Beta/device-safety ceiling. Remote Config may request a larger batch,
    /// but the client never exceeds this amount in one user-initiated pass.
    private static let normalSafetyBatchCap = 25
    private static let lowPowerSafetyBatchCap = 10

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
        try Task.checkCancellation()
        try Self.checkDeviceSafety()

        let values = config.current
        onProgress?(SyncProgress(phase: .preparing))
        guard EventLifecycle.canSync(event, clock: clock, config: values) else { throw AppError.eventExpired }
        guard faceDetection.isReadyForMatching else { throw AppError.faceRecognitionNotReady }

        if !photoLibrary.authorizationStatus().canRead {
            let status = await photoLibrary.requestAuthorization()
            guard status.canRead else { throw AppError.photoLibraryAccessDenied }
        }

        try Task.checkCancellation()
        let assets = try await photoLibrary.assets(in: event.dateRange)

        // Account + event + scan-generation isolation. A different user on the
        // same iPhone or any recognition-pipeline revision gets an independent
        // scan state. v5.1 intentionally rescans assets processed by v5.0.
        let scanStateKey = [event.id, currentUserId, FaceModelPolicy.scanGeneration]
            .joined(separator: "::")
        var state = scanStateStore.load(eventId: scanStateKey)

        // PhotoKit local identifiers can disappear when a photo is deleted or
        // Limited Photos access changes. Retain only identifiers still visible
        // in this event window so local scan-state storage stays bounded.
        state.retainScannedAssetIds(Set(assets.map(\.id)))

        let planned = ScanPlanner(config: values).plan(assets: assets, event: event, state: state)

        let safetyCap = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? Self.lowPowerSafetyBatchCap
            : Self.normalSafetyBatchCap
        let toScan = Array(planned.toScan.prefix(safetyCap))
        let deferredBySafetyCap = max(0, planned.toScan.count - toScan.count)
        let remainingAfterPass = planned.remaining + deferredBySafetyCap

        if toScan.isEmpty {
            state.lastSyncedAt = clock.now()
            scanStateStore.save(state)
            return Summary(scanned: 0, matchedPhotos: 0, remaining: remainingAfterPass, alreadyCaughtUp: remainingAfterPass == 0)
        }

        let matcher = FaceMatcher(config: values)
        let totalThisPass = toScan.count
        var matchedCount = 0
        var processedIds: [String] = []
        var failedCount = 0

        for asset in toScan {
            try Task.checkCancellation()
            try Self.checkDeviceSafety()

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
            } catch is CancellationError {
                // Persist completed work before surfacing cancellation so a user
                // can safely continue later without rescanning completed assets.
                state.markScanned(processedIds)
                state.lastSyncedAt = clock.now()
                scanStateStore.save(state)
                throw AppError.syncCancelled
            } catch let error as AppError where error == .deviceTooWarm {
                state.markScanned(processedIds)
                state.lastSyncedAt = clock.now()
                scanStateStore.save(state)
                throw error
            } catch {
                // Failed assets are deliberately NOT marked scanned. They remain
                // eligible for the next user-initiated sync instead of being
                // silently lost after a transient Storage/network/model error.
                failedCount += 1
                Log.scanner.error("Skipping asset during sync: \(String(describing: error), privacy: .public)")
            }

            let completedThisPass = processedIds.count + failedCount
            onProgress?(SyncProgress(
                phase: .scanning,
                checked: processedIds.count,
                matched: matchedCount,
                remaining: (totalThisPass - completedThisPass) + remainingAfterPass + failedCount
            ))

            // Cooperative yield prevents long runs from monopolizing an
            // executor and gives cancellation/UI work a chance between photos.
            await Task.yield()
        }

        let totalRemaining = remainingAfterPass + failedCount
        onProgress?(SyncProgress(phase: .finishing, checked: processedIds.count,
                                 matched: matchedCount, remaining: totalRemaining))
        state.markScanned(processedIds)
        state.lastSyncedAt = clock.now()
        scanStateStore.save(state)

        return Summary(scanned: processedIds.count, matchedPhotos: matchedCount,
                       remaining: totalRemaining, alreadyCaughtUp: totalRemaining == 0)
    }

    private func process(
        asset: PhotoAsset,
        event: Event,
        participants: [EventParticipant],
        currentUserId: String,
        matcher: FaceMatcher,
        values: RemoteConfigValues
    ) async throws -> Bool {
        try Task.checkCancellation()

        // The PhotoKit service now requests a bounded working image directly;
        // it no longer loads the full-resolution original before downsampling.
        let working = try await photoLibrary.imageData(
            for: asset.id,
            maxPixelSize: max(values.thumbnailMaxPixelSize, 2048)
        )
        try Task.checkCancellation()

        let faces = try await faceDetection.detectFaces(in: working)
        let appearances = matcher.appearances(in: faces, participants: participants)
        guard !appearances.isEmpty else { return false }

        try Task.checkCancellation()
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

    private static func checkDeviceSafety() throws {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            throw AppError.deviceTooWarm
        case .nominal, .fair:
            return
        @unknown default:
            return
        }
    }
}
