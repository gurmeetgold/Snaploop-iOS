import Foundation

/// One unit of erasure work. Modeled explicitly so the *plan* is pure and
/// testable, separately from the I/O that carries it out.
public enum ErasureOperation: Equatable, Sendable {
    case deleteFaceProfile(userId: String)
    case removeEventMembership(eventId: String, userId: String)  // also revokes the event embedding
    case deleteUserDocument(userId: String)
}

/// Builds erasure plans. Pure — no side effects — so the cascade is auditable.
public enum ErasurePlanner {

    /// Deleting only the face profile: the embedding is removed; the user must
    /// redo face setup to participate in matching again. Memberships stay.
    public static func planDeleteFaceProfile(userId: String) -> [ErasureOperation] {
        [.deleteFaceProfile(userId: userId)]
    }

    /// Deleting the whole account cascades: leave every event (removing
    /// membership + revoking the event-side embedding), delete the face
    /// profile, then delete the user document. Photos the user *sourced* remain
    /// event property (documented tradeoff) — they are intentionally NOT in this
    /// plan.
    public static func planDeleteAccount(userId: String, memberEventIds: [String]) -> [ErasureOperation] {
        var ops: [ErasureOperation] = memberEventIds
            .sorted()
            .map { .removeEventMembership(eventId: $0, userId: userId) }
        ops.append(.deleteFaceProfile(userId: userId))
        ops.append(.deleteUserDocument(userId: userId))
        return ops
    }
}

/// Executes erasure plans against the repositories. Ordering matters: revoke
/// event embeddings and memberships first, then the profile, then the user doc,
/// so a partial failure never leaves the biometric template reachable.
public struct ErasureService {
    private let events: EventRepository
    private let faceProfiles: FaceProfileStore
    private let users: UserDirectory

    public init(events: EventRepository, faceProfiles: FaceProfileStore, users: UserDirectory) {
        self.events = events
        self.faceProfiles = faceProfiles
        self.users = users
    }

    public func deleteFaceProfile(userId: String) async throws {
        try await run(ErasurePlanner.planDeleteFaceProfile(userId: userId))
    }

    public func deleteAccount(userId: String) async throws {
        let eventIds = (try? await events.events(forUserId: userId).map(\.id)) ?? []
        try await run(ErasurePlanner.planDeleteAccount(userId: userId, memberEventIds: eventIds))
    }

    /// Executes a plan step by step.
    public func run(_ plan: [ErasureOperation]) async throws {
        for op in plan {
            switch op {
            case .deleteFaceProfile(let userId):
                try await faceProfiles.delete(userId: userId)
            case .removeEventMembership(let eventId, let userId):
                try await events.removeMember(eventId: eventId, userId: userId)
            case .deleteUserDocument(let userId):
                try await users.delete(userId: userId)
            }
        }
    }
}
