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

    private func bobRoster(identity: String = "bob-face", revision: String = "A") -> [EventParticipant] {
        [EventParticipant(userId: "bob", displayName: "Bob",
                          faceIdentityId: identity,
                          faceEmbedding: FaceEmbedding([1, 0, 0])!,
                          faceTemplates: [
                            FaceTemplate(id: "bob-\(revision)-center", embedding: FaceEmbedding([1, 0, 0])!, pose: .center, quality: 1, createdAt: Date(timeIntervalSince1970: 1)),
                            FaceTemplate(id: "bob-\(revision)-side", embedding: FaceEmbedding([1, 0, 0])!, pose: .sideA, quality: 1, createdAt: Date(timeIntervalSince1970: 1))
                          ],
                          faceProfileVersion: FaceModelPolicy.currentVersion,
                          joinedAt: Date(timeIntervalSince1970: 1))]
    }

    private func scanKey(
        eventId: String = "e1",
        userId: String = "alice",
        includeOwnMatches: Bool = false,
        preferenceRevision: String = "default",
        participants: [EventParticipant]? = nil
    ) -> String {
        let roster = participants ?? bobRoster()
        let rosterIdentity = roster
            .map { "\($0.userId)=\($0.stableFaceIdentityId)" }
            .sorted()
            .joined(separator: ";")
        return [
            eventId,
            userId,
            FaceModelPolicy.scanGeneration,
            "sharing-v5",
            includeOwnMatches ? "own-on" : "own-off",
            preferenceRevision,
            rosterIdentity,
        ].joined(separator: "::")
    }

    func testUploadsOnlyMatchesForOtherMembersAndMarksAllScanned() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = makeEvent(now: now)
        let roster = bobRoster()
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

        let summary = try await coordinator.sync(event: event, participants: roster, currentUserId: "alice")

        XCTAssertEqual(summary.scanned, 3)
        XCTAssertEqual(summary.matchedPhotos, 2)
        XCTAssertFalse(summary.hasMore)

        let bobPhotos = try await matchRepo.myPhotos(eventId: "e1", userId: "bob")
        XCTAssertEqual(Set(bobPhotos.map(\.assetLocalId)), ["a1", "a3"])
        XCTAssertTrue(bobPhotos.allSatisfy { match in
            match.appearances.allSatisfy {
                $0.faceIdentityId == roster[0].stableFaceIdentityId
                    && $0.faceProfileRevision == roster[0].faceProfileRevision
            }
        })
        let alicePhotos = try await matchRepo.myPhotos(eventId: "e1", userId: "alice")
        XCTAssertTrue(alicePhotos.isEmpty)
        XCTAssertEqual(scanStore.load(eventId: scanKey(participants: roster)).scannedCount, 3)
    }

    func testSecondPassIsCaughtUpAndRescansNothing() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let event = makeEvent(now: now)
        let assets = [PhotoAsset(id: "a1", creationDate: now)]
        let detector = ScriptedDetector(facesByAsset: ["a1": [face([1, 0, 0])]])
        let scanStore = InMemoryScanStateStore()
        let roster = bobRoster()

        let coordinator = CameraSyncCoordinator(
            config: StaticConfigProvider(.default),
            clock: FixedClock(now),
            photoLibrary: ScriptedLibrary(assetsList: assets),
            faceDetection: detector,
            thumbnailEncoder: PassthroughThumbnailEncoder(),
            matches: InMemoryMatchRepository(),
            scanStateStore: scanStore
        )

        _ = try await coordinator.sync(event: event, participants: roster, currentUserId: "alice")
        let second = try await coordinator.sync(event: event, participants: roster, currentUserId: "alice")

        XCTAssertEqual(second.scanned, 0)
        XCTAssertTrue(second.alreadyCaughtUp)
    }

    func testSameIdentityFaceSetupRefreshPreservesScanState() async throws {
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

        let oldRoster = bobRoster(identity: "bob-face", revision: "A")
        let refreshedRoster = bobRoster(identity: "bob-face", revision: "B")
        XCTAssertNotEqual(oldRoster[0].faceProfileRevision, refreshedRoster[0].faceProfileRevision)
        XCTAssertEqual(oldRoster[0].stableFaceIdentityId, refreshedRoster[0].stableFaceIdentityId)

        let first = try await coordinator.sync(event: event, participants: oldRoster, currentUserId: "alice")
        let afterRefresh = try await coordinator.sync(event: event, participants: refreshedRoster, currentUserId: "alice")

        XCTAssertEqual(first.scanned, 1)
        XCTAssertEqual(afterRefresh.scanned, 0, "Same-person Face Setup refresh must preserve prior scan state and positive matches")
        XCTAssertTrue(afterRefresh.alreadyCaughtUp)
    }

    func testNewFaceIdentityForcesFreshScanNamespace() async throws {
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

        let oldRoster = bobRoster(identity: "bob-face-A", revision: "A")
        let newIdentityRoster = bobRoster(identity: "bob-face-B", revision: "A")
        _ = try await coordinator.sync(event: event, participants: oldRoster, currentUserId: "alice")
        let afterIdentityChange = try await coordinator.sync(event: event, participants: newIdentityRoster, currentUserId: "alice")

        XCTAssertEqual(afterIdentityChange.scanned, 1, "A genuinely new face identity must not reuse the old identity's scan state")
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

final class BiometricConsentPolicyTests: XCTestCase {
    private func record(
        country: String,
        subdivision: String = "",
        age18: Bool = true,
        notice: Bool = true,
        ownFace: Bool = true,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> BiometricConsentRecord {
        BiometricConsentRecord(
            userId: "user",
            acceptedAt: Date(),
            expiresAt: expiresAt,
            jurisdictionCountry: country,
            jurisdictionSubdivision: subdivision,
            age18Attested: age18,
            noticeAcknowledged: notice,
            ownFaceAttested: ownFace
        )
    }

    private func faceProfile(ids: [String], vector: [Float], identityId: String = "identity") -> FaceProfile {
        let poses: [FaceTemplate.Pose] = [.center, .sideA, .sideB, .tilted, .alternate]
        let templates = zip(ids, poses).map { id, pose in
            FaceTemplate(id: id, embedding: FaceEmbedding(vector)!, pose: pose, quality: 1, createdAt: Date())
        }
        return FaceProfile(
            userId: "user",
            faceIdentityId: identityId,
            embedding: FaceEmbedding(vector)!,
            templates: templates,
            version: FaceModelPolicy.currentVersion,
            updatedAt: Date()
        )
    }

    func testIndiaIsSupportedWithoutStateSelection() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "IN").isFaceMatchAvailable)
        XCTAssertTrue(record(country: "IN").isActive)
        XCTAssertTrue(BiometricJurisdictionCatalog.subdivisions(for: "IN").isEmpty)
    }

    func testIndiaRejectsUnexpectedSubdivision() {
        XCTAssertFalse(BiometricJurisdiction(countryCode: "IN", subdivisionCode: "DL").isFaceMatchAvailable)
    }

    func testQuebecAndUnitedStatesAreBlocked() {
        XCTAssertFalse(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "QC").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "AK").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "IL").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "NY").isFaceMatchAvailable)
    }

    func testIndiaIsOnlySupportedLaunchJurisdiction() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "IN").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON").isFaceMatchAvailable)
    }

    func testLaunchCountryPickerContainsIndiaOnly() {
        XCTAssertEqual(BiometricJurisdictionCatalog.countries.map(\.code), ["IN"])
    }

    func testAgeAttestationIsRequiredForActiveConsent() {
        XCTAssertFalse(record(country: "IN", age18: false).isActive)
    }

    func testNoticeAcknowledgementIsRequiredForActiveConsent() {
        XCTAssertFalse(record(country: "IN", notice: false).isActive)
    }

    func testOwnFaceAttestationIsRequiredForActiveConsent() {
        XCTAssertFalse(record(country: "IN", ownFace: false).isActive)
    }

    func testExpiredConsentIsInactive() {
        XCTAssertFalse(record(country: "IN", expiresAt: Date().addingTimeInterval(-1)).isActive)
    }

    func testCanonicalDisclosureV5IsPinned() {
        XCTAssertEqual(BiometricConsentRecord.currentPolicyVersion, 5)
        XCTAssertEqual(BiometricConsentRecord.currentDisclosureId, "biometric-consent-v5")
        XCTAssertEqual(
            BiometricConsentRecord.currentDisclosureSHA256,
            "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f"
        )
    }

    func testFaceSetupReplacementAcceptsSameIdentityWithNewTemplateIds() {
        let existing = faceProfile(ids: ["a", "b", "c", "d", "e"], vector: [1, 0, 0])
        let replacement = faceProfile(ids: ["f", "g", "h", "i", "j"], vector: [1, 0, 0])
        XCTAssertTrue(FirebaseFaceProfileStore.isSameIdentityReplacement(newProfile: replacement, existingProfile: existing))
        XCTAssertNotEqual(existing.faceProfileRevision, replacement.faceProfileRevision)
        XCTAssertEqual(existing.stableFaceIdentityId, replacement.stableFaceIdentityId)
    }

    func testFaceSetupReplacementRejectsClearlyDifferentIdentity() {
        let existing = faceProfile(ids: ["a", "b", "c", "d", "e"], vector: [1, 0, 0])
        let differentPerson = faceProfile(ids: ["f", "g", "h", "i", "j"], vector: [0, 1, 0])
        XCTAssertFalse(FirebaseFaceProfileStore.isSameIdentityReplacement(newProfile: differentPerson, existingProfile: existing))
    }
}
