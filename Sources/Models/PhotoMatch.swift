import Foundation

/// The result of matching one photo against the event roster: which
/// participants appear in it, and how confident we are. One `PhotoMatch` is
/// produced per matched photo per device and uploaded (thumbnail + this
/// metadata) — originals stay on the device until downloaded on demand.
public struct PhotoMatch: Identifiable, Equatable, Codable, Sendable {
    public let id: String                 // deterministic: "\(eventId):\(assetId)"
    public let eventId: String
    public let ownerUserId: String        // whose camera/library this came from
    public let assetLocalId: String       // PhotoKit id on the owner's device (for on-demand original)

    /// Participants detected in this photo, with per-participant confidence.
    public var appearances: [Appearance]

    public let capturedAt: Date           // photo creation date
    public let matchedAt: Date            // when the match was computed

    public var thumbnailPath: String?     // Storage path once uploaded

    public init(
        eventId: String,
        ownerUserId: String,
        assetLocalId: String,
        appearances: [Appearance],
        capturedAt: Date,
        matchedAt: Date,
        thumbnailPath: String? = nil
    ) {
        self.id = "\(eventId):\(assetLocalId)"
        self.eventId = eventId
        self.ownerUserId = ownerUserId
        self.assetLocalId = assetLocalId
        self.appearances = appearances
        self.capturedAt = capturedAt
        self.matchedAt = matchedAt
        self.thumbnailPath = thumbnailPath
    }

    /// One participant's presence in a photo.
    public struct Appearance: Equatable, Codable, Sendable {
        public let participantUserId: String
        public let confidence: Double     // cosine similarity of the winning face
        /// Stable server-issued biometric-subject ID. It survives a verified
        /// same-person Face Setup refresh and changes only after Face Setup is
        /// deleted and a new identity is enrolled.
        public let faceIdentityId: String?
        /// Audit-only revision of the exact template set used for this match.
        /// The backend verifies it when accepting a new match, but continued
        /// access is bound to `faceIdentityId`, not to this changing revision.
        public let faceProfileRevision: String
        /// User correction: a participant can mark a match "Not Me". Suppressed
        /// appearances stay recorded (for precision tuning) but never surface.
        public var dismissedByUser: Bool

        public init(
            participantUserId: String,
            confidence: Double,
            faceIdentityId: String? = nil,
            faceProfileRevision: String = "",
            dismissedByUser: Bool = false
        ) {
            self.participantUserId = participantUserId
            self.confidence = confidence
            self.faceIdentityId = faceIdentityId
            self.faceProfileRevision = faceProfileRevision
            self.dismissedByUser = dismissedByUser
        }
    }

    /// Participants who should see this photo in their "My Photos" feed
    /// (appearances they haven't dismissed).
    public var activeParticipantIds: [String] {
        appearances.filter { !$0.dismissedByUser }.map(\.participantUserId)
    }
}
