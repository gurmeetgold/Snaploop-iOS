import Foundation

/// A user's membership in an event — the Firestore
/// `events/{eventId}/members/{userId}` document. Existing `participant` raw
/// values remain unchanged for backward compatibility; the UI presents them as
/// "Member".
public struct EventMember: Identifiable, Equatable, Codable, Sendable {
    public var id: String { userId }

    public let userId: String
    public var role: Role
    public let joinedAt: Date
    public var sharingEnabled: Bool
    public var lastSyncAt: Date?
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
        case admin
        case participant

        public var isOrganizer: Bool { self == .organizer }
        public var isAdmin: Bool { self == .admin }
        public var canManageMembers: Bool { self == .organizer || self == .admin }

        public var displayName: String {
            switch self {
            case .organizer: return "Organizer"
            case .admin: return "Admin"
            case .participant: return "Member"
            }
        }
    }
}
