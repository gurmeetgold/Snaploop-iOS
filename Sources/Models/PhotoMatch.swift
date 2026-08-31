import Foundation

/// The result of matching one photo against the event roster: which
/// participants appear in it, and how confident we are. Source installation and
/// membership metadata are carried now; source-scoped photo IDs are activated
/// explicitly with the photo-corpus migration so a release update cannot create
/// parallel duplicates for every legacy scanned asset.
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
            // Trusted repository decoding preserves the server-issued identity,
            // including future source-scoped IDs. New local matches omit this.
            self.id = explicitId
        } else if useSourceScopedIdentity, let normalizedSource {
            self.id = "\(eventId):\(normalizedSource):\(assetLocalId)"
        } else {
            // Preserve the legacy ID during Change 2. The upcoming corpus/cursor
            // migration turns on the source-scoped identity in one coordinated
            // step with scanner state, preventing duplicate parallel documents.
            self.id = "\(eventId):\(assetLocalId)"
        }
        self.eventId = eventId
        self.ownerUserId = ownerUserId
        self.sourceMembershipId = sourceMembershipId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.assetLocalId = assetLocalId
        self.appearances = appearances
        self.capturedAt = capturedAt
        self.matchedAt = matchedAt
        self.thumbnailPath = thumbnailPath
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
        /// Legacy compatibility field. The current product has no "Not Me"
        /// interaction; new matching architecture does not depend on this flag.
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

    /// Participants who should see this photo in their "My Photos" feed.
    /// `dismissedByUser` is retained only for legacy data compatibility.
    public var activeParticipantIds: [String] {
        appearances.filter { !$0.dismissedByUser }.map(\.participantUserId)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
