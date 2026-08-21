import Foundation

/// One unit of local/in-memory erasure work. The live Firebase repositories
/// delegate destructive cascades to authenticated backend callables so account
/// and biometric cleanup cannot be interrupted between client-side steps.
public enum ErasureOperation: Equatable, Sendable {
    case deleteFaceProfile(userId: String)
    case removeEventMembership(eventId: String, userId: String)
    case deleteUserDocument(userId: String)
}

/// Retained for deterministic unit tests and development repositories.
public enum ErasurePlanner {
    public static func planDeleteFaceProfile(userId: String) -> [ErasureOperation] {
        [.deleteFaceProfile(userId: userId)]
    }

    public static func planDeleteAccount(userId: String, memberEventIds: [String]) -> [ErasureOperation] {
        var ops: [ErasureOperation] = memberEventIds
            .sorted()
            .map { .removeEventMembership(eventId: $0, userId: userId) }
        ops.append(.deleteFaceProfile(userId: userId))
        ops.append(.deleteUserDocument(userId: userId))
        return ops
    }
}

/// Privacy erasure facade.
///
/// In live mode `FaceProfileStore.delete` and `UserDirectory.delete` are trusted
/// Cloud Function calls. The server owns the full cascade: event-scoped face
/// snapshots, photo appearances, authored shared previews, memberships, user
/// documents and (for account deletion) Firebase Auth identity.
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
        try await faceProfiles.delete(userId: userId)
    }

    public func deleteAccount(userId: String) async throws {
        if events is FirebaseEventRepository {
            try await users.delete(userId: userId)
            return
        }

        let memberEventIds = try await events.events(forUserId: userId).map(\.id)
        try await run(ErasurePlanner.planDeleteAccount(userId: userId, memberEventIds: memberEventIds))
    }

    /// Explicit plan execution remains available to unit tests and in-memory
    /// repositories. Production UI paths above use the server-owned cascades.
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
