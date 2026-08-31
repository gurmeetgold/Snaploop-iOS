import XCTest
@testable import SnapLoop

/// Reproduces the two lifecycle gaps that the upcoming photo-corpus + recipient-
/// cursor migration must fix. These are expected failures on the legacy
/// scannedAssetIds implementation, so they document the bug without making the
/// current release-hardening test suite red before the replacement lands.
final class ScannerLifecycleKnownLimitationsTests: XCTestCase {
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
        identityId: String,
        revisionLabel: String,
        vector: [Float],
        joinedAt: Date
    ) -> EventParticipant {
        let embedding = FaceEmbedding(vector)!
        return EventParticipant(
            userId: "recipient",
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
        detector: ScriptedDetector
    ) -> CameraSyncCoordinator {
        CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ScriptedLibrary(
                assetsList: [PhotoAsset(id: "asset", creationDate: now)]
            ),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: InMemoryMatchRepository(),
            scanStateStore: store
        )
    }

    func testKnownGap_SameIdentityFaceSetupRefreshMustReevaluatePreviouslyNegativePhoto() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let detector = ScriptedDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(now: now, store: store, detector: detector)
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

        XCTExpectFailure(
            "Legacy scan state keys only on stable face identity, so a same-person Face Setup revision does not revisit a photo that previously failed matching. Recipient cursors must make this pass."
        )
        XCTAssertEqual(afterRefresh.scanned, 1)
    }

    func testKnownGap_LeaveAndRejoinMustCreateFreshHistoricalEvaluation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryScanStateStore()
        let detector = ScriptedDetector(facesByAsset: [
            "asset": [face([1, 0, 0])]
        ])
        let coordinator = coordinator(now: now, store: store, detector: detector)
        let firstMembership = participant(
            identityId: "stable-face",
            revisionLabel: "same",
            vector: [1, 0, 0],
            joinedAt: Date(timeIntervalSince1970: 1)
        )
        let rejoinedMembership = participant(
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
        XCTAssertNotEqual(firstMembership.joinedAt, rejoinedMembership.joinedAt)
        XCTAssertEqual(firstMembership.stableFaceIdentityId, rejoinedMembership.stableFaceIdentityId)

        let afterRejoin = try await coordinator.sync(
            event: event(now: now),
            participants: [rejoinedMembership],
            currentUserId: "source"
        )

        XCTExpectFailure(
            "Legacy scan state ignores membership generation/joinedAt, so leave + rejoin with the same stable face identity can reuse stale processed-photo state. membershipId + recipient cursors must make this pass."
        )
        XCTAssertEqual(afterRejoin.scanned, 1)
    }
}
