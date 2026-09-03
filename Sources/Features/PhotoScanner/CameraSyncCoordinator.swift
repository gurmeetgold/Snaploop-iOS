import Foundation

/// Orchestrates one "Scan Photos" pass, on demand, for a single Event.
///
/// Change 4 separates expensive photo processing from recipient matching:
/// - each source photo is decoded/detected/embedded once into a protected local
///   corpus;
/// - each Event recipient owns an independent cursor over that corpus;
/// - roster, membership, Face Setup and sharing-generation changes invalidate
///   only the minimum matching/publication work, never the cached extraction.
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
    static let corpusGeneration = "photo-corpus-v1"

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
        /// Number of source assets whose currently-pending corpus/recipient work
        /// completed during this pass. A cached historical rematch counts once.
        public let scanned: Int
        public let matchedPhotos: Int
        public let remaining: Int
        public let alreadyCaughtUp: Bool
        public var hasMore: Bool { remaining > 0 }
    }

    /// Aggregated counters are intentionally identity-free. Do not add Event IDs,
    /// user IDs, asset IDs, template IDs, embeddings, names, phone numbers or
    /// similarity scores here.
    private struct PassDiagnostics {
        var detectedFaces = 0
        var sizeRejectedFaces = 0
        var eligibleFaces = 0
        var acceptedFaces = 0
        var belowThresholdFaces = 0
        var ambiguityRejectedFaces = 0
        var ownAppearancesFiltered = 0
        var newlyProcessedAssets = 0
        var cachedRematchAssets = 0

        mutating func record(_ diagnostics: FaceMatcher.Diagnostics, ownFiltered: Int) {
            detectedFaces += diagnostics.detectedFaceCount
            sizeRejectedFaces += diagnostics.sizeRejectedFaceCount
            eligibleFaces += diagnostics.eligibleFaceCount
            acceptedFaces += diagnostics.acceptedFaceCount
            belowThresholdFaces += diagnostics.belowThresholdFaceCount
            ambiguityRejectedFaces += diagnostics.ambiguityRejectedFaceCount
            ownAppearancesFiltered += ownFiltered
        }
    }

    private struct PreferenceRevisions {
        let sharing: String?
        let ownMatches: String?
    }

    /// The client sends a combined token (`share=...;own=...`) so automatic sync
    /// wakes for either preference. The two revisions must be applied separately:
    /// changing "Keep My Pics" may invalidate only the source user's own cursor,
    /// while changing sharing generation can require replaying every previously
    /// published positive from this source.
    private static func preferenceRevisions(_ rawValue: String) -> PreferenceRevisions {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return PreferenceRevisions(sharing: nil, ownMatches: nil) }

        guard raw.contains("share=") || raw.contains("own=") else {
            // Backward compatibility for pre-combined callers/tests.
            return PreferenceRevisions(sharing: raw, ownMatches: nil)
        }

        var sharing: String?
        var ownMatches: String?
        for component in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let value = String(component)
            if value.hasPrefix("share=") {
                sharing = normalizedRevision(String(value.dropFirst("share=".count)))
            } else if value.hasPrefix("own=") {
                ownMatches = normalizedRevision(String(value.dropFirst("own=".count)))
            }
        }
        return PreferenceRevisions(sharing: sharing, ownMatches: ownMatches)
    }

    /// Stable local namespace: Event + account-scoped installation + face-model
    /// generation. Roster/template/preferences are deliberately absent; those
    /// changes are represented by recipient cursors rather than duplicate corpora.
    static func scanStateKey(eventId: String, sourceInstallationId: String) -> String {
        [
            eventId,
            sourceInstallationId,
            FaceModelPolicy.scanGeneration,
            corpusGeneration,
        ].joined(separator: "::")
    }

    private static func isMatchable(_ participant: EventParticipant) -> Bool {
        participant.faceProfileVersion == FaceModelPolicy.currentVersion
            && !participant.stableFaceIdentityId.isEmpty
            && !participant.faceProfileRevision.isEmpty
    }

    private static func normalizedMembershipId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedRevision(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pre-Change-4/test callers do not have a server-issued sharing generation.
    /// These baseline tokens must not trigger a one-time replay merely because
    /// schema v3 learned how to persist a sharing revision.
    private static func isBaselineSharingRevision(_ revision: String) -> Bool {
        revision == "default" || revision == "dev" || revision == "legacy:0"
    }

    /// FaceMatcher's ambiguity margin compares identities against one another.
    /// Adding/removing/updating any matchable identity can change either direction
    /// of a prior decision: a miss can become a hit, while an old hit can become
    /// ambiguous. The roster fingerprint therefore makes all prior outcomes stale
    /// without discarding the expensive cached photo-face extraction.
    private static func ambiguityRosterRevision(_ participants: [EventParticipant]) -> String {
        participants
            .filter(isMatchable)
            .map {
                [
                    $0.userId,
                    AutomaticSyncIdentityScope.participantEpoch($0),
                    $0.stableFaceIdentityId,
                    $0.faceProfileRevision,
                ].joined(separator: "=")
            }
            .sorted()
            .joined(separator: ";")
    }

    public func sync(
        event: Event,
        participants: [EventParticipant],
        currentUserId: String,
        sourceMembershipId explicitSourceMembershipId: String? = nil,
        includeOwnMatches: Bool = false,
        preferenceRevision: String = "default",
        onProgress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> Summary {
        try Task.checkCancellation()
        try Self.checkDeviceSafety()

        let values = config.current
        onProgress?(SyncProgress(phase: .preparing))
        guard EventLifecycle.canSync(event, clock: clock, config: values) else {
            throw AppError.eventExpired
        }
        guard faceDetection.isReadyForMatching else {
            throw AppError.faceRecognitionNotReady
        }

        if !photoLibrary.authorizationStatus().canRead {
            let status = await photoLibrary.requestAuthorization()
            guard status.canRead else { throw AppError.photoLibraryAccessDenied }
        }

        let sourceInstallationId = accountInstallationIdentity.id(for: currentUserId)
        guard !sourceInstallationId.isEmpty else { throw AppError.notAuthenticated }

        // Source membership is authorization state, not biometric state. The
        // trusted face-roster manifest supplies it independently so a member can
        // contribute photos even when their own Face Setup is not a recipient row.
        let sourceParticipant = participants.first(where: { $0.userId == currentUserId })
        let sourceMembershipId = Self.normalizedMembershipId(explicitSourceMembershipId)
            ?? Self.normalizedMembershipId(sourceParticipant?.membershipId)
        let sourceMembershipEpoch = sourceMembershipId
            ?? sourceParticipant.map(AutomaticSyncIdentityScope.participantEpoch)

        try Task.checkCancellation()
        let fetchedAssets = try await photoLibrary.assets(in: event.dateRange)
        let assets = fetchedAssets.sorted {
            if $0.creationDate != $1.creationDate { return $0.creationDate < $1.creationDate }
            return $0.id < $1.id
        }

        let stateKey = Self.scanStateKey(
            eventId: event.id,
            sourceInstallationId: sourceInstallationId
        )
        var state = scanStateStore.load(eventId: stateKey)
        state.schemaVersion = ScanState.currentSchemaVersion
        state.retainCurrentAssets(Set(assets.map(\.id)))

        // Source leave/rejoin invalidates every outbound recipient cursor because
        // newly published rows must bind to the new source membership generation.
        // The local photo-face corpus remains valid and is reused.
        if let sourceMembershipEpoch {
            if let previous = state.sourceMembershipEpoch,
               previous != sourceMembershipEpoch {
                state.resetRecipientCursors()
            }
            state.sourceMembershipEpoch = sourceMembershipEpoch
        }

        let revisions = Self.preferenceRevisions(preferenceRevision)
        // Schema-v5 migration can contain the old combined token inside the
        // sharing slot. Parse that old value before normalizing the two fields so
        // upgrading does not cause a needless replay for every Event member.
        let previouslyStoredCombined = state.sourceSharingRevision.map(Self.preferenceRevisions)

        // Sharing OFF deletes this source account's server photo rows. When it is
        // enabled again, the server issues a new sharing revision. Reopen only the
        // old positive cursor outcomes so those rows are republished from cached
        // face extraction; negatives still represent valid misses.
        if let sharingRevision = revisions.sharing {
            let previousSharingRevision = previouslyStoredCombined?.sharing
            if let previous = previousSharingRevision {
                if previous != sharingRevision {
                    state.clearPositiveRecipientEvaluations()
                }
            } else if state.hasPositiveRecipientEvaluations,
                      !Self.isBaselineSharingRevision(sharingRevision) {
                // Schema-v2 migration: a non-baseline current revision proves
                // sharing changed at least once. Replaying positives once is safe
                // and idempotent, and prevents a permanently empty server album.
                state.clearPositiveRecipientEvaluations()
            }
            state.sourceSharingRevision = sharingRevision
        }

        // "Keep My Pics" / own-photo visibility is intentionally independent
        // from source sharing. A change can only affect the source user's own
        // recipient cursor. In particular it must never turn arbitrary contact or
        // non-matching photos into own matches, and it must not force rematching
        // every other Event member.
        if let ownMatchesRevision = revisions.ownMatches {
            let previousOwnRevision = state.sourceOwnMatchesRevision
                ?? previouslyStoredCombined?.ownMatches
            if let previous = previousOwnRevision {
                if previous != ownMatchesRevision {
                    state.removeRecipientCursor(userId: currentUserId)
                }
            } else if state.recipientCursor(userId: currentUserId) != nil {
                // One-time safe migration for a pre-v5 state that had an own
                // cursor but no dedicated own preference generation.
                state.removeRecipientCursor(userId: currentUserId)
            }
            state.sourceOwnMatchesRevision = ownMatchesRevision
        }

        let ambiguityRevision = Self.ambiguityRosterRevision(participants)
        if let previous = state.rosterAmbiguityRevision,
           previous != ambiguityRevision {
            state.markAllRecipientEvaluationsStale()
        }
        state.rosterAmbiguityRevision = ambiguityRevision

        let matchableRecipients = participants.filter { participant in
            Self.isMatchable(participant)
                && (includeOwnMatches || participant.userId != currentUserId)
        }
        let activeRecipientIds = Set(matchableRecipients.map(\.userId))
        let matchableRecipientByUser = Dictionary(
            matchableRecipients.map { ($0.userId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        state.retainRecipientCursors(for: activeRecipientIds)

        for participant in matchableRecipients {
            state.reconcileRecipient(
                userId: participant.userId,
                membershipEpoch: AutomaticSyncIdentityScope.participantEpoch(participant),
                faceIdentityId: participant.stableFaceIdentityId,
                faceProfileRevision: participant.faceProfileRevision
            )
        }

        // One asset can have work for many recipients; run FaceMatcher once
        // against the full current roster, then advance all pending cursors from
        // that single ambiguity-aware decision.
        let pendingAssets = assets.filter { asset in
            if state.corpusRecord(for: asset.id) == nil { return true }
            return !state.pendingRecipientUserIds(
                for: asset.id,
                among: activeRecipientIds
            ).isEmpty
        }

        let configuredCap = max(0, values.maxAssetsPerSyncBatch)
        let passCap = min(configuredCap, Self.currentSafetyBatchCap())
        let toProcess = Array(pendingAssets.prefix(passCap))
        let remainingAfterPass = max(0, pendingAssets.count - toProcess.count)
        let fullMatchableRosterCount = participants.filter(Self.isMatchable).count

        Log.scanner.notice(
            "Scan diagnostics begin assets=\(assets.count, privacy: .public) corpus=\(state.corpusCount, privacy: .public) planned=\(pendingAssets.count, privacy: .public) roster=\(participants.count, privacy: .public) matchable=\(fullMatchableRosterCount, privacy: .public) recipients=\(matchableRecipients.count, privacy: .public) includeOwn=\(includeOwnMatches, privacy: .public)"
        )

        if toProcess.isEmpty {
            state.lastSyncedAt = clock.now()
            scanStateStore.save(state)
            Log.scanner.notice(
                "Scan diagnostics caught-up assets=\(assets.count, privacy: .public) corpus=\(state.corpusCount, privacy: .public) remaining=\(remainingAfterPass, privacy: .public)"
            )
            return Summary(
                scanned: 0,
                matchedPhotos: 0,
                remaining: remainingAfterPass,
                alreadyCaughtUp: remainingAfterPass == 0
            )
        }

        let matcher = FaceMatcher(config: values)
        let totalThisPass = toProcess.count
        var matchedCount = 0
        var completedCount = 0
        var failedCount = 0
        var passDiagnostics = PassDiagnostics()

        for asset in toProcess {
            try Task.checkCancellation()
            try Self.checkDeviceSafety()

            do {
                var workingImageData: Data?
                var corpusRecord = state.corpusRecord(for: asset.id)

                if corpusRecord == nil {
                    let working = try await photoLibrary.imageData(
                        for: asset.id,
                        maxPixelSize: max(values.thumbnailMaxPixelSize, 2048)
                    )
                    workingImageData = working
                    try Task.checkCancellation()

                    let detected = try await faceDetection.detectFaces(in: working)
                    let cached = PhotoCorpusRecord(
                        assetId: asset.id,
                        creationDate: asset.creationDate,
                        faces: detected.map { CachedPhotoFace($0) },
                        processedAt: clock.now()
                    )
                    state.cache(cached)
                    corpusRecord = cached
                    passDiagnostics.newlyProcessedAssets += 1

                    // Persist the expensive on-device extraction before any
                    // network publication. A cancellation, background expiry or
                    // transient upload failure can then retry from cached faces.
                    scanStateStore.save(state)
                } else {
                    passDiagnostics.cachedRematchAssets += 1
                }

                guard let corpusRecord else {
                    throw AppError.decoding("photo corpus record was not created")
                }

                let pendingRecipientIds = state.pendingRecipientUserIds(
                    for: asset.id,
                    among: activeRecipientIds
                )

                if !pendingRecipientIds.isEmpty {
                    // Preserve knowledge of the last successful positive while a
                    // stale result is being re-evaluated. If the full current
                    // roster now makes that recipient negative/ambiguous, the
                    // server must explicitly revoke the old appearance.
                    let previouslyPositiveRecipientIds = Set(pendingRecipientIds.filter { userId in
                        state.recipientCursor(userId: userId)?.wasMatched(asset.id) == true
                    })

                    let matchResult = matcher.appearancesWithDiagnostics(
                        in: corpusRecord.faces.map(\.detectedFace),
                        // Full roster is intentional. Matching only the changed
                        // recipient would bypass the cross-person ambiguity margin.
                        participants: participants
                    )
                    let ownFiltered = includeOwnMatches
                        ? 0
                        : matchResult.appearances.filter { $0.participantUserId == currentUserId }.count
                    passDiagnostics.record(matchResult.diagnostics, ownFiltered: ownFiltered)

                    let positiveAppearances = matchResult.appearances.filter {
                        pendingRecipientIds.contains($0.participantUserId)
                            && (includeOwnMatches || $0.participantUserId != currentUserId)
                    }
                    let positiveRecipientIds = Set(positiveAppearances.map(\.participantUserId))
                    let removalRecipientIds = previouslyPositiveRecipientIds.subtracting(positiveRecipientIds)

                    var recipientRemovals: [PhotoMatch.RecipientContext] = []
                    recipientRemovals.reserveCapacity(removalRecipientIds.count)
                    for userId in removalRecipientIds.sorted() {
                        guard let participant = matchableRecipientByUser[userId] else {
                            throw AppError.decoding("pending recipient disappeared from the current matching roster")
                        }
                        recipientRemovals.append(PhotoMatch.RecipientContext(
                            participantUserId: participant.userId,
                            recipientMembershipId: participant.membershipId,
                            faceIdentityId: participant.stableFaceIdentityId,
                            faceProfileRevision: participant.faceProfileRevision
                        ))
                    }

                    if !positiveAppearances.isEmpty || !recipientRemovals.isEmpty {
                        try Task.checkCancellation()
                        let thumbnail: Data
                        if positiveAppearances.isEmpty {
                            // A removal-only reconciliation does not need to read
                            // or upload the image again; FirebaseMatchRepository
                            // performs an authenticated metadata-only update.
                            thumbnail = Data()
                        } else {
                            let working: Data
                            if let workingImageData {
                                working = workingImageData
                            } else {
                                working = try await photoLibrary.imageData(
                                    for: asset.id,
                                    maxPixelSize: max(values.thumbnailMaxPixelSize, 2048)
                                )
                            }
                            thumbnail = try thumbnailEncoder.encodeJPEG(
                                from: working,
                                maxPixelSize: values.thumbnailMaxPixelSize,
                                quality: values.thumbnailJPEGQuality
                            )
                        }

                        let match = PhotoMatch(
                            eventId: event.id,
                            ownerUserId: currentUserId,
                            sourceInstallationId: sourceInstallationId,
                            sourceMembershipId: sourceMembershipId,
                            assetLocalId: asset.id,
                            appearances: positiveAppearances,
                            recipientRemovals: recipientRemovals,
                            capturedAt: asset.creationDate,
                            matchedAt: clock.now(),
                            useSourceScopedIdentity: true
                        )
                        try await matches.upload(match: match, thumbnailJPEG: thumbnail)
                        if !positiveAppearances.isEmpty {
                            matchedCount += 1
                        }
                    }

                    // Advance cursor outcomes only after any required publication
                    // or removal has succeeded. Failed backend reconciliation
                    // therefore remains retryable with the previous positive bit.
                    for userId in pendingRecipientIds {
                        state.markRecipientEvaluation(
                            userId: userId,
                            assetId: asset.id,
                            matched: positiveRecipientIds.contains(userId)
                        )
                    }
                }

                // If there are no recipients yet, completing the corpus record is
                // still useful work. A later member gets a pending cursor over it.
                completedCount += 1
            } catch is CancellationError {
                state.lastSyncedAt = clock.now()
                scanStateStore.save(state)
                throw AppError.syncCancelled
            } catch let error as AppError where error == .deviceTooWarm {
                state.lastSyncedAt = clock.now()
                scanStateStore.save(state)
                throw error
            } catch {
                failedCount += 1
                Log.scanner.error(
                    "Scan asset skipped category=\(Self.diagnosticErrorCategory(error), privacy: .public)"
                )
            }

            let attemptedThisPass = completedCount + failedCount
            onProgress?(SyncProgress(
                phase: .scanning,
                checked: completedCount,
                matched: matchedCount,
                remaining: (totalThisPass - attemptedThisPass) + remainingAfterPass + failedCount
            ))
            await Task.yield()
        }

        let totalRemaining = remainingAfterPass + failedCount
        onProgress?(SyncProgress(
            phase: .finishing,
            checked: completedCount,
            matched: matchedCount,
            remaining: totalRemaining
        ))
        state.lastSyncedAt = clock.now()
        scanStateStore.save(state)

        Log.scanner.notice(
            "Scan diagnostics end checked=\(completedCount, privacy: .public) matchedPhotos=\(matchedCount, privacy: .public) failed=\(failedCount, privacy: .public) corpusNew=\(passDiagnostics.newlyProcessedAssets, privacy: .public) corpusReused=\(passDiagnostics.cachedRematchAssets, privacy: .public) faces=\(passDiagnostics.detectedFaces, privacy: .public) sizeRejected=\(passDiagnostics.sizeRejectedFaces, privacy: .public) eligibleFaces=\(passDiagnostics.eligibleFaces, privacy: .public) acceptedFaces=\(passDiagnostics.acceptedFaces, privacy: .public) belowThreshold=\(passDiagnostics.belowThresholdFaces, privacy: .public) ambiguous=\(passDiagnostics.ambiguityRejectedFaces, privacy: .public) ownFiltered=\(passDiagnostics.ownAppearancesFiltered, privacy: .public) remaining=\(totalRemaining, privacy: .public)"
        )

        return Summary(
            scanned: completedCount,
            matchedPhotos: matchedCount,
            remaining: totalRemaining,
            alreadyCaughtUp: totalRemaining == 0
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
