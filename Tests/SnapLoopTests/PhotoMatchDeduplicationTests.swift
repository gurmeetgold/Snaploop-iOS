import Foundation
import XCTest
@testable import SnapLoop

final class PhotoMatchDeduplicationTests: XCTestCase {
    func testUniqueKeepsOwnCameraMatches() {
        let match = makeMatch(eventId: "event-a", ownerUserId: "me", assetLocalId: "asset-1")

        let result = PhotoMatchDeduplication.unique([match])

        XCTAssertEqual(result, [match])
    }

    func testUniqueCollapsesSameOwnerAndAssetAcrossEvents() {
        let first = makeMatch(eventId: "event-a", ownerUserId: "friend", assetLocalId: "asset-1")
        let duplicate = makeMatch(eventId: "event-b", ownerUserId: "friend", assetLocalId: "asset-1")
        let differentOwner = makeMatch(eventId: "event-b", ownerUserId: "me", assetLocalId: "asset-1")

        let result = PhotoMatchDeduplication.unique([first, duplicate, differentOwner])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], first)
        XCTAssertEqual(result[1], differentOwner)
    }

    private func makeMatch(eventId: String, ownerUserId: String, assetLocalId: String) -> PhotoMatch {
        PhotoMatch(
            eventId: eventId,
            ownerUserId: ownerUserId,
            assetLocalId: assetLocalId,
            appearances: [
                .init(participantUserId: "me", confidence: 0.95)
            ],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            matchedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }
}
