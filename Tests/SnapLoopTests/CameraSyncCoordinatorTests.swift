import XCTest
@testable import SnapLoop

final class CameraSyncCoordinatorTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private struct ScriptedLibrary: PhotoLibraryService {
        let assetsList: [PhotoAsset]
        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] { assetsList.filter { range.contains($0.creationDate) } }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data { Data(assetId.utf8) }
        func originalImageData(for assetId: String) async throws -> Data { Data(assetId.utf8) }
    }

    private struct ScriptedDetector: FaceDetectionService {
        let facesByAsset: [String: [DetectedFace]]
        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            facesByAsset[String(decoding: imageData, as: UTF8.self)] ?? []
        }
        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding { FaceEmbedding(normalized: [1, 0, 0]) }
    }

    private func face(_ raw: [Float]) -> DetectedFace { DetectedFace(embedding: FaceEmbedding(raw)!, sizeFraction: 0.5) }

    private func makeEvent(now: Date) -> Event {
        Event(id: "e1", joinCode: "ABC234", creatorUserId: "alice", name: "Event",
              startsAt: now.addingTimeInterval(-day), endsAt: now.addingTimeInterval(day),
              createdAt: now.addingTimeInterval(-day))
    }

    private func bobRoster() -> [EventParticipant] {
        [EventParticipant(userId: "bob", displayName: "Bob",
                          faceEmbedding: FaceEmbedding([1, 0, 0])!,
                          faceTemplates: [
                            FaceTemplate(embedding: FaceEmbedding([1, 0, 0])!, pose: .center, quality: 1, createdAt: Date()),
                            FaceTemplate(embedding: FaceEmbedding([1, 0, 0])!, pose: .sideA, quality: 1, createdAt: Date())
                          ],
                          faceProfileVersion: FaceModelPolicy.currentVersion,
                          joinedAt: Date())]
    }

    private func scanKey(eventId: String = "e1", userId: String = "alice") -> String {
        [eventId, userId, FaceModelPolicy.scanGeneration].joined(separator: "::")
    }

    func testUploadsOnlyMatchesForOtherMembersAndMarksAllScanned() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = makeEvent(now: now)
        let assets = [
            PhotoAsset(id: "a1", creationDate: now),
            PhotoAsset(id: "a2", creationDate: now),
            PhotoAsset(id: "a3", creationDate: now),
        ]
        let detector = ScriptedDetector(facesByAsset: [
            "a1": [face([1, 0, 0])],
            "a2": [face([0, 1, 0])],
            "a3": [face([1, 0, 0])],
        ])

        let matchRepo = InMemoryMatchRepository()
        let scanStore = InMemoryScanStateStore()
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ScriptedLibrary(assetsList: assets),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: matchRepo,
            scanStateStore: scanStore
        )

        let summary = try await coordinator.sync(event: event, participants: bobRoster(), currentUserId: "alice")

        XCTAssertEqual(summary.scanned, 3)
        XCTAssertEqual(summary.matchedPhotos, 2)
        XCTAssertFalse(summary.hasMore)

        let bobPhotos = try await matchRepo.myPhotos(eventId: "e1", userId: "bob")
        XCTAssertEqual(Set(bobPhotos.map(\.assetLocalId)), ["a1", "a3"])
        let alicePhotos = try await matchRepo.myPhotos(eventId: "e1", userId: "alice")
        XCTAssertTrue(alicePhotos.isEmpty)
        XCTAssertEqual(scanStore.load(eventId: scanKey()).scannedCount, 3)
    }

    func testSecondPassIsCaughtUpAndRescansNothing() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = makeEvent(now: now)
        let assets = [PhotoAsset(id: "a1", creationDate: now)]
        let detector = ScriptedDetector(facesByAsset: ["a1": [face([1, 0, 0])]])
        let scanStore = InMemoryScanStateStore()

        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ScriptedLibrary(assetsList: assets),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: InMemoryMatchRepository(),
            scanStateStore: scanStore
        )

        _ = try await coordinator.sync(event: event, participants: bobRoster(), currentUserId: "alice")
        let second = try await coordinator.sync(event: event, participants: bobRoster(), currentUserId: "alice")

        XCTAssertEqual(second.scanned, 0)
        XCTAssertTrue(second.alreadyCaughtUp)
    }

    func testRefusesToSyncExpiredEvent() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = Event(id: "e1", joinCode: "ABC234", creatorUserId: "alice", name: "Old",
                          startsAt: now.addingTimeInterval(-30 * day),
                          endsAt: now.addingTimeInterval(-20 * day),
                          createdAt: now.addingTimeInterval(-30 * day))
        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ScriptedLibrary(assetsList: []),
            faceDetection: ScriptedDetector(facesByAsset: [:]),
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: InMemoryMatchRepository(),
            scanStateStore: InMemoryScanStateStore()
        )

        do {
            _ = try await coordinator.sync(event: event, participants: bobRoster(), currentUserId: "alice")
            XCTFail("Expected expired event to throw")
        } catch {
            XCTAssertEqual(error as? AppError, .eventExpired)
        }
    }
}
