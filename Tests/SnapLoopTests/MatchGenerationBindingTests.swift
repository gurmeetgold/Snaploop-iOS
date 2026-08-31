import XCTest
@testable import SnapLoop

final class MatchGenerationBindingTests: XCTestCase {
    func testChange2CarriesSourceMetadataWithoutChangingLegacyPhotoId() {
        let match = PhotoMatch(
            eventId: "event",
            ownerUserId: "source",
            sourceInstallationId: String(repeating: "a", count: 64),
            sourceMembershipId: "membership-source",
            assetLocalId: "asset",
            appearances: [],
            capturedAt: Date(timeIntervalSince1970: 1),
            matchedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(match.id, "event:asset")
        XCTAssertEqual(match.sourceInstallationId, String(repeating: "a", count: 64))
        XCTAssertEqual(match.sourceMembershipId, "membership-source")
    }

    func testSourceScopedPhotoIdentitySeparatesSameAssetAcrossInstallationsWhenMigrationActivates() {
        let first = PhotoMatch(
            eventId: "event",
            ownerUserId: "source",
            sourceInstallationId: String(repeating: "a", count: 64),
            sourceMembershipId: "membership-source",
            assetLocalId: "same-local-id",
            appearances: [],
            capturedAt: Date(timeIntervalSince1970: 1),
            matchedAt: Date(timeIntervalSince1970: 2),
            useSourceScopedIdentity: true
        )
        let second = PhotoMatch(
            eventId: "event",
            ownerUserId: "source",
            sourceInstallationId: String(repeating: "b", count: 64),
            sourceMembershipId: "membership-source",
            assetLocalId: "same-local-id",
            appearances: [],
            capturedAt: Date(timeIntervalSince1970: 1),
            matchedAt: Date(timeIntervalSince1970: 2),
            useSourceScopedIdentity: true
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.contains(String(repeating: "a", count: 64)))
        XCTAssertTrue(second.id.contains(String(repeating: "b", count: 64)))
    }

    func testFaceMatcherCarriesRecipientMembershipGenerationIntoAppearance() throws {
        let embedding = try XCTUnwrap(FaceEmbedding([1, 0, 0]))
        let participant = EventParticipant(
            userId: "recipient",
            membershipId: "membership-recipient",
            displayName: "Recipient",
            faceIdentityId: "stable-face",
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(
                    id: "center",
                    embedding: embedding,
                    pose: .center,
                    quality: 1,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                FaceTemplate(
                    id: "side",
                    embedding: embedding,
                    pose: .sideA,
                    quality: 1,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: Date(timeIntervalSince1970: 1)
        )
        let face = DetectedFace(embedding: embedding, sizeFraction: 0.5)

        let appearances = FaceMatcher(config: .default).appearances(
            in: [face],
            participants: [participant]
        )

        XCTAssertEqual(appearances.count, 1)
        XCTAssertEqual(appearances[0].participantUserId, "recipient")
        XCTAssertEqual(appearances[0].recipientMembershipId, "membership-recipient")
    }

    func testExplicitServerIdIsPreservedWhenDecodingFutureSourceScopedMatch() {
        let explicit = "event:\(String(repeating: "c", count: 64)):asset"
        let match = PhotoMatch(
            id: explicit,
            eventId: "event",
            ownerUserId: "source",
            sourceInstallationId: String(repeating: "c", count: 64),
            sourceMembershipId: "membership-source",
            assetLocalId: "asset",
            appearances: [],
            capturedAt: Date(timeIntervalSince1970: 1),
            matchedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(match.id, explicit)
    }
}
