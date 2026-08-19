import Foundation

/// Orchestrates event membership transitions. Firebase performs trusted
/// membership mutations through callable Functions; in-memory repositories keep
/// the same protocol-driven behavior for tests and development.
public struct EventMembershipService {
    private let repository: EventRepository
    private let config: ConfigProviding
    private let clock: Clock

    public init(repository: EventRepository, config: ConfigProviding, clock: Clock) {
        self.repository = repository
        self.config = config
        self.clock = clock
    }

    /// Creates the event and organizer membership. The Firebase repository's
    /// createEvent callable already creates the organizer membership/roster
    /// atomically, while in-memory repositories still need the explicit seed.
    public func create(event: Event, creator: User, faceProfile: FaceProfile) async throws {
        try await repository.createEvent(event)

        if repository is FirebaseEventRepository {
            return
        }

        try await addMembership(
            eventId: event.id,
            user: creator,
            faceProfile: faceProfile,
            role: .organizer
        )
    }

    /// Joins an existing event. For Firebase, do not read the private roster
    /// before joining: the trusted joinEvent callable is authoritative for
    /// idempotency, capacity and membership creation. That fixes the backwards
    /// "join first" permission failure for invite/code/QR entry.
    public func join(event: Event, user: User, faceProfile: FaceProfile) async throws {
        let values = config.current
        guard event.status == .active,
              EventLifecycle.status(for: event, clock: clock, config: values) != .expired else {
            throw AppError.eventExpired
        }

        if repository is FirebaseEventRepository {
            let member = EventMember(
                userId: user.id,
                role: .participant,
                joinedAt: clock.now(),
                sharingEnabled: true,
                lastSyncAt: nil,
                faceTemplateVersion: faceProfile.version
            )
            // FirebaseEventRepository.addMember delegates to the trusted server,
            // which also writes the participant roster entry atomically.
            try await repository.addMember(eventId: event.id, member: member)
            return
        }

        let current = try await repository.members(eventId: event.id)
        if current.contains(where: { $0.userId == user.id }) { return }
        guard current.count < values.maxParticipantsPerEvent else { throw AppError.eventFull }

        try await addMembership(
            eventId: event.id,
            user: user,
            faceProfile: faceProfile,
            role: .participant
        )
    }

    public func leave(eventId: String, userId: String) async throws {
        if repository is FirebaseEventRepository {
            // Use the managed path so member removal is authorized consistently
            // and current members receive the server-generated change notice.
            try await EventManagementClient.remove(eventId: eventId, userId: userId)
        } else {
            try await repository.removeMember(eventId: eventId, userId: userId)
        }
    }

    public func setSharing(eventId: String, userId: String, enabled: Bool) async throws {
        try await repository.setSharing(eventId: eventId, userId: userId, enabled: enabled)
    }

    private func addMembership(
        eventId: String,
        user: User,
        faceProfile: FaceProfile,
        role: EventMember.Role
    ) async throws {
        let now = clock.now()
        let member = EventMember(
            userId: user.id,
            role: role,
            joinedAt: now,
            sharingEnabled: true,
            lastSyncAt: nil,
            faceTemplateVersion: faceProfile.version
        )
        try await repository.addMember(eventId: eventId, member: member)

        let participant = EventParticipant(
            userId: user.id,
            displayName: user.displayName ?? "Someone",
            phoneNumber: user.phoneNumber,
            faceEmbedding: faceProfile.embedding,
            faceTemplates: faceProfile.templates,
            faceProfileVersion: faceProfile.version,
            joinedAt: now
        )
        try await repository.join(eventId: eventId, participant: participant)
    }
}
