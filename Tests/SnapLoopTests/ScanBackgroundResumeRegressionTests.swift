import Foundation
import XCTest
@testable import SnapLoop

final class ScanBackgroundResumeRegressionTests: XCTestCase {
    private struct ThreeAssetLibrary: PhotoLibraryService {
        let assetsToReturn: [PhotoAsset]

        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] {
            assetsToReturn.filter { range.contains($0.creationDate) }
        }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
            Data(assetId.utf8)
        }
        func originalImageData(for assetId: String) async throws -> Data {
            Data(assetId.utf8)
        }
    }

    private final class CancelSecondAssetOnceDetector: FaceDetectionService, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledSecondAsset = false
        private var counts: [String: Int] = [:]

        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            let assetId = String(data: imageData, encoding: .utf8) ?? "unknown"
            lock.lock()
            counts[assetId, default: 0] += 1
            let shouldCancel = assetId == "a2" && !cancelledSecondAsset
            if shouldCancel { cancelledSecondAsset = true }
            lock.unlock()

            if shouldCancel { throw CancellationError() }
            return [DetectedFace(
                embedding: FaceEmbedding(normalized: [1, 0, 0]),
                sizeFraction: 0.5
            )]
        }

        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }

        func count(for assetId: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[assetId, default: 0]
        }
    }

    private final class FixedInstallationIdentity: AccountInstallationIdentityProviding, @unchecked Sendable {
        func id(for userId: String) -> String { "background-resume-installation" }
        func resetInstallation() {}
    }

    func testInterruptedScanKeepsCompletedCheckpointAndResumesAtFirstUnprocessedAsset() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = Event(
            id: "background-resume-event",
            joinCode: "RES234",
            creatorUserId: "alice",
            name: "Background Resume",
            startsAt: now.addingTimeInterval(-86_400),
            endsAt: now.addingTimeInterval(86_400),
            createdAt: now.addingTimeInterval(-86_400)
        )
        let assets = [
            PhotoAsset(id: "a1", creationDate: now.addingTimeInterval(-3)),
            PhotoAsset(id: "a2", creationDate: now.addingTimeInterval(-2)),
            PhotoAsset(id: "a3", creationDate: now.addingTimeInterval(-1)),
        ]
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        let bob = EventParticipant(
            userId: "bob",
            membershipId: "membership-bob",
            displayName: "Bob",
            faceIdentityId: "bob-face",
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(id: "bob-center", embedding: embedding, pose: .center, quality: 1, createdAt: now),
                FaceTemplate(id: "bob-side", embedding: embedding, pose: .sideA, quality: 1, createdAt: now),
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: now.addingTimeInterval(-1_000)
        )

        let scanState = InMemoryScanStateStore()
        let matches = InMemoryMatchRepository()
        let detector = CancelSecondAssetOnceDetector()
        let installation = FixedInstallationIdentity()
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ThreeAssetLibrary(assetsToReturn: assets),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: matches,
            scanStateStore: scanState,
            accountInstallationIdentity: installation
        )

        do {
            _ = try await coordinator.sync(
                event: event,
                participants: [bob],
                currentUserId: "alice",
                sourceMembershipId: "membership-alice"
            )
            XCTFail("The simulated background interruption should cancel the first pass")
        } catch let error as AppError {
            XCTAssertEqual(error, .syncCancelled)
        }

        let stateKey = CameraSyncCoordinator.scanStateKey(
            eventId: event.id,
            sourceInstallationId: installation.id(for: "alice")
        )
        let interruptedState = scanState.load(eventId: stateKey)
        XCTAssertNotNil(interruptedState.corpusRecord(for: "a1"))
        XCTAssertNil(interruptedState.corpusRecord(for: "a2"), "Interrupted inference must not be checkpointed as a completed miss")
        XCTAssertNil(interruptedState.corpusRecord(for: "a3"))
        XCTAssertTrue(interruptedState.recipientCursor(userId: "bob")?.hasEvaluated("a1") == true)
        XCTAssertFalse(interruptedState.recipientCursor(userId: "bob")?.hasEvaluated("a2") ?? false)

        let resumed = try await coordinator.sync(
            event: event,
            participants: [bob],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice"
        )

        XCTAssertEqual(resumed.scanned, 2)
        XCTAssertEqual(resumed.remaining, 0)
        XCTAssertEqual(detector.count(for: "a1"), 1, "Resume must not rerun ML for the completed first asset")
        XCTAssertEqual(detector.count(for: "a2"), 2, "The interrupted asset is retried exactly once")
        XCTAssertEqual(detector.count(for: "a3"), 1)

        let photos = try await matches.myPhotos(eventId: event.id, userId: "bob")
        XCTAssertEqual(Set(photos.map(\.assetLocalId)), Set(["a1", "a2", "a3"]))
    }
}
