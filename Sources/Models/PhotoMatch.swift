import Foundation

/// The result of matching one photo against the event roster: which
/// participants appear in it, and how confident we are. Source installation and
/// membership metadata make the same PhotoKit local identifier safe across
/// multiple devices signed into the same account.
public struct PhotoMatch: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let eventId: String
    public let ownerUserId: String        // whose camera/library this came from
    /// Pseudonymous account+installation source identity. It is never an
    /// authentication credential. Optional for legacy stored matches.
    public let sourceInstallationId: String?
    /// Server-issued generation of the source user's current event membership.
    /// Used by the commit barrier to reject work produced before leave/rejoin.
    /// Optional only for legacy stored matches during migration.
    public let sourceMembershipId: String?
    public let assetLocalId: String       // PhotoKit id on the source device

    /// Participants detected in this photo, with per-participant confidence.
    public var appearances: [Appearance]

    /// Recipients that were previously published for this source photo but whose
    /// latest ambiguity-aware re-evaluation is now negative. These are transient
    /// publication instructions, not Gallery content. The backend validates the
    /// supplied membership/identity/revision before removing an old appearance so
    /// stale scans cannot revoke a newer generation's valid match.
    public let recipientRemovals: [RecipientContext]?

    public let capturedAt: Date           // photo creation date
    public let matchedAt: Date            // when the match was computed

    public var thumbnailPath: String?     // Storage path once uploaded

    public init(
        id explicitId: String? = nil,
        eventId: String,
        ownerUserId: String,
        sourceInstallationId: String? = nil,
        sourceMembershipId: String? = nil,
        assetLocalId: String,
        appearances: [Appearance],
        recipientRemovals: [RecipientContext]? = nil,
        capturedAt: Date,
        matchedAt: Date,
        thumbnailPath: String? = nil,
        useSourceScopedIdentity: Bool = false
    ) {
        let normalizedSource = sourceInstallationId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.sourceInstallationId = normalizedSource
        if let explicitId = explicitId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            // Trusted repository decoding preserves the server-issued identity.
            self.id = explicitId
        } else if useSourceScopedIdentity, let normalizedSource {
            self.id = "\(eventId):\(normalizedSource):\(assetLocalId)"
        } else {
            // Legacy constructors remain source-compatible for already persisted
            // data and older tests. Change-4 scanner work opts in explicitly.
            self.id = "\(eventId):\(assetLocalId)"
        }
        self.eventId = eventId
        self.ownerUserId = ownerUserId
        self.sourceMembershipId = sourceMembershipId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.assetLocalId = assetLocalId
        self.appearances = appearances
        self.recipientRemovals = recipientRemovals?.isEmpty == false ? recipientRemovals : nil
        self.capturedAt = capturedAt
        self.matchedAt = matchedAt
        self.thumbnailPath = thumbnailPath
    }

    /// True only for the Change-4 identity contract. Repositories use this to
    /// request idempotent appearance merging instead of legacy full replacement.
    public var isSourceScopedIdentity: Bool {
        guard let sourceInstallationId else { return false }
        return id == "\(eventId):\(sourceInstallationId):\(assetLocalId)"
    }

    /// One participant's presence in a photo.
    public struct Appearance: Equatable, Codable, Sendable {
        public let participantUserId: String
        /// Server-issued generation of the recipient's current event membership.
        /// A later leave/rejoin gets another value, preventing stale match work
        /// from being authorized for the new participation. Optional for legacy
        /// stored matches during migration.
        public let recipientMembershipId: String?
        public let confidence: Double     // cosine similarity of the winning face
        /// Stable server-issued biometric-subject ID. It survives a verified
        /// same-person Face Setup refresh and changes only after Face Setup is
        /// deleted and a new identity is enrolled.
        public let faceIdentityId: String?
        /// Audit revision of the exact template set used for this match. The
        /// backend verifies it when accepting new matching work.
        public let faceProfileRevision: String
        /// Legacy compatibility field. New matches use the server's explicit
        /// dismissal tombstone rather than relying on this row-level flag.
        public var dismissedByUser: Bool

        public init(
            participantUserId: String,
            recipientMembershipId: String? = nil,
            confidence: Double,
            faceIdentityId: String? = nil,
            faceProfileRevision: String = "",
            dismissedByUser: Bool = false
        ) {
            self.participantUserId = participantUserId
            self.recipientMembershipId = recipientMembershipId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            self.confidence = confidence
            self.faceIdentityId = faceIdentityId
            self.faceProfileRevision = faceProfileRevision
            self.dismissedByUser = dismissedByUser
        }
    }

    /// Current recipient generation used when explicitly retracting a previously
    /// published positive after a roster/template re-evaluation.
    public struct RecipientContext: Equatable, Codable, Sendable {
        public let participantUserId: String
        public let recipientMembershipId: String?
        public let faceIdentityId: String
        public let faceProfileRevision: String

        public init(
            participantUserId: String,
            recipientMembershipId: String? = nil,
            faceIdentityId: String,
            faceProfileRevision: String
        ) {
            self.participantUserId = participantUserId
            self.recipientMembershipId = recipientMembershipId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            self.faceIdentityId = faceIdentityId
            self.faceProfileRevision = faceProfileRevision
        }
    }

    /// Participants who should see this photo in their "My Photos" feed.
    /// `dismissedByUser` is retained only for legacy data compatibility.
    public var activeParticipantIds: [String] {
        appearances.filter { !$0.dismissedByUser }.map(\.participantUserId)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
