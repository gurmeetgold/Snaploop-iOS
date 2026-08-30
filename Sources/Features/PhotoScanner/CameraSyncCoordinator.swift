import Foundation

/// Orchestrates one "Scan Photos" pass, on demand, for a single event.
public struct CameraSyncCoordinator {
    private let config: ConfigProviding
    private let clock: Clock
    private let photoLibrary: PhotoLibraryService
    private let faceDetection: FaceDetectionService
    private let thumbnailEncoder: ThumbnailEncoder
    private let matches: MatchRepository
    private let scanStateStore: ScanStateStore

    private static let normalSafetyBatchCap = 100
    private static let lowPowerSafetyBatchCap = 100
    private static let elevatedThermalBatchCap = 100

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
        includeOwnMatches: Bool = false,
        preferenceRevision: String = "default",
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

        // Local scan state follows the stable biometric identities in the Event,
        // not the exact template revisions. A verified same-person Face Setup
        // refresh therefore keeps prior positive matches and does not trigger a
        // wasteful full rescan. Deleting Face Setup and enrolling a new identity
        // changes the stable ID and creates a fresh scan namespace.
        let rosterIdentityRevision = participants
            .map { "\($0.userId)=\($0.stableFaceIdentityId)" }
            .sorted()
            .joined(separator: ";")

        let scanStateKey = [
            event.id,
            currentUserId,
            FaceModelPolicy.scanGeneration,
            "sharing-v5",
            includeOwnMatches ? "own-on" : "own-off",
            preferenceRevision,
            rosterIdentityRevision,
        ].joined(separator: "::")
        var state = scanStateStore.load(eventId: scanStateKey)
        state.retainScannedAssetIds(Set(assets.map(\.id)))

        let planned = ScanPlanner(config: values).plan(assets: assets, event: event, state: state)
        let safetyCap = Self.currentSafetyBatchCap()
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
                    includeOwnMatches: includeOwnMatches,
                    matcher: matcher,
                    values: values
                )
                if matched { matchedCount += 1 }
                processedIds.append(asset.id)
            } catch is CancellationError {
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
                failedCount += 1
                Log.scanner.error("Skipping asset during scan: \(String(describing: error), privacy: .public)")
            }

            let completedThisPass = processedIds.count + failedCount
            onProgress?(SyncProgress(
                phase: .scanning,
                checked: processedIds.count,
                matched: matchedCount,
                remaining: (totalThisPass - completedThisPass) + remainingAfterPass + failedCount
            ))
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
        includeOwnMatches: Bool,
        matcher: FaceMatcher,
        values: RemoteConfigValues
    ) async throws -> Bool {
        try Task.checkCancellation()

        let working = try await photoLibrary.imageData(
            for: asset.id,
            maxPixelSize: max(values.thumbnailMaxPixelSize, 2048)
        )
        try Task.checkCancellation()

        var appearances: [PhotoMatch.Appearance]
        do {
            let transientCandidateFaces = try await faceDetection.detectFaces(in: working)
            appearances = matcher.appearances(in: transientCandidateFaces, participants: participants)
        }

        if !includeOwnMatches {
            appearances.removeAll { $0.participantUserId == currentUserId }
        }
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

    private static func currentSafetyBatchCap() -> Int {
        let baseCap = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? lowPowerSafetyBatchCap
            : normalSafetyBatchCap

        if ProcessInfo.processInfo.thermalState == .serious {
            return min(baseCap, elevatedThermalBatchCap)
        }
        return baseCap
    }

    private static func checkDeviceSafety() throws {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: throw AppError.deviceTooWarm
        case .nominal, .fair, .serious: return
        @unknown default: return
        }
    }
}
