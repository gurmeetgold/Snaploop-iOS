import Foundation
import XCTest
@testable import SnapLoop

final class Change4AmbiguityRevalidationTests: XCTestCase {
    private struct OneAssetLibrary: PhotoLibraryService {
        let asset: PhotoAsset

        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] {
            range.contains(asset.creationDate) ? [asset] : []
        }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
            Data("image-\(assetId)".utf8)
        }
        func originalImageData(for assetId: String) async throws -> Data {
            Data("original-\(assetId)".utf8)
        }
    }

    private final class CountingDetector: FaceDetectionService, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            lock.lock()
            count += 1
            lock.unlock()
            return [DetectedFace(
                embedding: FaceEmbedding(normalized: [1, 0, 0]),
                sizeFraction: 0.5
            )]
        }

        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }

        var detectionCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private final class CapturingMatchRepository: MatchRepository, @unchecked Sendable {
        struct Upload: Sendable {
            let match: PhotoMatch
            let thumbnail: Data
        }

        private let lock = NSLock()
        private var storage: [Upload] = []

        func upload(match: PhotoMatch, thumbnailJPEG: Data) async throws {
            lock.lock()
            storage.append(Upload(match: match, thumbnail: thumbnailJPEG))
            lock.unlock()
        }

        func dismissAppearance(matchId: String, participantUserId: String) async throws {}
        func myPhotos(eventId: String, userId: String) async throws -> [PhotoMatch] { [] }
        func sharedAlbum(eventId: String) async throws -> [PhotoMatch] { [] }
        func signedOriginalURL(match: PhotoMatch, ttlHours: Int) async throws -> URL {
            throw AppError.originalUnavailable
        }

        var uploads: [Upload] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private final class FixedInstallationIdentity: AccountInstallationIdentityProviding, @unchecked Sendable {
        let value: String
        init(_ value: String) { self.value = value }
        func id(for userId: String) -> String { value }
        func resetInstallation() {}
    }

    private func participant(
        userId: String,
        membershipId: String,
        identityId: String,
        now: Date
    ) -> EventParticipant {
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        return EventParticipant(
            userId: userId,
            membershipId: membershipId,
            displayName: userId,
            faceIdentityId: identityId,
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(
                    id: "\(userId)-center",
                    embedding: embedding,
                    pose: .center,
                    quality: 1,
                    createdAt: now
                ),
                FaceTemplate(
                    id: "\(userId)-side",
                    embedding: embedding,
                    pose: .sideA,
                    quality: 1,
                    createdAt: now
                ),
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: now
        )
    }

    func testNewAmbiguousMemberRevokesOldPositiveWithoutRerunningFaceDetection() async throws {
        let now = Date(timeIntervalSince1970: 2_500_000)
        let event = Event(
            id: "event",
            joinCode: "ABC234",
            creatorUserId: "alice",
            name: "Event",
            startsAt: now - 86_400,
            endsAt: now + 86_400,
            createdAt: now - 86_400
        )
        let asset = PhotoAsset(id: "asset", creationDate: now)
        let bob = participant(
            userId: "bob",
            membershipId: "membership-bob",
            identityId: "face-bob",
            now: now
        )
        let eve = participant(
            userId: "eve",
            membershipId: "membership-eve",
            identityId: "face-eve",
            now: now
        )

        let detector = CountingDetector()
        let matches = CapturingMatchRepository()
        let scanState = InMemoryScanStateStore()
        let installation = FixedInstallationIdentity("installation")
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OneAssetLibrary(asset: asset),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: matches,
            scanStateStore: scanState,
            accountInstallationIdentity: installation
        )

        let initial = try await coordinator.sync(
            event: event,
            participants: [bob],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice"
        )
        XCTAssertEqual(initial.scanned, 1)
        XCTAssertEqual(initial.matchedPhotos, 1)
        XCTAssertEqual(detector.detectionCount, 1)
        XCTAssertEqual(matches.uploads.count, 1)
        XCTAssertEqual(matches.uploads[0].match.activeParticipantIds, ["bob"])
        XCTAssertFalse(matches.uploads[0].thumbnail.isEmpty)

        // Eve is intentionally enrolled with the same synthetic embedding. The
        // full current roster should now make this face ambiguous instead of
        // leaving Bob's formerly positive match authorized forever.
        let revalidated = try await coordinator.sync(
            event: event,
            participants: [bob, eve],
            currentUserId: "alice",
            sourceMembershipId: "membership-alice"
        )

        XCTAssertEqual(revalidated.scanned, 1)
        XCTAssertEqual(revalidated.matchedPhotos, 0)
        XCTAssertEqual(revalidated.remaining, 0)
        XCTAssertEqual(detector.detectionCount, 1, "Roster changes must reuse cached photo-face embeddings")
        XCTAssertEqual(matches.uploads.count, 2)

        let removalUpload = matches.uploads[1]
        XCTAssertTrue(removalUpload.match.appearances.isEmpty)
        XCTAssertEqual(removalUpload.match.recipientRemovals?.map(\.participantUserId), ["bob"])
        XCTAssertEqual(removalUpload.match.recipientRemovals?.first?.recipientMembershipId, "membership-bob")
        XCTAssertTrue(removalUpload.thumbnail.isEmpty, "Removal-only reconciliation must not re-upload the image")

        let key = CameraSyncCoordinator.scanStateKey(
            eventId: event.id,
            sourceInstallationId: installation.value
        )
        let state = scanState.load(eventId: key)
        XCTAssertEqual(state.recipientCursor(userId: "bob")?.negativeAssetIds, [asset.id])
        XCTAssertEqual(state.recipientCursor(userId: "eve")?.negativeAssetIds, [asset.id])
        XCTAssertTrue(state.recipientCursor(userId: "bob")?.staleAssetIds.isEmpty == true)
    }
}
