import Foundation

/// Orchestrates the two membership transitions — creating an event (organizer
/// joins) and joining an existing one (participant joins). Extracted from the
/// view layer so the rules (lifecycle gate, participant cap, roster seeding)
/// are unit-testable against an in-memory repository.
///
/// "Joining IS the consent": there is no per-photo approval. Adding the
/// membership + roster embedding here is the single consent action.
public struct EventMembershipService {

    private let repository: EventRepository
    private let config: ConfigProviding
    private let clock: Clock

    public init(repository: EventRepository, config: ConfigProviding, clock: Clock) {
        self.repository = repository
        self.config = config
        self.clock = clock
    }

    /// Creates the event and makes `creator` its organizer, seeding the matching
    /// roster with the creator's face embedding.
    public func create(event: Event, creator: User, faceProfile: FaceProfile) async throws {
        try await repository.createEvent(event)
        try await addMembership(
            eventId: event.id, user: creator, faceProfile: faceProfile, role: .organizer)
    }

    /// Joins an existing event as a participant. Enforces the lifecycle gate and
    /// participant cap before writing anything.
    public func join(event: Event, user: User, faceProfile: FaceProfile) async throws {
        let values = config.current

        // Can't join an event that's past its grace window or ended early.
        guard event.status == .active,
              EventLifecycle.status(for: event, clock: clock, config: values) != .expired else {
            throw AppError.eventExpired
        }

        let current = try await repository.members(eventId: event.id)
        if current.contains(where: { $0.userId == user.id }) { return } // idempotent
        guard current.count < values.maxParticipantsPerEvent else { throw AppError.eventFull }

        try await addMembership(
            eventId: event.id, user: user, faceProfile: faceProfile, role: .participant)
    }

    /// Leaves an event: removes membership and revokes the embedding from the
    /// event's roster (so other devices stop matching against this user).
    public func leave(eventId: String, userId: String) async throws {
        try await repository.removeMember(eventId: eventId, userId: userId)
    }

    public func setSharing(eventId: String, userId: String, enabled: Bool) async throws {
        try await repository.setSharing(eventId: eventId, userId: userId, enabled: enabled)
    }

    // MARK: - Private

    private func addMembership(
        eventId: String, user: User, faceProfile: FaceProfile, role: EventMember.Role
    ) async throws {
        let now = clock.now()
        let member = EventMember(
            userId: user.id, role: role, joinedAt: now,
            sharingEnabled: true, lastSyncAt: nil,
            faceTemplateVersion: faceProfile.version)
        try await repository.addMember(eventId: eventId, member: member)

        let participant = EventParticipant(
            userId: user.id, displayName: user.displayName ?? "Someone",
            faceEmbedding: faceProfile.embedding,
            faceProfileVersion: faceProfile.version, joinedAt: now)
        try await repository.join(eventId: eventId, participant: participant)
    }
}
