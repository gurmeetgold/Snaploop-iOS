import XCTest
@testable import SnapLoop

@MainActor
final class IdentityGenerationTests: XCTestCase {
    private func user(_ id: String) -> User {
        User(
            id: id,
            phoneNumber: "+15555550100",
            displayName: "User",
            hasFaceProfile: false,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    func testSessionContextSurvivesSameAccountRefresh() {
        let original = user("user-a")
        let session = AppSession(user: original)
        let context = session.authenticatedExecutionContext
        XCTAssertNotNil(context)

        let refreshed = User(
            id: original.id,
            phoneNumber: original.phoneNumber,
            displayName: "Updated Name",
            hasFaceProfile: false,
            createdAt: original.createdAt
        )
        session.beginAuthenticatedSession(user: refreshed, faceProfile: nil, faceProfileResolved: true)

        XCTAssertEqual(session.authenticatedExecutionContext, context)
        XCTAssertTrue(context.map(session.isCurrent) ?? false)
    }

    func testSessionContextRotatesWhenAccountChanges() {
        let session = AppSession(user: user("user-a"))
        let old = session.authenticatedExecutionContext!

        session.beginAuthenticatedSession(user: user("user-b"), faceProfile: nil, faceProfileResolved: true)

        XCTAssertNotEqual(session.authenticatedExecutionContext, old)
        XCTAssertFalse(session.isCurrent(old))
        XCTAssertEqual(session.authenticatedExecutionContext?.userId, "user-b")
    }

    func testSignOutInvalidatesCapturedSessionContext() {
        let session = AppSession(user: user("user-a"))
        let oldGeneration = session.sessionGeneration
        let old = session.authenticatedExecutionContext!

        session.clearAuthenticatedSession()

        XCTAssertNil(session.authenticatedExecutionContext)
        XCTAssertNotEqual(session.sessionGeneration, oldGeneration)
        XCTAssertFalse(session.isCurrent(old))
    }

    func testAccountInstallationIdentityIsStablePerAccountAndSeparatedAcrossAccounts() {
        let store = InMemoryAccountInstallationIdentityStore()

        let firstA = store.id(for: "user-a")
        let secondA = store.id(for: "user-a")
        let firstB = store.id(for: "user-b")

        XCTAssertFalse(firstA.isEmpty)
        XCTAssertEqual(firstA, secondA)
        XCTAssertNotEqual(firstA, firstB)
    }

    func testResetInstallationRotatesAccountInstallationIdentity() {
        let store = InMemoryAccountInstallationIdentityStore()
        let before = store.id(for: "user-a")

        store.resetInstallation()
        let after = store.id(for: "user-a")

        XCTAssertNotEqual(before, after)
    }

    func testEventMemberMembershipIdIsBackwardCompatibleWhenAbsent() throws {
        let original = EventMember(
            userId: "member",
            membershipId: "membership-generation",
            role: .participant,
            joinedAt: Date(timeIntervalSince1970: 1),
            faceTemplateVersion: FaceModelPolicy.currentVersion
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "membershipId")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(EventMember.self, from: legacy)

        XCTAssertEqual(decoded.userId, original.userId)
        XCTAssertNil(decoded.membershipId)
    }

    func testEventParticipantCarriesMembershipGenerationWithoutChangingDisplayIdentity() {
        let participant = EventParticipant(
            userId: "member",
            membershipId: "membership-generation",
            displayName: "Member",
            faceIdentityId: "stable-face",
            faceEmbedding: FaceEmbedding(normalized: [1, 0, 0]),
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(participant.id, "member")
        XCTAssertEqual(participant.membershipId, "membership-generation")
        XCTAssertEqual(participant.stableFaceIdentityId, "stable-face")
    }
}
