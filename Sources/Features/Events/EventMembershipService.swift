import Foundation

/// Orchestrates event membership transitions. In live Firebase builds the
/// trusted `joinEvent` callable is the authority for capacity, lifecycle and
/// idempotency checks; a non-member must never need permission to read the
/// private member roster before that callable is allowed to join them.
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
        try await repository.createEvent(event)
        // Live Firebase createEvent already creates organizer membership and the
        // participant snapshot atomically. The duplicate calls below are
        // idempotent and keep in-memory/dev repositories behaving the same.
        try await addMembership(
            eventId: event.id, user: creator, faceProfile: faceProfile, role: .organizer)
    }

    public func join(event: Event, user: User, faceProfile: FaceProfile) async throws {
        let values = config.current
        guard event.status == .active,
              EventLifecycle.status(for: event, clock: clock, config: values) != .expired else {
            throw AppError.eventExpired
        }

        // If roster access is already authorized (the user is already a member,
        // or a dev repository is in use), preserve the local idempotency/cap
        // checks. A permission error for a genuine non-member is intentionally
        // ignored so the trusted joinEvent callable can create membership.
        if let current = try? await repository.members(eventId: event.id) {
            if current.contains(where: { $0.userId == user.id }) { return }
            guard current.count < values.maxParticipantsPerEvent else { throw AppError.eventFull }
        }

        try await addMembership(
            eventId: event.id, user: user, faceProfile: faceProfile, role: .participant)
    }

    public func leave(eventId: String, userId: String) async throws {
        try await repository.removeMember(eventId: eventId, userId: userId)
    }

    public func setSharing(eventId: String, userId: String, enabled: Bool) async throws {
        try await repository.setSharing(eventId: eventId, userId: userId, enabled: enabled)
    }

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
            phoneNumber: user.phoneNumber,
            faceEmbedding: faceProfile.embedding,
            faceTemplates: faceProfile.templates,
            faceProfileVersion: faceProfile.version, joinedAt: now)
        try await repository.join(eventId: eventId, participant: participant)
    }
}
