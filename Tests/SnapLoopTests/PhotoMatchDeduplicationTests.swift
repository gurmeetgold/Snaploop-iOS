import Foundation
import XCTest
@testable import SnapLoop

final class PhotoMatchDeduplicationTests: XCTestCase {
    func testUniqueKeepsOwnCameraMatches() {
        let match = makeMatch(eventId: "event-a", ownerUserId: "me", assetLocalId: "asset-1")

        let result = PhotoMatchDeduplication.unique([match])

        XCTAssertEqual(result, [match])
    }

    func testUniqueCollapsesSameLegacyOwnerAndAssetAcrossEvents() {
        let first = makeMatch(eventId: "event-a", ownerUserId: "friend", assetLocalId: "asset-1")
        let duplicate = makeMatch(eventId: "event-b", ownerUserId: "friend", assetLocalId: "asset-1")
        let differentOwner = makeMatch(eventId: "event-b", ownerUserId: "me", assetLocalId: "asset-1")

        let result = PhotoMatchDeduplication.unique([first, duplicate, differentOwner])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], first)
        XCTAssertEqual(result[1], differentOwner)
    }

    func testUniqueKeepsSameAssetIdentifierFromTwoSourceInstallations() {
        let first = makeMatch(
            eventId: "event-a",
            ownerUserId: "friend",
            assetLocalId: "same-local-id",
            sourceInstallationId: "install-a"
        )
        let second = makeMatch(
            eventId: "event-a",
            ownerUserId: "friend",
            assetLocalId: "same-local-id",
            sourceInstallationId: "install-b"
        )

        let result = PhotoMatchDeduplication.unique([first, second])

        XCTAssertEqual(result, [first, second])
    }

    func testUniquePrefersModernSourceScopedRowOverLegacyMigrationDuplicate() {
        let legacy = makeMatch(
            eventId: "event-a",
            ownerUserId: "friend",
            assetLocalId: "asset-1"
        )
        let modern = makeMatch(
            eventId: "event-a",
            ownerUserId: "friend",
            assetLocalId: "asset-1",
            sourceInstallationId: "install-a"
        )

        let result = PhotoMatchDeduplication.unique([legacy, modern])

        XCTAssertEqual(result, [modern])
    }

    private func makeMatch(
        eventId: String,
        ownerUserId: String,
        assetLocalId: String,
        sourceInstallationId: String? = nil
    ) -> PhotoMatch {
        PhotoMatch(
            eventId: eventId,
            ownerUserId: ownerUserId,
            sourceInstallationId: sourceInstallationId,
            assetLocalId: assetLocalId,
            appearances: [
                .init(participantUserId: "me", confidence: 0.95)
            ],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            matchedAt: Date(timeIntervalSince1970: 1_700_000_100),
            useSourceScopedIdentity: sourceInstallationId != nil
        )
    }
}
