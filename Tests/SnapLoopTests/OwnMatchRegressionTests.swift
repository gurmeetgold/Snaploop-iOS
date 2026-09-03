import XCTest
@testable import SnapLoop

final class OwnMatchRegressionTests: XCTestCase {
    private struct OnePhotoLibrary: PhotoLibraryService {
        let asset: PhotoAsset

        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] {
            range.contains(asset.creationDate) ? [asset] : []
        }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
            Data(assetId.utf8)
        }
        func originalImageData(for assetId: String) async throws -> Data {
            Data(assetId.utf8)
        }
    }

    private struct SelfFaceDetector: FaceDetectionService {
        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            [DetectedFace(embedding: FaceEmbedding([1, 0, 0])!, sizeFraction: 0.5)]
        }

        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }
    }

    private final class FixedInstallationIdentity: AccountInstallationIdentityProviding, @unchecked Sendable {
        func id(for userId: String) -> String { "own-match-regression-installation" }
        func resetInstallation() {}
    }

    func testEnablingOwnMatchesReplaysCachedCorpusAndPublishesSelfMatch() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = Event(
            id: "own-match-event",
            joinCode: "OWN234",
            creatorUserId: "alice",
            name: "Own Match Event",
            startsAt: now.addingTimeInterval(-86_400),
            endsAt: now.addingTimeInterval(86_400),
            createdAt: now.addingTimeInterval(-86_400)
        )
        let asset = PhotoAsset(id: "self-photo", creationDate: now)
        let alice = EventParticipant(
            userId: "alice",
            membershipId: "alice-membership",
            displayName: "Alice",
            faceIdentityId: "alice-face",
            faceEmbedding: FaceEmbedding([1, 0, 0])!,
            faceTemplates: [
                FaceTemplate(
                    id: "alice-center",
                    embedding: FaceEmbedding([1, 0, 0])!,
                    pose: .center,
                    quality: 1,
                    createdAt: now
                ),
                FaceTemplate(
                    id: "alice-side",
                    embedding: FaceEmbedding([1, 0, 0])!,
                    pose: .sideA,
                    quality: 1,
                    createdAt: now
                ),
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: now.addingTimeInterval(-1_000)
        )

        let matches = InMemoryMatchRepository()
        let scanState = InMemoryScanStateStore()
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: OnePhotoLibrary(asset: asset),
            faceDetection: SelfFaceDetector(),
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: matches,
            scanStateStore: scanState,
            accountInstallationIdentity: FixedInstallationIdentity()
        )

        // First pass builds the protected local corpus while own-photo visibility
        // is OFF. It must not publish Alice's own photo.
        _ = try await coordinator.sync(
            event: event,
            participants: [alice],
            currentUserId: "alice",
            includeOwnMatches: false,
            preferenceRevision: "share=s1;own=o1"
        )
        let beforeEnabling = try await matches.myPhotos(eventId: event.id, userId: "alice")
        XCTAssertTrue(beforeEnabling.isEmpty)

        // Turning the option ON changes only the own-match generation. The next
        // pass must reuse the cached extraction, open Alice's recipient cursor and
        // publish the legitimate self match without needing a new source photo.
        let replay = try await coordinator.sync(
            event: event,
            participants: [alice],
            currentUserId: "alice",
            includeOwnMatches: true,
            preferenceRevision: "share=s1;own=o2"
        )

        let ownPhotos = try await matches.myPhotos(eventId: event.id, userId: "alice")
        XCTAssertEqual(replay.scanned, 1)
        XCTAssertEqual(replay.matchedPhotos, 1)
        XCTAssertEqual(ownPhotos.map(\.assetLocalId), ["self-photo"])
        XCTAssertTrue(ownPhotos.allSatisfy { $0.isSourceScopedIdentity })
    }
}
