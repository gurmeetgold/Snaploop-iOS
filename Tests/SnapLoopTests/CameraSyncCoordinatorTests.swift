import XCTest
@testable import SnapLoop

/// End-to-end test of one sync pass over scripted device services. Proves the
/// coordinator uploads only matched photos, marks every successfully processed
/// asset so it is never rescanned, and honors the lifecycle gate.
final class CameraSyncCoordinatorTests: XCTestCase {

    private let day: TimeInterval = 86_400

    // MARK: Scripted services

    private struct ScriptedLibrary: PhotoLibraryService {
        let assetsList: [PhotoAsset]
        func authorizationStatus() -> PhotoAuthorization { .authorized }
        func requestAuthorization() async -> PhotoAuthorization { .authorized }
        func assets(in range: ClosedRange<Date>) async throws -> [PhotoAsset] {
            assetsList.filter { range.contains($0.creationDate) }
        }
        func imageData(for assetId: String, maxPixelSize: Int) async throws -> Data {
            Data(assetId.utf8)
        }
        func originalImageData(for assetId: String) async throws -> Data { Data(assetId.utf8) }
    }

    private struct ScriptedDetector: FaceDetectionService {
        let facesByAsset: [String: [DetectedFace]]
        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            let assetId = String(decoding: imageData, as: UTF8.self)
            return facesByAsset[assetId] ?? []
        }
        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }
    }

    private func face(_ raw: [Float]) -> DetectedFace {
        DetectedFace(embedding: FaceEmbedding(raw)!, sizeFraction: 0.5)
    }

    private func makeEvent(now: Date) -> Event {
        Event(id: "e1", joinCode: "ABC234", creatorUserId: "alice", name: "Trip",
              startsAt: now.addingTimeInterval(-day), endsAt: now.addingTimeInterval(day),
              createdAt: now.addingTimeInterval(-day))
    }

    private func aliceRoster() -> [EventParticipant] {
        [EventParticipant(userId: "alice", displayName: "Alice",
                          faceEmbedding: FaceEmbedding([1, 0, 0])!,
                          faceTemplates: [
                            FaceTemplate(
                                embedding: FaceEmbedding([1, 0, 0])!,
                                pose: .frontal,
                                quality: 1,
                                createdAt: Date()
                            ),
                            FaceTemplate(
                                embedding: FaceEmbedding([1, 0, 0])!,
                                pose: .slightLeft,
                                quality: 1,
                                createdAt: Date()
                            )
                          ],
                          faceProfileVersion: FaceModelPolicy.currentVersion,
                          joinedAt: Date())]
    }

    private func scanKey(eventId: String = "e1", userId: String = "alice") -> String {
        [eventId, userId, FaceModelPolicy.scanGeneration].joined(separator: "::")
    }

    // MARK: Tests

    func testUploadsOnlyMatchedPhotosAndMarksAllScanned() async throws {
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

        let summary = try await coordinator.sync(
            event: event, participants: aliceRoster(), currentUserId: "alice")

        XCTAssertEqual(summary.scanned, 3)
        XCTAssertEqual(summary.matchedPhotos, 2)
        XCTAssertFalse(summary.hasMore)

        let mine = try await matchRepo.myPhotos(eventId: "e1", userId: "alice")
        XCTAssertEqual(Set(mine.map(\.assetLocalId)), ["a1", "a3"])

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

        _ = try await coordinator.sync(event: event, participants: aliceRoster(), currentUserId: "alice")
        let second = try await coordinator.sync(event: event, participants: aliceRoster(), currentUserId: "alice")

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
            _ = try await coordinator.sync(event: event, participants: aliceRoster(), currentUserId: "alice")
            XCTFail("Expected expired event to throw")
        } catch {
            XCTAssertEqual(error as? AppError, .eventExpired)
        }
    }
}
