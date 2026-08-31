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

    private final class CountingMatchDetector: FaceDetectionService, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            lock.lock()
            count += 1
            lock.unlock()
            return [DetectedFace(embedding: FaceEmbedding(normalized: [1, 0, 0]), sizeFraction: 0.5)]
        }

        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }

        var detectionCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
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

    private func event(now: Date) -> Event {
        Event(
            id: "e1",
            joinCode: "ABC234",
            creatorUserId: "alice",
            name: "Event",
            startsAt: now - day,
            endsAt: now + day,
            createdAt: now - day
        )
    }

    private func bob(now: Date) -> EventParticipant {
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        return EventParticipant(
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
    }

    func testFailedUploadKeepsCachedCorpusRetryableAndCountsAsRemaining() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let currentEvent = event(now: now)
        let asset = PhotoAsset(id: "a1", creationDate: now)
        let participant = bob(now: now)
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
            event: currentEvent,
            participants: [participant],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice"
        )

        XCTAssertEqual(summary.scanned, 0)
        XCTAssertEqual(summary.matchedPhotos, 0)
        XCTAssertEqual(summary.remaining, 1)
        XCTAssertFalse(summary.alreadyCaughtUp)

        let key = CameraSyncCoordinator.scanStateKey(
            eventId: currentEvent.id,
            sourceInstallationId: installationId
        )
        let state = scanStore.load(eventId: key)
        XCTAssertEqual(state.corpusCount, 1, "Expensive detection should survive a transient upload failure")
        XCTAssertFalse(state.recipientCursor(userId: "bob")?.hasEvaluated(asset.id) ?? true)
    }

    func testRetryAfterUploadFailureDoesNotRunFaceDetectionTwice() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let currentEvent = event(now: now)
        let asset = PhotoAsset(id: "a1", creationDate: now)
        let participant = bob(now: now)
        let scanStore = InMemoryScanStateStore()
        let detector = CountingMatchDetector()
        let installation = FixedInstallationIdentity("fixed-installation")

        let failingCoordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OneAssetLibrary(asset: asset),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: FailingMatchRepository(),
            scanStateStore: scanStore,
            accountInstallationIdentity: installation
        )
        let failed = try await failingCoordinator.sync(
            event: currentEvent,
            participants: [participant],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice"
        )
        XCTAssertEqual(failed.remaining, 1)
        XCTAssertEqual(detector.detectionCount, 1)

        let successfulMatches = InMemoryMatchRepository()
        let retryCoordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OneAssetLibrary(asset: asset),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: successfulMatches,
            scanStateStore: scanStore,
            accountInstallationIdentity: installation
        )
        let retried = try await retryCoordinator.sync(
            event: currentEvent,
            participants: [participant],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice"
        )

        XCTAssertEqual(retried.scanned, 1)
        XCTAssertEqual(retried.matchedPhotos, 1)
        XCTAssertEqual(retried.remaining, 0)
        XCTAssertEqual(detector.detectionCount, 1, "Retry must reuse the protected photo corpus instead of rerunning ML")
        let photos = try await successfulMatches.myPhotos(eventId: currentEvent.id, userId: "bob")
        XCTAssertEqual(photos.count, 1)
    }

    func testSharingGenerationChangeRepublishesOnlyCachedPositiveWork() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let currentEvent = event(now: now)
        let asset = PhotoAsset(id: "a1", creationDate: now)
        let participant = bob(now: now)
        let scanStore = InMemoryScanStateStore()
        let detector = CountingMatchDetector()
        let matches = InMemoryMatchRepository()
        let installation = FixedInstallationIdentity("fixed-installation")
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OneAssetLibrary(asset: asset),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: matches,
            scanStateStore: scanStore,
            accountInstallationIdentity: installation
        )

        let first = try await coordinator.sync(
            event: currentEvent,
            participants: [participant],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice",
            preferenceRevision: "id:sharing-1"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 1)
        XCTAssertEqual(detector.detectionCount, 1)

        let unchanged = try await coordinator.sync(
            event: currentEvent,
            participants: [participant],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice",
            preferenceRevision: "id:sharing-1"
        )
        XCTAssertEqual(unchanged.scanned, 0)
        XCTAssertTrue(unchanged.alreadyCaughtUp)
        XCTAssertEqual(detector.detectionCount, 1)

        // Server-side sharing OFF removes the published source row. The new
        // sharing generation must replay the prior positive from cached faces.
        let reenabled = try await coordinator.sync(
            event: currentEvent,
            participants: [participant],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice",
            preferenceRevision: "id:sharing-2"
        )
        XCTAssertEqual(reenabled.scanned, 1)
        XCTAssertEqual(reenabled.matchedPhotos, 1)
        XCTAssertEqual(detector.detectionCount, 1, "Sharing replay must not rerun face detection")

        let key = CameraSyncCoordinator.scanStateKey(
            eventId: currentEvent.id,
            sourceInstallationId: installation.value
        )
        let state = scanStore.load(eventId: key)
        XCTAssertEqual(state.sourceSharingRevision, "id:sharing-2")
        XCTAssertEqual(state.recipientCursor(userId: "bob")?.positiveAssetIds, [asset.id])
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

    func testScanStateNamespaceSeparatesSourceInstallations() {
        let first = CameraSyncCoordinator.scanStateKey(eventId: "event", sourceInstallationId: "install-a")
        let second = CameraSyncCoordinator.scanStateKey(eventId: "event", sourceInstallationId: "install-b")
        let stable = CameraSyncCoordinator.scanStateKey(eventId: "event", sourceInstallationId: "install-a")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, stable)
    }
}