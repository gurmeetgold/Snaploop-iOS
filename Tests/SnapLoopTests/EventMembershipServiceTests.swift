import XCTest
@testable import SnapLoop

final class EventMembershipServiceTests: XCTestCase {

    private let day: TimeInterval = 86_400

    private func user(_ id: String) -> User {
        User(id: id, phoneNumber: "+1555000\(id)", displayName: id, hasFaceProfile: true, createdAt: Date())
    }
    private func profile(_ id: String) -> FaceProfile {
        FaceProfile(userId: id, embedding: FaceEmbedding([1, 0, 0])!, version: 1, updatedAt: Date())
    }
    private func makeEvent(now: Date, status: EventStatus = .active) -> Event {
        Event(id: "e1", joinCode: "ABC234", inviteToken: String(repeating: "A", count: InviteToken.length),
              creatorUserId: "creator", name: "Trip",
              startsAt: now.addingTimeInterval(-day), endsAt: now.addingTimeInterval(day),
              status: status, createdAt: now)
    }

    func testCreateAddsOrganizerMembershipAndRoster() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let repo = InMemoryEventRepository()
        let svc = EventMembershipService(repository: repo, config: StaticConfigProvider(.default), clock: FixedClock(now))
        let event = makeEvent(now: now)

        try await svc.create(event: event, creator: user("creator"), faceProfile: profile("creator"))

        let members = try await repo.members(eventId: "e1")
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.role, .organizer)
        let roster = try await repo.participants(eventId: "e1")
        XCTAssertEqual(roster.map(\.userId), ["creator"])
    }

    func testJoinAddsParticipantAndIsIdempotent() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let repo = InMemoryEventRepository()
        let svc = EventMembershipService(repository: repo, config: StaticConfigProvider(.default), clock: FixedClock(now))
        let event = makeEvent(now: now)
        try await repo.createEvent(event)

        try await svc.join(event: event, user: user("b"), faceProfile: profile("b"))
        try await svc.join(event: event, user: user("b"), faceProfile: profile("b")) // repeat

        let members = try await repo.members(eventId: "e1")
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.role, .participant)
    }

    func testJoinRejectsExpiredEvent() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let repo = InMemoryEventRepository()
        let svc = EventMembershipService(repository: repo, config: StaticConfigProvider(.default), clock: FixedClock(now))
        // Event ended by organizer.
        let event = makeEvent(now: now, status: .endedByOrganizer)
        do {
            try await svc.join(event: event, user: user("b"), faceProfile: profile("b"))
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? AppError, .eventExpired)
        }
    }

    func testJoinEnforcesParticipantCap() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var config = RemoteConfigValues.default
        config.maxParticipantsPerEvent = 2
        let repo = InMemoryEventRepository()
        let svc = EventMembershipService(repository: repo, config: StaticConfigProvider(config), clock: FixedClock(now))
        let event = makeEvent(now: now)
        try await repo.createEvent(event)

        try await svc.join(event: event, user: user("a"), faceProfile: profile("a"))
        try await svc.join(event: event, user: user("b"), faceProfile: profile("b"))
        do {
            try await svc.join(event: event, user: user("c"), faceProfile: profile("c"))
            XCTFail("Expected event full")
        } catch {
            XCTAssertEqual(error as? AppError, .eventFull)
        }
    }

    func testLeaveRemovesMembershipAndRevokesEmbedding() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let repo = InMemoryEventRepository()
        let svc = EventMembershipService(repository: repo, config: StaticConfigProvider(.default), clock: FixedClock(now))
        let event = makeEvent(now: now)
        try await repo.createEvent(event)
        try await svc.join(event: event, user: user("b"), faceProfile: profile("b"))

        try await svc.leave(eventId: "e1", userId: "b")

        let members = try await repo.members(eventId: "e1")
        let roster = try await repo.participants(eventId: "e1")
        XCTAssertTrue(members.isEmpty)
        XCTAssertTrue(roster.isEmpty, "Leaving must revoke the embedding from the event roster")
    }
}
