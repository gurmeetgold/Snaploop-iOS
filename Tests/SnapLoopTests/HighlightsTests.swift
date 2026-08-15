import XCTest
@testable import SnapLoop

final class HighlightsTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 2_000_000)

    private func photo(_ ref: String, source: String = "s1", at offset: TimeInterval,
                       users: [String] = ["u1"], type: MediaType = .photo) -> EventPhoto {
        EventPhoto(eventId: "e1", sourceUserId: source, capturedAt: base.addingTimeInterval(offset),
                   width: 3000, height: 2000, mediaType: type, matchedUserIds: users,
                   createdAt: base, sourceAssetReference: ref)
    }
    private func q(_ id: String, sharp: Double, face: Double = 0.7, exp: Double = 0.7) -> (String, PhotoQualitySignals) {
        ("e1:\(id)", PhotoQualitySignals(photoId: id, sharpness: sharp, faceQuality: face, exposure: exp))
    }

    // MARK: Best shot

    func testBurstGroupingBySourceAndTime() {
        let sel = BestShotSelector(burstWindow: 3)
        let photos = [
            photo("a", at: 0), photo("b", at: 1), photo("c", at: 2),   // one burst (s1)
            photo("d", at: 100),                                        // separate (s1)
            photo("e", source: "s2", at: 1),                            // different source
        ]
        let groups = sel.bursts(photos)
        XCTAssertEqual(groups.count, 3)
    }

    func testBestShotPicksHighestQualityPerBurst() {
        let sel = BestShotSelector(burstWindow: 3)
        let photos = [photo("a", at: 0), photo("b", at: 1), photo("c", at: 2)]
        let quality = Dictionary(uniqueKeysWithValues: [
            q("a", sharp: 0.3), q("b", sharp: 0.9), q("c", sharp: 0.5),
        ])
        let best = sel.bestShots(from: photos, quality: quality)
        XCTAssertEqual(best.count, 1)
        XCTAssertEqual(best.first?.sourceAssetReference, "b")
    }

    // MARK: Blur filter

    func testBlurFilterPartitionsByThreshold() {
        let filter = BlurFilter(threshold: 0.4)
        let photos = [photo("a", at: 0), photo("b", at: 100)]
        let quality = Dictionary(uniqueKeysWithValues: [q("a", sharp: 0.2), q("b", sharp: 0.8)])
        let (shown, down) = filter.partition(photos, quality: quality)
        XCTAssertEqual(shown.map(\.sourceAssetReference), ["b"])
        XCTAssertEqual(down.map(\.sourceAssetReference), ["a"])
    }

    // MARK: Highlights curation

    func testCuratorProducesGroupAndPerParticipantWithinLimits() {
        let curator = HighlightsCurator(groupLimit: 3, perParticipantLimit: 2, burstWindow: 3)
        // Spread-out photos so bursts don't collapse them all.
        let photos = (0..<8).map { photo("p\($0)", at: Double($0) * 600, users: $0 % 2 == 0 ? ["u1"] : ["u2"]) }
        let quality = Dictionary(uniqueKeysWithValues: photos.map { q($0.sourceAssetReference, sharp: 0.5 + Double.random(in: 0...0.4)) })

        let h = curator.curate(eventId: "e1", photos: photos, quality: quality)
        XCTAssertLessThanOrEqual(h.group.count, 3)
        XCTAssertFalse(h.group.isEmpty)
        XCTAssertLessThanOrEqual(h.perParticipant["u1"]?.count ?? 0, 2)
        XCTAssertLessThanOrEqual(h.perParticipant["u2"]?.count ?? 0, 2)
    }

    func testCuratorIsAdditiveAndEmptyWhenNoPhotos() {
        let h = HighlightsCurator().curate(eventId: "e1", photos: [], quality: [:])
        XCTAssertTrue(h.isEmpty)
    }

    func testEntitlementGatesPremiumOnly() {
        XCTAssertFalse(Entitlement.free.allows(.videoHighlightReel))
        XCTAssertTrue(Entitlement.premiumOrganizer.allows(.videoHighlightReel))
        XCTAssertTrue(Entitlement.business.allows(.extendedRetention))
    }
}
