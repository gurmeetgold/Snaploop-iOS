import Foundation

/// Persistable representation of one detected face. Candidate photo-face
/// embeddings never leave the source device; they are cached only so a roster or
/// Face Setup change can be compared without decoding and embedding the photo
/// again.
public struct CachedPhotoFace: Equatable, Codable, Sendable {
    public let embedding: FaceEmbedding
    public let sizeFraction: Double

    public init(embedding: FaceEmbedding, sizeFraction: Double) {
        self.embedding = embedding
        self.sizeFraction = sizeFraction
    }

    public init(_ face: DetectedFace) {
        self.init(embedding: face.embedding, sizeFraction: face.sizeFraction)
    }

    public var detectedFace: DetectedFace {
        DetectedFace(embedding: embedding, sizeFraction: sizeFraction)
    }
}

/// One PhotoKit asset whose expensive face-detection/embedding pass has already
/// completed on this installation.
public struct PhotoCorpusRecord: Equatable, Codable, Sendable {
    public let assetId: String
    public let creationDate: Date
    public let faces: [CachedPhotoFace]
    public let processedAt: Date

    public init(assetId: String, creationDate: Date, faces: [CachedPhotoFace], processedAt: Date) {
        self.assetId = assetId
        self.creationDate = creationDate
        self.faces = faces
        self.processedAt = processedAt
    }
}

/// Per-recipient matching cursor for the local photo corpus.
///
/// Positive and negative outcomes are retained separately from whether they are
/// still current. This distinction is important for ambiguity-safe rematching:
/// when the Event roster or a same-person Face Setup revision changes, the old
/// outcome becomes stale and must be evaluated again against the full roster. We
/// keep the previous positive bit until that re-evaluation finishes so a newly
/// negative result can explicitly revoke an already-published recipient.
///
/// A new face identity or Event membership generation is a harder boundary: all
/// old outcomes are discarded because server authorization is generation-bound.
public struct RecipientMatchCursor: Equatable, Codable, Sendable {
    public let userId: String
    public var membershipEpoch: String
    public var faceIdentityId: String
    public var faceProfileRevision: String
    public private(set) var positiveAssetIds: Set<String>
    public private(set) var negativeAssetIds: Set<String>
    public private(set) var staleAssetIds: Set<String>

    public init(
        userId: String,
        membershipEpoch: String,
        faceIdentityId: String,
        faceProfileRevision: String,
        positiveAssetIds: Set<String> = [],
        negativeAssetIds: Set<String> = [],
        staleAssetIds: Set<String> = []
    ) {
        self.userId = userId
        self.membershipEpoch = membershipEpoch
        self.faceIdentityId = faceIdentityId
        self.faceProfileRevision = faceProfileRevision
        self.positiveAssetIds = positiveAssetIds
        self.negativeAssetIds = negativeAssetIds
        self.staleAssetIds = staleAssetIds
    }

    /// True only when the result exists and is valid for the current roster /
    /// template revision. A stale result intentionally appears pending.
    public func hasEvaluated(_ assetId: String) -> Bool {
        !staleAssetIds.contains(assetId)
            && (positiveAssetIds.contains(assetId) || negativeAssetIds.contains(assetId))
    }

    /// Last successfully published/local positive outcome, even if it has become
    /// stale and is awaiting re-evaluation. The coordinator uses this to know
    /// when a newly negative result must revoke server visibility.
    public func wasMatched(_ assetId: String) -> Bool {
        positiveAssetIds.contains(assetId)
    }

    public mutating func reconcile(
        membershipEpoch newMembershipEpoch: String,
        faceIdentityId newFaceIdentityId: String,
        faceProfileRevision newFaceProfileRevision: String
    ) {
        if membershipEpoch != newMembershipEpoch || faceIdentityId != newFaceIdentityId {
            membershipEpoch = newMembershipEpoch
            faceIdentityId = newFaceIdentityId
            faceProfileRevision = newFaceProfileRevision
            positiveAssetIds.removeAll(keepingCapacity: true)
            negativeAssetIds.removeAll(keepingCapacity: true)
            staleAssetIds.removeAll(keepingCapacity: true)
            return
        }

        if faceProfileRevision != newFaceProfileRevision {
            faceProfileRevision = newFaceProfileRevision
            // The biometric subject is the same, but template scores can change.
            // Re-evaluate both prior hits and misses so a better Face Setup can
            // discover misses *and* retract an old false positive safely.
            markAllEvaluatedStale()
        }
    }

    public mutating func mark(assetId: String, matched: Bool) {
        if matched {
            positiveAssetIds.insert(assetId)
            negativeAssetIds.remove(assetId)
        } else {
            negativeAssetIds.insert(assetId)
            positiveAssetIds.remove(assetId)
        }
        staleAssetIds.remove(assetId)
    }

    /// Sharing OFF removes this source's server publication rows. On OFF→ON the
    /// old positive bits should be replayed as fresh publications, not treated as
    /// stale server rows that require a removal decision.
    public mutating func clearPositives() {
        positiveAssetIds.removeAll(keepingCapacity: true)
    }

    public mutating func clearNegatives() {
        negativeAssetIds.removeAll(keepingCapacity: true)
    }

    public mutating func markAllEvaluatedStale() {
        staleAssetIds.formUnion(positiveAssetIds)
        staleAssetIds.formUnion(negativeAssetIds)
    }

    public mutating func retainAssetIds(_ validIds: Set<String>) {
        positiveAssetIds.formIntersection(validIds)
        negativeAssetIds.formIntersection(validIds)
        staleAssetIds.formIntersection(validIds)
    }

    // MARK: Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case userId
        case membershipEpoch
        case faceIdentityId
        case faceProfileRevision
        case positiveAssetIds
        case negativeAssetIds
        case staleAssetIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        membershipEpoch = try container.decode(String.self, forKey: .membershipEpoch)
        faceIdentityId = try container.decode(String.self, forKey: .faceIdentityId)
        faceProfileRevision = try container.decode(String.self, forKey: .faceProfileRevision)
        positiveAssetIds = try container.decodeIfPresent(Set<String>.self, forKey: .positiveAssetIds) ?? []
        negativeAssetIds = try container.decodeIfPresent(Set<String>.self, forKey: .negativeAssetIds) ?? []
        staleAssetIds = try container.decodeIfPresent(Set<String>.self, forKey: .staleAssetIds) ?? []
    }
}

/// Device-local scanner state.
///
/// `scannedAssetIds` is retained only to decode pre-Change-4 state and to keep
/// the pure legacy `ScanPlanner` API source-compatible. The live scanner no
/// longer treats it as a permanent "this photo is done" bit. Change 4 uses the
/// photo corpus plus per-recipient cursors instead.
public struct ScanState: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 4

    public let eventId: String
    public var schemaVersion: Int

    /// Legacy pre-Change-4 state. Do not use this to decide whether a current
    /// recipient still needs matching.
    public private(set) var scannedAssetIds: Set<String>

    /// Expensive photo-face processing cache, keyed by PhotoKit local identifier.
    public private(set) var photoCorpus: [String: PhotoCorpusRecord]

    /// Matching progress for each currently matchable Event recipient.
    public private(set) var recipientCursors: [String: RecipientMatchCursor]

    /// Source Event membership generation used when the cursors were last valid.
    /// A leave/rejoin clears recipient cursors but preserves the local corpus.
    public var sourceMembershipEpoch: String?

    /// Source-sharing publication generation. Sharing OFF deletes this account's
    /// server photo rows. When sharing comes back ON with a new revision, only
    /// prior positive cursor results are invalidated so cached photos republish;
    /// negatives and expensive photo-face extraction remain valid.
    public var sourceSharingRevision: String?

    /// Revision of every identity that participates in FaceMatcher's ambiguity
    /// comparison. Any roster change can change either direction of a decision:
    /// a miss can become a hit, and an old hit can become ambiguous when a new
    /// similar-looking member joins. Therefore existing outcomes are marked stale
    /// and re-evaluated from cached photo-face embeddings.
    public var rosterAmbiguityRevision: String?

    public var lastSyncedAt: Date?

    public init(
        eventId: String,
        scannedAssetIds: Set<String> = [],
        photoCorpus: [String: PhotoCorpusRecord] = [:],
        recipientCursors: [String: RecipientMatchCursor] = [:],
        sourceMembershipEpoch: String? = nil,
        sourceSharingRevision: String? = nil,
        rosterAmbiguityRevision: String? = nil,
        lastSyncedAt: Date? = nil,
        schemaVersion: Int = ScanState.currentSchemaVersion
    ) {
        self.eventId = eventId
        self.schemaVersion = schemaVersion
        self.scannedAssetIds = scannedAssetIds
        self.photoCorpus = photoCorpus
        self.recipientCursors = recipientCursors
        self.sourceMembershipEpoch = sourceMembershipEpoch
        self.sourceSharingRevision = sourceSharingRevision
        self.rosterAmbiguityRevision = rosterAmbiguityRevision
        self.lastSyncedAt = lastSyncedAt
    }

    // MARK: Legacy compatibility

    public func hasScanned(_ assetId: String) -> Bool {
        scannedAssetIds.contains(assetId)
    }

    public mutating func markScanned(_ ids: some Sequence<String>) {
        scannedAssetIds.formUnion(ids)
    }

    public mutating func retainScannedAssetIds(_ validIds: Set<String>) {
        scannedAssetIds.formIntersection(validIds)
    }

    // MARK: Change 4 corpus + cursors

    public func corpusRecord(for assetId: String) -> PhotoCorpusRecord? {
        photoCorpus[assetId]
    }

    public mutating func cache(_ record: PhotoCorpusRecord) {
        photoCorpus[record.assetId] = record
    }

    public func recipientCursor(userId: String) -> RecipientMatchCursor? {
        recipientCursors[userId]
    }

    public mutating func reconcileRecipient(
        userId: String,
        membershipEpoch: String,
        faceIdentityId: String,
        faceProfileRevision: String
    ) {
        if var existing = recipientCursors[userId] {
            existing.reconcile(
                membershipEpoch: membershipEpoch,
                faceIdentityId: faceIdentityId,
                faceProfileRevision: faceProfileRevision
            )
            recipientCursors[userId] = existing
        } else {
            recipientCursors[userId] = RecipientMatchCursor(
                userId: userId,
                membershipEpoch: membershipEpoch,
                faceIdentityId: faceIdentityId,
                faceProfileRevision: faceProfileRevision
            )
        }
    }

    public mutating func retainRecipientCursors(for activeUserIds: Set<String>) {
        recipientCursors = recipientCursors.filter { activeUserIds.contains($0.key) }
    }

    public mutating func resetRecipientCursors() {
        recipientCursors.removeAll(keepingCapacity: true)
    }

    public var hasPositiveRecipientEvaluations: Bool {
        recipientCursors.values.contains { !$0.positiveAssetIds.isEmpty }
    }

    public mutating func clearPositiveRecipientEvaluations() {
        for userId in Array(recipientCursors.keys) {
            guard var cursor = recipientCursors[userId] else { continue }
            cursor.clearPositives()
            recipientCursors[userId] = cursor
        }
    }

    public mutating func clearNegativeRecipientEvaluations() {
        for userId in Array(recipientCursors.keys) {
            guard var cursor = recipientCursors[userId] else { continue }
            cursor.clearNegatives()
            recipientCursors[userId] = cursor
        }
    }

    public mutating func markAllRecipientEvaluationsStale() {
        for userId in Array(recipientCursors.keys) {
            guard var cursor = recipientCursors[userId] else { continue }
            cursor.markAllEvaluatedStale()
            recipientCursors[userId] = cursor
        }
    }

    public func pendingRecipientUserIds(for assetId: String, among userIds: Set<String>) -> Set<String> {
        Set(userIds.filter { userId in
            guard let cursor = recipientCursors[userId] else { return true }
            return !cursor.hasEvaluated(assetId)
        })
    }

    public mutating func markRecipientEvaluation(userId: String, assetId: String, matched: Bool) {
        guard var cursor = recipientCursors[userId] else { return }
        cursor.mark(assetId: assetId, matched: matched)
        recipientCursors[userId] = cursor
    }

    /// Prunes assets that PhotoKit no longer returns for the Event's current
    /// date/permission window. This handles photo deletion, limited-library
    /// access changes and Event date edits without invalidating the rest of the
    /// corpus.
    public mutating func retainCurrentAssets(_ validIds: Set<String>) {
        scannedAssetIds.formIntersection(validIds)
        photoCorpus = photoCorpus.filter { validIds.contains($0.key) }
        for userId in Array(recipientCursors.keys) {
            guard var cursor = recipientCursors[userId] else { continue }
            cursor.retainAssetIds(validIds)
            recipientCursors[userId] = cursor
        }
    }

    public var corpusCount: Int { photoCorpus.count }

    /// Compatibility diagnostic. Once a Change-4 corpus exists, it is the
    /// meaningful count of locally processed photo assets.
    public var scannedCount: Int {
        photoCorpus.isEmpty ? scannedAssetIds.count : photoCorpus.count
    }

    // MARK: Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case eventId
        case schemaVersion
        case scannedAssetIds
        case photoCorpus
        case recipientCursors
        case sourceMembershipEpoch
        case sourceSharingRevision
        case rosterAmbiguityRevision
        case lastSyncedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try container.decode(String.self, forKey: .eventId)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        scannedAssetIds = try container.decodeIfPresent(Set<String>.self, forKey: .scannedAssetIds) ?? []
        photoCorpus = try container.decodeIfPresent([String: PhotoCorpusRecord].self, forKey: .photoCorpus) ?? [:]
        recipientCursors = try container.decodeIfPresent([String: RecipientMatchCursor].self, forKey: .recipientCursors) ?? [:]
        sourceMembershipEpoch = try container.decodeIfPresent(String.self, forKey: .sourceMembershipEpoch)
        sourceSharingRevision = try container.decodeIfPresent(String.self, forKey: .sourceSharingRevision)
        rosterAmbiguityRevision = try container.decodeIfPresent(String.self, forKey: .rosterAmbiguityRevision)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }
}
