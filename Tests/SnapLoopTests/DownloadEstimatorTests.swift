import XCTest
@testable import SnapLoop

final class DownloadEstimatorTests: XCTestCase {

    private func photo(_ id: String, w: Int, h: Int, type: MediaType = .photo) -> EventPhoto {
        EventPhoto(eventId: "e1", sourceUserId: "s", capturedAt: Date(),
                   width: w, height: h, mediaType: type, matchedUserIds: ["u1"],
                   createdAt: Date(), sourceAssetReference: id)
    }

    func testPhotoEstimateScalesWithPixels() {
        let est = DownloadEstimator(jpegBytesPerPixel: 0.3)
        let small = est.estimatedBytes(for: photo("a", w: 1000, h: 1000))
        let big = est.estimatedBytes(for: photo("b", w: 4000, h: 3000))
        XCTAssertEqual(small, 300_000)
        XCTAssertEqual(big, Int64(4000 * 3000) * 3 / 10)
        XCTAssertGreaterThan(big, small)
    }

    func testBatchSumsAllItems() {
        let est = DownloadEstimator(jpegBytesPerPixel: 0.3)
        let total = est.estimatedBytes(for: [photo("a", w: 1000, h: 1000), photo("b", w: 1000, h: 1000)])
        XCTAssertEqual(total, 600_000)
    }

    func testWiFiRecommendedOnlyAboveThreshold() {
        let est = DownloadEstimator(jpegBytesPerPixel: 0.3, wifiRecommendationThreshold: 1_000_000)
        XCTAssertFalse(est.shouldRecommendWiFi(for: [photo("a", w: 1000, h: 1000)]))       // 300 KB
        let many = (0..<10).map { photo("p\($0)", w: 2000, h: 2000) }                       // 10 × 1.2 MB
        XCTAssertTrue(est.shouldRecommendWiFi(for: many))
    }

    func testVideoUsesDurationHeuristic() {
        let est = DownloadEstimator(assumedVideoSeconds: 10, videoBitsPerSecond: 8_000_000)
        // 10s × 8 Mbps / 8 = 10 MB
        XCTAssertEqual(est.estimatedBytes(for: photo("v", w: 1920, h: 1080, type: .video)), 10_000_000)
    }

    func testHumanReadableSizeIsNonEmpty() {
        let est = DownloadEstimator()
        XCTAssertFalse(est.humanReadableSize(for: [photo("a", w: 4000, h: 3000)]).isEmpty)
    }
}
