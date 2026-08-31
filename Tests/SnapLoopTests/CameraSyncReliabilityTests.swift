import Foundation
import XCTest
@testable import SnapLoop

final class CameraSyncReliabilityTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private struct OneAssetLibrary: PhotoLibraryService {
        let asset: PhotoAsset
        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] { range.contains(asset.creationDate) ? [asset] : [] }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data { Data(assetId.utf8) }
        func originalImageData(for assetId: String) async throws -> Data { Data(assetId.utf8) }
    }

    private struct AlwaysMatchDetector: FaceDetectionService {
        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            [DetectedFace(embedding: FaceEmbedding(normalized: [1, 0, 0]), sizeFraction: 0.5)]
        }
        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding { FaceEmbedding(normalized: [1, 0, 0]) }
    }

    private final class FixedInstallationIdentity: AccountInstallationIdentityProviding, @unchecked Sendable {
        let value: String
        init(_ value: String) { self.value = value }
        func id(for userId: String) -> String { value }
        func resetInstallation() {}
    }

    private struct FailingMatchRepository: MatchRepository {
        func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws { throw AppError.network(underlying: "transient") }
        func dismissAppearance(matchId: String, participantUserId: String) async throws {}
        func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch] { [] }
        func sharedAlbum(eventId: String) async throws -> [PhotoMatch] { [] }
        func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL { throw AppError.originalUnavailable }
    }

    func testFailedUploadKeepsCachedCorpusRetryableAndCountsAsRemaining() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = Event(
            id: "e1",
            joinCode: "ABC234",
            creatorUserId: "alice",
            name: "Event",
            startsAt: now - day,
            endsAt: now + day,
            createdAt: now - day
        )
        let asset = PhotoAsset(id: "a1", creationDate: now)
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        let participant = EventParticipant(
            userId: "bob",
            membershipId: "membership-bob",
            displayName: "Bob",
            faceIdentityId: "bob-face",
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(id: "bob-center", embedding: embedding, pose: .center, quality: 1, createdAt: now),
                FaceTemplate(id: "bob-side", embedding: embedding, pose: .sideA, quality: 1, createdAt: now)
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: now
        )
        let scanStore = InMemoryScanStateStore()
        let installationId = "fixed-installation"
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OneAssetLibrary(asset: asset),
            faceDetection: AlwaysMatchDetector(),
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: FailingMatchRepository(),
            scanStateStore: scanStore,
            accountInstallationIdentity: FixedInstallationIdentity(installationId)
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

        let key = CameraSyncCoordinator.scanStateKey(
            eventId: event.id,
            sourceInstallationId: installationId
        )
        let state = scanStore.load(eventId: key)
        XCTAssertEqual(state.corpusCount, 1, "Expensive detection should survive a transient upload failure")
        XCTAssertFalse(state.recipientCursor(userId: "bob")?.hasEvaluated(asset.id) ?? true)
    }

    func testScanStatePrunesCorpusAndCursorEntriesNoLongerVisibleInPhotoKitWindow() {
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        var state = ScanState(
            eventId: "state",
            scannedAssetIds: ["still-here", "deleted"],
            photoCorpus: [
                "still-here": PhotoCorpusRecord(
                    assetId: "still-here",
                    creationDate: Date(timeIntervalSince1970: 1),
                    faces: [CachedPhotoFace(embedding: embedding, sizeFraction: 0.5)],
                    processedAt: Date(timeIntervalSince1970: 2)
                ),
                "deleted": PhotoCorpusRecord(
                    assetId: "deleted",
                    creationDate: Date(timeIntervalSince1970: 1),
                    faces: [],
                    processedAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )
        state.reconcileRecipient(
            userId: "bob",
            membershipEpoch: "membership",
            faceIdentityId: "face",
            faceProfileRevision: "revision"
        )
        state.markRecipientEvaluation(userId: "bob", assetId: "still-here", matched: true)
        state.markRecipientEvaluation(userId: "bob", assetId: "deleted", matched: false)

        state.retainCurrentAssets(["still-here", "new-unprocessed"])

        XCTAssertEqual(state.scannedAssetIds, ["still-here"])
        XCTAssertEqual(Set(state.photoCorpus.keys), ["still-here"])
        XCTAssertEqual(state.recipientCursor(userId: "bob")?.positiveAssetIds, ["still-here"])
        XCTAssertTrue(state.recipientCursor(userId: "bob")?.negativeAssetIds.isEmpty == true)
    }
}
