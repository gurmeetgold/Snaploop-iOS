import Foundation
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

    private final class CountingDetector: FaceDetectionService, @unchecked Sendable {
        private let lock = NSLock()
        private let facesByAsset: [String: [DetectedFace]]
        private var detections = 0

        init(facesByAsset: [String: [DetectedFace]]) {
            self.facesByAsset = facesByAsset
        }

        func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
            lock.lock()
            detections += 1
            lock.unlock()
            return facesByAsset[String(decoding: imageData, as: UTF8.self)] ?? []
        }

        func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
            FaceEmbedding(normalized: [1, 0, 0])
        }

        var detectionCount: Int {
            lock.lock(); defer { lock.unlock() }
            return detections
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
        detector: FaceDetectionService,
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
            currentUserId: "source",
            sourceMembershipId: "source-membership"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 0)
        XCTAssertNotEqual(oldProfile.faceProfileRevision, improvedProfile.faceProfileRevision)
        XCTAssertEqual(oldProfile.stableFaceIdentityId, improvedProfile.stableFaceIdentityId)

        let afterRefresh = try await coordinator.sync(
            event: event(now: now),
            participants: [improvedProfile],
            currentUserId: "source",
            sourceMembershipId: "source-membership"
        )

        XCTAssertEqual(afterRefresh.scanned, 1)
        XCTAssertEqual(afterRefresh.matchedPhotos, 1)
        let recipientPhotos = try await matchRepository.myPhotos(eventId: "event", userId: "recipient")
        XCTAssertEqual(recipientPhotos.map(\.assetLocalId), ["asset"])
    }

    func testRecipientLeaveAndRejoinCreatesFreshHistoricalEvaluation() async throws {
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
            currentUserId: "source",
            sourceMembershipId: "source-membership"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 1)
        XCTAssertNotEqual(firstMembership.membershipId, rejoinedMembership.membershipId)
        XCTAssertEqual(firstMembership.stableFaceIdentityId, rejoinedMembership.stableFaceIdentityId)

        let afterRejoin = try await coordinator.sync(
            event: event(now: now),
            participants: [rejoinedMembership],
            currentUserId: "source",
            sourceMembershipId: "source-membership"
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
            currentUserId: "source",
            sourceMembershipId: "source-membership"
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
            currentUserId: "source",
            sourceMembershipId: "source-membership"
        )

        XCTAssertEqual(afterJoin.scanned, 1)
        XCTAssertEqual(afterJoin.matchedPhotos, 1)
        let recipientPhotos = try await matches.myPhotos(eventId: "event", userId: "recipient")
        XCTAssertEqual(recipientPhotos.count, 1)
    }

    func testAmbiguityRosterChangeReopensNegativeWithoutRunningFaceDetectionAgain() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let matches = InMemoryMatchRepository()
        let detector = CountingDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(now: now, store: store, detector: detector, matches: matches)
        let recipient = participant(
            userId: "recipient",
            membershipId: "recipient-membership",
            identityId: "recipient-face",
            revisionLabel: "v1",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )
        let competitor = participant(
            userId: "competitor",
            membershipId: "competitor-membership",
            identityId: "competitor-face",
            revisionLabel: "v1",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )

        let ambiguous = try await coordinator.sync(
            event: event(now: now),
            participants: [recipient, competitor],
            currentUserId: "source",
            sourceMembershipId: "source-membership"
        )
        XCTAssertEqual(ambiguous.scanned, 1)
        XCTAssertEqual(ambiguous.matchedPhotos, 0)
        XCTAssertEqual(detector.detectionCount, 1)

        let afterCompetitorLeaves = try await coordinator.sync(
            event: event(now: now),
            participants: [recipient],
            currentUserId: "source",
            sourceMembershipId: "source-membership"
        )

        XCTAssertEqual(afterCompetitorLeaves.scanned, 1)
        XCTAssertEqual(afterCompetitorLeaves.matchedPhotos, 1)
        XCTAssertEqual(detector.detectionCount, 1, "Roster-only rematching must reuse the protected photo corpus")
        let recipientPhotos = try await matches.myPhotos(eventId: "event", userId: "recipient")
        XCTAssertEqual(recipientPhotos.count, 1)
    }

    func testSourceLeaveAndRejoinRebindsHistoricalPublicationWithoutRedetectingPhoto() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let matches = InMemoryMatchRepository()
        let detector = CountingDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(now: now, store: store, detector: detector, matches: matches)
        let recipient = participant(
            userId: "recipient",
            membershipId: "recipient-membership",
            identityId: "recipient-face",
            revisionLabel: "v1",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )

        let first = try await coordinator.sync(
            event: event(now: now),
            participants: [recipient],
            currentUserId: "source",
            sourceMembershipId: "source-membership-1"
        )
        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(first.matchedPhotos, 1)
        XCTAssertEqual(detector.detectionCount, 1)

        let afterSourceRejoin = try await coordinator.sync(
            event: event(now: now),
            participants: [recipient],
            currentUserId: "source",
            sourceMembershipId: "source-membership-2"
        )
        XCTAssertEqual(afterSourceRejoin.scanned, 1)
        XCTAssertEqual(afterSourceRejoin.matchedPhotos, 1)
        XCTAssertEqual(detector.detectionCount, 1)

        let shared = try await matches.sharedAlbum(eventId: "event")
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared.first?.sourceMembershipId, "source-membership-2")
        XCTAssertEqual(shared.first?.appearances.first?.recipientMembershipId, "recipient-membership")
    }
}
