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
    private let accountInstallationIdentity: AccountInstallationIdentityProviding

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
        scanStateStore: ScanStateStore,
        accountInstallationIdentity: AccountInstallationIdentityProviding = InMemoryAccountInstallationIdentityStore()
    ) {
        self.config = config
        self.clock = clock
        self.photoLibrary = photoLibrary
        self.faceDetection = faceDetection
        self.thumbnailEncoder = thumbnailEncoder
        self.matches = matches
        self.scanStateStore = scanStateStore
        self.accountInstallationIdentity = accountInstallationIdentity
    }

    public struct Summary: Equatable, Sendable {
        public let scanned: Int
        public let matchedPhotos: Int
        public let remaining: Int
        public let alreadyCaughtUp: Bool
        public var hasMore: Bool { remaining > 0 }
    }

    /// Aggregated counters are intentionally identity-free. Do not add event IDs,
    /// user IDs, asset IDs, template IDs, embeddings, names, phone numbers or
    /// similarity scores here. These values are emitted only to local unified
    /// logging to diagnose why a scan produced fewer matches than expected.
    private struct PassDiagnostics {
        var detectedFaces = 0
        var sizeRejectedFaces = 0
        var eligibleFaces = 0
        var acceptedFaces = 0
        var belowThresholdFaces = 0
        var ambiguityRejectedFaces = 0
        var ownAppearancesFiltered = 0

        mutating func record(_ result: ProcessResult) {
            let d = result.faceDiagnostics
            detectedFaces += d.detectedFaceCount
            sizeRejectedFaces += d.sizeRejectedFaceCount
            eligibleFaces += d.eligibleFaceCount
            acceptedFaces += d.acceptedFaceCount
            belowThresholdFaces += d.belowThresholdFaceCount
            ambiguityRejectedFaces += d.ambiguityRejectedFaceCount
            ownAppearancesFiltered += result.ownAppearancesFiltered
        }
    }

    private struct ProcessResult {
        let matched: Bool
        let ownAppearancesFiltered: Int
        let faceDiagnostics: FaceMatcher.Diagnostics
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

        let sourceInstallationId = accountInstallationIdentity.id(for: currentUserId)
        guard !sourceInstallationId.isEmpty else { throw AppError.notAuthenticated }
        // Face-roster rows now carry the server membership generation. Legacy
        // deployed backends can temporarily return nil; the server then applies
        // its compatibility path rather than inventing a client-side identity.
        let sourceMembershipId = participants
            .first(where: { $0.userId == currentUserId })?
            .membershipId

        try Task.checkCancellation()
        let assets = try await photoLibrary.assets(in: event.dateRange)

        // Local scan state follows the stable biometric identities in the Event,
        // not the exact template revisions. A verified same-person Face Setup
        // refresh therefore keeps prior positive matches and does not trigger a
        // wasteful full rescan. Deleting Face Setup and enrolling a new identity
        // changes the stable ID and creates a fresh scan namespace.
        //
        // NOTE: Change 2 intentionally leaves this legacy state namespace intact.
        // Activating source-scoped photo IDs or a new scan namespace before the
        // photo-corpus + recipient-cursor migration could create duplicate photo
        // documents during roster-triggered rescans.
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
        let matchableParticipantCount = participants.filter {
            $0.faceProfileVersion == FaceModelPolicy.currentVersion
                && !$0.stableFaceIdentityId.isEmpty
                && !$0.faceProfileRevision.isEmpty
        }.count

        Log.scanner.notice(
            "Scan diagnostics begin assets=\(assets.count, privacy: .public) remembered=\(state.scannedCount, privacy: .public) planned=\(planned.toScan.count, privacy: .public) roster=\(participants.count, privacy: .public) matchable=\(matchableParticipantCount, privacy: .public) includeOwn=\(includeOwnMatches, privacy: .public)"
        )

        if toScan.isEmpty {
            state.lastSyncedAt = clock.now()
            scanStateStore.save(state)
            Log.scanner.notice(
                "Scan diagnostics caught-up assets=\(assets.count, privacy: .public) remembered=\(state.scannedCount, privacy: .public) remaining=\(remainingAfterPass, privacy: .public)"
            )
            return Summary(scanned: 0, matchedPhotos: 0, remaining: remainingAfterPass, alreadyCaughtUp: remainingAfterPass == 0)
        }

        let matcher = FaceMatcher(config: values)
        let totalThisPass = toScan.count
        var matchedCount = 0
        var processedIds: [String] = []
        var failedCount = 0
        var passDiagnostics = PassDiagnostics()

        for asset in toScan {
            try Task.checkCancellation()
            try Self.checkDeviceSafety()

            do {
                let result = try await process(
                    asset: asset,
                    event: event,
                    participants: participants,
                    currentUserId: currentUserId,
                    sourceInstallationId: sourceInstallationId,
                    sourceMembershipId: sourceMembershipId,
                    includeOwnMatches: includeOwnMatches,
                    matcher: matcher,
                    values: values
                )
                passDiagnostics.record(result)
                if result.matched { matchedCount += 1 }
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
                Log.scanner.error(
                    "Scan asset skipped category=\(Self.diagnosticErrorCategory(error), privacy: .public)"
                )
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

        Log.scanner.notice(
            "Scan diagnostics end checked=\(processedIds.count, privacy: .public) matchedPhotos=\(matchedCount, privacy: .public) failed=\(failedCount, privacy: .public) faces=\(passDiagnostics.detectedFaces, privacy: .public) sizeRejected=\(passDiagnostics.sizeRejectedFaces, privacy: .public) eligibleFaces=\(passDiagnostics.eligibleFaces, privacy: .public) acceptedFaces=\(passDiagnostics.acceptedFaces, privacy: .public) belowThreshold=\(passDiagnostics.belowThresholdFaces, privacy: .public) ambiguous=\(passDiagnostics.ambiguityRejectedFaces, privacy: .public) ownFiltered=\(passDiagnostics.ownAppearancesFiltered, privacy: .public) remaining=\(totalRemaining, privacy: .public)"
        )

        return Summary(scanned: processedIds.count, matchedPhotos: matchedCount,
                       remaining: totalRemaining, alreadyCaughtUp: totalRemaining == 0)
    }

    private func process(
        asset: PhotoAsset,
        event: Event,
        participants: [EventParticipant],
        currentUserId: String,
        sourceInstallationId: String,
        sourceMembershipId: String?,
        includeOwnMatches: Bool,
        matcher: FaceMatcher,
        values: RemoteConfigValues
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let working = try await photoLibrary.imageData(
            for: asset.id,
            maxPixelSize: max(values.thumbnailMaxPixelSize, 2048)
        )
        try Task.checkCancellation()

        let transientCandidateFaces = try await faceDetection.detectFaces(in: working)
        let matchResult = matcher.appearancesWithDiagnostics(
            in: transientCandidateFaces,
            participants: participants
        )
        var appearances = matchResult.appearances
        let beforeOwnFilter = appearances.count

        if !includeOwnMatches {
            appearances.removeAll { $0.participantUserId == currentUserId }
        }
        let ownAppearancesFiltered = max(0, beforeOwnFilter - appearances.count)

        guard !appearances.isEmpty else {
            return ProcessResult(
                matched: false,
                ownAppearancesFiltered: ownAppearancesFiltered,
                faceDiagnostics: matchResult.diagnostics
            )
        }

        try Task.checkCancellation()
        let thumbnail = try thumbnailEncoder.encodeJPEG(
            from: working,
            maxPixelSize: values.thumbnailMaxPixelSize,
            quality: values.thumbnailJPEGQuality
        )
        let match = PhotoMatch(
            eventId: event.id,
            ownerUserId: currentUserId,
            sourceInstallationId: sourceInstallationId,
            sourceMembershipId: sourceMembershipId,
            assetLocalId: asset.id,
            appearances: appearances,
            capturedAt: asset.creationDate,
            matchedAt: clock.now(),
            // Keep legacy photo document identity until the corpus/cursor state
            // migration lands. Source metadata is already carried to the server.
            useSourceScopedIdentity: false
        )
        try await matches.upload(match: match, thumbnailJPEG: thumbnail)
        return ProcessResult(
            matched: true,
            ownAppearancesFiltered: ownAppearancesFiltered,
            faceDiagnostics: matchResult.diagnostics
        )
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

    /// Keep diagnostic logs useful without ever serializing error payloads that
    /// may contain backend messages, paths, identifiers or other user data.
    private static func diagnosticErrorCategory(_ error: Error) -> String {
        guard let appError = error as? AppError else { return "non_app_error" }
        switch appError {
        case .photoLibraryAccessDenied:
            return "photo_library_access"
        case .thumbnailEncodingFailed, .originalUnavailable:
            return "photo_io"
        case .faceEmbeddingFailed, .faceRecognitionNotReady, .noFaceDetectedInSelfie, .multipleFacesInSelfie:
            return "face_pipeline"
        case .faceIdentityMismatch:
            return "face_identity"
        case .deviceTooWarm:
            return "thermal"
        case .syncCancelled:
            return "cancelled"
        case .eventNotFound, .eventExpired, .notAMember:
            return "event_state"
        case .network:
            return "network"
        case .backend:
            return "backend"
        case .decoding:
            return "decoding"
        case .notAuthenticated:
            return "auth"
        default:
            return "app_error"
        }
    }
}
