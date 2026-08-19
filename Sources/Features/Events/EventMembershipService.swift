import Foundation

/// Orchestrates event membership transitions. Live Firebase builds route
/// security-sensitive mutations through trusted callable Functions; in-memory
/// development builds retain the protocol-based implementation.
public struct EventMembershipService {
    private let repository: EventRepository
    private let config: ConfigProviding
    private let clock: Clock

    public init(repository: EventRepository, config: ConfigProviding, clock: Clock) {
        self.repository = repository
        self.config = config
        self.clock = clock
    }

    public func create(event: Event, creator: User, faceProfile: FaceProfile) async throws {
        if AppEnvironment.useLiveServices {
            try await EventManagementClient.create(event)
            return
        }
        try await repository.createEvent(event)
        try await addMembership(
            eventId: event.id,
            user: creator,
            faceProfile: faceProfile,
            role: .organizer
        )
    }

    public func join(event: Event, user: User, faceProfile: FaceProfile) async throws {
        let values = config.current
        guard event.status == .active,
              EventLifecycle.status(for: event, clock: clock, config: values) != .expired else {
            throw AppError.eventExpired
        }

        if AppEnvironment.useLiveServices {
            // The server is authoritative for membership existence, capacity and
            // lifecycle. Crucially, no private roster read is required first.
            try await EventManagementClient.join(eventId: event.id)
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
        if AppEnvironment.useLiveServices {
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
