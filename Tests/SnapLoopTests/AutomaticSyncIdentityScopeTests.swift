import XCTest
@testable import SnapLoop

final class AutomaticSyncIdentityScopeTests: XCTestCase {
    private func event() -> Event {
        Event(
            id: "event",
            joinCode: "ABC234",
            creatorUserId: "source",
            name: "Event",
            startsAt: Date(timeIntervalSince1970: 100),
            endsAt: Date(timeIntervalSince1970: 200),
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 75)
        )
    }

    private func participant(
        membershipId: String?,
        joinedAt: Date = Date(timeIntervalSince1970: 60),
        revisionLabel: String = "r1"
    ) -> EventParticipant {
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        return EventParticipant(
            userId: "recipient",
            membershipId: membershipId,
            displayName: "Recipient",
            faceIdentityId: "stable-face",
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(
                    id: "\(revisionLabel)-center",
                    embedding: embedding,
                    pose: .center,
                    quality: 1,
                    createdAt: joinedAt
                )
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: joinedAt
        )
    }

    func testAutomaticSyncPersistenceIsSeparatedByAccountInstallation() throws {
        let eventId = "same-event"
        let first = try XCTUnwrap(AutomaticSyncIdentityScope.storageKey(
            prefix: "sync.",
            sourceInstallationId: "account-install-A",
            eventId: eventId
        ))
        let second = try XCTUnwrap(AutomaticSyncIdentityScope.storageKey(
            prefix: "sync.",
            sourceInstallationId: "account-install-B",
            eventId: eventId
        ))

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("firebase-user"))
        XCTAssertFalse(second.contains("firebase-user"))
    }

    func testEmptyInstallationIdentityFailsClosedInsteadOfCreatingSharedKey() {
        XCTAssertNil(AutomaticSyncIdentityScope.storageKey(
            prefix: "sync.",
            sourceInstallationId: "   ",
            eventId: "event"
        ))
    }

    func testLeaveAndRejoinChangesFingerprintWhenMembershipGenerationChanges() {
        let first = participant(membershipId: "membership-1")
        let rejoined = participant(membershipId: "membership-2")

        let firstFingerprint = AutomaticSyncIdentityScope.scanTriggerFingerprint(
            event: event(),
            participants: [first]
        )
        let rejoinedFingerprint = AutomaticSyncIdentityScope.scanTriggerFingerprint(
            event: event(),
            participants: [rejoined]
        )

        XCTAssertNotEqual(firstFingerprint, rejoinedFingerprint)
    }

    func testSourceMembershipChangeTriggersEvenWhenSourceHasNoFaceRosterRow() {
        let roster = [participant(membershipId: "recipient-membership")]
        let first = AutomaticSyncIdentityScope.scanTriggerFingerprint(
            event: event(),
            participants: roster,
            sourceMembershipId: "source-membership-1",
            sharingRevision: "id:sharing"
        )
        let rejoined = AutomaticSyncIdentityScope.scanTriggerFingerprint(
            event: event(),
            participants: roster,
            sourceMembershipId: "source-membership-2",
            sharingRevision: "id:sharing"
        )

        XCTAssertNotEqual(first, rejoined)
    }

    func testSharingGenerationChangeBypassesAutomaticCooldownFingerprint() {
        let roster = [participant(membershipId: "recipient-membership")]
        let before = AutomaticSyncIdentityScope.scanTriggerFingerprint(
            event: event(),
            participants: roster,
            sourceMembershipId: "source-membership",
            sharingRevision: "id:sharing-1"
        )
        let after = AutomaticSyncIdentityScope.scanTriggerFingerprint(
            event: event(),
            participants: roster,
            sourceMembershipId: "source-membership",
            sharingRevision: "id:sharing-2"
        )

        XCTAssertNotEqual(before, after)
    }

    func testFaceSetupRevisionChangesFingerprintForSameMembership() {
        let oldProfile = participant(membershipId: "membership", revisionLabel: "old")
        let newProfile = participant(membershipId: "membership", revisionLabel: "new")

        XCTAssertEqual(oldProfile.stableFaceIdentityId, newProfile.stableFaceIdentityId)
        XCTAssertNotEqual(oldProfile.faceProfileRevision, newProfile.faceProfileRevision)

        XCTAssertNotEqual(
            AutomaticSyncIdentityScope.scanTriggerFingerprint(event: event(), participants: [oldProfile]),
            AutomaticSyncIdentityScope.scanTriggerFingerprint(event: event(), participants: [newProfile])
        )
    }

    func testLegacyMemberFallbackChangesWhenJoinedAtChanges() {
        let original = participant(
            membershipId: nil,
            joinedAt: Date(timeIntervalSince1970: 60)
        )
        let rejoinedLegacy = participant(
            membershipId: nil,
            joinedAt: Date(timeIntervalSince1970: 90)
        )

        XCTAssertNotEqual(
            AutomaticSyncIdentityScope.scanTriggerFingerprint(event: event(), participants: [original]),
            AutomaticSyncIdentityScope.scanTriggerFingerprint(event: event(), participants: [rejoinedLegacy])
        )
    }
}