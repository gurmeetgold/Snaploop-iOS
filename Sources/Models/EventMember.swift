import Foundation

/// A user's membership in an event — the Firestore
/// `events/{eventId}/members/{userId}` document. Its mere existence is what
/// grants a user read access to the event (see the security rules), so joining
/// creates this document and leaving deletes it.
public struct EventMember: Identifiable, Equatable, Codable, Sendable {
    public var id: String { userId }

    public let userId: String
    public var role: Role
    public let joinedAt: Date

    /// User can pause their own participation ("Pause Sharing") without leaving.
    /// While false, this device stops syncing/matching for this event.
    public var sharingEnabled: Bool

    /// Timestamp of this member's last completed sync pass (UI: "Last synced…").
    public var lastSyncAt: Date?

    /// Which face-profile version this membership's cached embedding came from.
    /// Lets the event detect that a member re-took their selfie and refresh.
    public var faceTemplateVersion: Int

    public init(
        userId: String,
        role: Role,
        joinedAt: Date,
        sharingEnabled: Bool = true,
        lastSyncAt: Date? = nil,
        faceTemplateVersion: Int
    ) {
        self.userId = userId
        self.role = role
        self.joinedAt = joinedAt
        self.sharingEnabled = sharingEnabled
        self.lastSyncAt = lastSyncAt
        self.faceTemplateVersion = faceTemplateVersion
    }

    public enum Role: String, Codable, Sendable {
        case organizer
        case participant
        public var isOrganizer: Bool { self == .organizer }
    }
}
