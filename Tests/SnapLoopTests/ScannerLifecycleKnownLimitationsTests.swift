import XCTest
@testable import SnapLoop

/// Regression coverage for the lifecycle cases that motivated Change 4. The
/// scanner must reuse cached photo-face embeddings while independently advancing
/// each recipient's membership/identity/template cursor.
final class ScannerLifecycleRegressionTests: XCTestCase {
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
        func originalImageData(for assetId: String) async throws -> Data {
            Data(assetId.utf8)
        }
    }

    private struct ScriptedDetector: FaceDetectionService {
        let facesByAsset: [String: [DetectedFace]]

        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            facesByAsset[String(decoding: imageData, as: UTF8.self)] ?? []
        }

        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }
    }

    private func face(_ vector: [Float]) -> DetectedFace {
        DetectedFace(embedding: FaceEmbedding(vector)!, sizeFraction: 0.5)
    }

    private func participant(
        userId: String = "recipient",
        membershipId: String? = nil,
        identityId: String,
        revisionLabel: String,
        vector: [Float],
        joinedAt: Date
    ) -> EventParticipant {
        let embedding = FaceEmbedding(vector)!
        return EventParticipant(
            userId: userId,
            membershipId: membershipId,
            displayName: nil,
            faceIdentityId: identityId,
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(
                    id: "\(revisionLabel)-center",
                    embedding: embedding,
                    pose: .center,
                    quality: 1,
                    createdAt: joinedAt
                ),
                FaceTemplate(
                    id: "\(revisionLabel)-side",
                    embedding: embedding,
                    pose: .sideA,
                    quality: 1,
                    createdAt: joinedAt
                )
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: joinedAt
        )
    }

    private func event(now: Date) -> Event {
        Event(
            id: "event",
            joinCode: "ABC234",
            creatorUserId: "source",
            name: "Event",
            startsAt: now.addingTimeInterval(-86_400),
            endsAt: now.addingTimeInterval(86_400),
            createdAt: now.addingTimeInterval(-86_400)
        )
    }

    private func coordinator(
        now: Date,
        store: ScanStateStore,
        detector: ScriptedDetector,
        matches: MatchRepository = InMemoryMatchRepository()
    ) -> CameraSyncCoordinator {
        CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ScriptedLibrary(
                assetsList: [PhotoAsset(id: "asset", creationDate: now)]
            ),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: matches,
            scanStateStore: store
        )
    }

    func testSameIdentityFaceSetupRefreshReevaluatesPreviouslyNegativePhoto() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let matchRepository = InMemoryMatchRepository()
        let detector = ScriptedDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(
            now: now,
            store: store,
            detector: detector,
            matches: matchRepository
        )
        let oldProfile = participant(
            identityId: "stable-face",
            revisionLabel: "old",
            vector: [0, 1, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )
        let improvedProfile = participant(
            identityId: "stable-face",
            revisionLabel: "new",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )

        let first = try await coordinator.sync(
            event: event(now: now),
            participants: [oldProfile],
            currentUserId: "source"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 0)
        XCTAssertNotEqual(oldProfile.faceProfileRevision, improvedProfile.faceProfileRevision)
        XCTAssertEqual(oldProfile.stableFaceIdentityId, improvedProfile.stableFaceIdentityId)

        let afterRefresh = try await coordinator.sync(
            event: event(now: now),
            participants: [improvedProfile],
            currentUserId: "source"
        )

        XCTAssertEqual(afterRefresh.scanned, 1)
        XCTAssertEqual(afterRefresh.matchedPhotos, 1)
        XCTAssertEqual(
            try await matchRepository.myPhotos(eventId: "event", userId: "recipient").map(\.assetLocalId),
            ["asset"]
        )
    }

    func testLeaveAndRejoinCreatesFreshHistoricalEvaluation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let detector = ScriptedDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(now: now, store: store, detector: detector)
        let firstMembership = participant(
            membershipId: "membership-1",
            identityId: "stable-face",
            revisionLabel: "same",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )
        let rejoinedMembership = participant(
            membershipId: "membership-2",
            identityId: "stable-face",
            revisionLabel: "same",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 2)
        )

        let first = try await coordinator.sync(
            event: event(now: now),
            participants: [firstMembership],
            currentUserId: "source"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 1)
        XCTAssertNotEqual(firstMembership.membershipId, rejoinedMembership.membershipId)
        XCTAssertEqual(firstMembership.stableFaceIdentityId, rejoinedMembership.stableFaceIdentityId)

        let afterRejoin = try await coordinator.sync(
            event: event(now: now),
            participants: [rejoinedMembership],
            currentUserId: "source"
        )

        XCTAssertEqual(afterRejoin.scanned, 1)
        XCTAssertEqual(afterRejoin.matchedPhotos, 1)
    }

    func testNewMemberGetsHistoricalEvaluationWithoutNewPhoto() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let matches = InMemoryMatchRepository()
        let detector = ScriptedDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(now: now, store: store, detector: detector, matches: matches)

        // First pass builds the local corpus while there is nobody to receive the
        // photo. The photo must not become permanently "done".
        let first = try await coordinator.sync(
            event: event(now: now),
            participants: [],
            currentUserId: "source"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 0)

        let joined = participant(
            membershipId: "membership-new",
            identityId: "new-member-face",
            revisionLabel: "v1",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 3)
        )
        let afterJoin = try await coordinator.sync(
            event: event(now: now),
            participants: [joined],
            currentUserId: "source"
        )

        XCTAssertEqual(afterJoin.scanned, 1)
        XCTAssertEqual(afterJoin.matchedPhotos, 1)
        XCTAssertEqual(
            try await matches.myPhotos(eventId: "event", userId: "recipient").count,
            1
        )
    }
}
