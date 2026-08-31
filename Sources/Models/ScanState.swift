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
/// Positive and negative results are deliberately tracked separately:
/// - a verified same-person Face Setup refresh keeps old positive matches but
///   clears negatives so an improved template can discover photos it missed;
/// - a new face identity or Event membership generation clears both sets;
/// - new corpus assets are simply absent from both sets and therefore pending.
public struct RecipientMatchCursor: Equatable, Codable, Sendable {
    public let userId: String
    public var membershipEpoch: String
    public var faceIdentityId: String
    public var faceProfileRevision: String
    public private(set) var positiveAssetIds: Set<String>
    public private(set) var negativeAssetIds: Set<String>

    public init(
        userId: String,
        membershipEpoch: String,
        faceIdentityId: String,
        faceProfileRevision: String,
        positiveAssetIds: Set<String> = [],
        negativeAssetIds: Set<String> = []
    ) {
        self.userId = userId
        self.membershipEpoch = membershipEpoch
        self.faceIdentityId = faceIdentityId
        self.faceProfileRevision = faceProfileRevision
        self.positiveAssetIds = positiveAssetIds
        self.negativeAssetIds = negativeAssetIds
    }

    public func hasEvaluated(_ assetId: String) -> Bool {
        positiveAssetIds.contains(assetId) || negativeAssetIds.contains(assetId)
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
            return
        }

        if faceProfileRevision != newFaceProfileRevision {
            faceProfileRevision = newFaceProfileRevision
            // Existing positives remain authorized for the same biometric
            // identity. Only old misses need another comparison.
            negativeAssetIds.removeAll(keepingCapacity: true)
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
    }

    public mutating func retainAssetIds(_ validIds: Set<String>) {
        positiveAssetIds.formIntersection(validIds)
        negativeAssetIds.formIntersection(validIds)
    }
}

/// Device-local scanner state.
///
/// `scannedAssetIds` is retained only to decode pre-Change-4 state and to keep
/// the pure legacy `ScanPlanner` API source-compatible. The live scanner no
/// longer treats it as a permanent "this photo is done" bit. Change 4 uses the
/// photo corpus plus per-recipient cursors instead.
public struct ScanState: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 2

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

    public var lastSyncedAt: Date?

    public init(
        eventId: String,
        scannedAssetIds: Set<String> = [],
        photoCorpus: [String: PhotoCorpusRecord] = [:],
        recipientCursors: [String: RecipientMatchCursor] = [:],
        sourceMembershipEpoch: String? = nil,
        lastSyncedAt: Date? = nil,
        schemaVersion: Int = ScanState.currentSchemaVersion
    ) {
        self.eventId = eventId
        self.schemaVersion = schemaVersion
        self.scannedAssetIds = scannedAssetIds
        self.photoCorpus = photoCorpus
        self.recipientCursors = recipientCursors
        self.sourceMembershipEpoch = sourceMembershipEpoch
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
        for userId in recipientCursors.keys {
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
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }
}
