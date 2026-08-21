import Foundation
import XCTest
@testable import SnapLoop

final class CameraSyncReliabilityTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private struct OneAssetLibrary: PhotoLibraryService {
        let asset: PhotoAsset
        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] {
            range.contains(asset.creationDate) ? [asset] : []
        }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
            Data(assetId.utf8)
        }
        func originalImageData(for assetId: String) async throws -> Data { Data(assetId.utf8) }
    }

    private struct AlwaysMatchDetector: FaceDetectionService {
        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            [DetectedFace(embedding: FaceEmbedding(normalized: [1, 0, 0]), sizeFraction: 0.5)]
        }
        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }
    }

    private struct FailingMatchRepository: MatchRepository {
        func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws {
            throw AppError.network(underlying: "transient")
        }
        func dismissAppearance(matchId: String, participantUserId: String) async throws {}
        func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch] { [] }
        func sharedAlbum(eventId: String) async throws -> [PhotoMatch] { [] }
        func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL {
            throw AppError.originalUnavailable
        }
    }

    func testFailedUploadRemainsRetryableAndCountsAsRemaining() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = Event(
            id: "e1",
            joinCode: "ABC234",
            creatorUserId: "alice",
            name: "Trip",
            startsAt: now - day,
            endsAt: now + day,
            createdAt: now - day
        )
        let asset = PhotoAsset(id: "a1", creationDate: now)
        let participant = EventParticipant(
            userId: "alice",
            displayName: "Alice",
            faceEmbedding: FaceEmbedding(normalized: [1, 0, 0]),
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: now
        )
        let scanStore = InMemoryScanStateStore()
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OneAssetLibrary(asset: asset),
            faceDetection: AlwaysMatchDetector(),
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: FailingMatchRepository(),
            scanStateStore: scanStore
        )

        let summary = try await coordinator.sync(
            event: event,
            participants: [participant],
            currentUserId: "alice"
        )

        XCTAssertEqual(summary.scanned, 0)
        XCTAssertEqual(summary.matchedPhotos, 0)
        XCTAssertEqual(summary.remaining, 1)
        XCTAssertFalse(summary.alreadyCaughtUp)

        let key = [event.id, "alice", FaceModelPolicy.scanGeneration].joined(separator: "::")
        XCTAssertFalse(scanStore.load(eventId: key).hasScanned(asset.id))
    }

    func testScanStatePrunesIdentifiersNoLongerVisibleInPhotoKitWindow() {
        var state = ScanState(
            eventId: "e1::alice::generation",
            scannedAssetIds: ["still-here", "deleted", "limited-access-removed"]
        )

        state.retainScannedAssetIds(["still-here", "new-unscanned"])

        XCTAssertEqual(state.scannedAssetIds, ["still-here"])
    }
}
