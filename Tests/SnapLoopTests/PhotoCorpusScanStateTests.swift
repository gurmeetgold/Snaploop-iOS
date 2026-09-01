import XCTest
@testable import SnapLoop

final class PhotoCorpusScanStateTests: XCTestCase {
    func testSameIdentityRevisionRefreshMarksHitsAndMissesStaleWithoutForgettingPriorPositive() {
        var cursor = RecipientMatchCursor(
            userId: "member",
            membershipEpoch: "membership-1",
            faceIdentityId: "face-1",
            faceProfileRevision: "revision-1",
            positiveAssetIds: ["positive"],
            negativeAssetIds: ["negative"]
        )

        cursor.reconcile(
            membershipEpoch: "membership-1",
            faceIdentityId: "face-1",
            faceProfileRevision: "revision-2"
        )

        XCTAssertEqual(cursor.positiveAssetIds, ["positive"])
        XCTAssertEqual(cursor.negativeAssetIds, ["negative"])
        XCTAssertEqual(cursor.staleAssetIds, ["positive", "negative"])
        XCTAssertTrue(cursor.wasMatched("positive"))
        XCTAssertFalse(cursor.hasEvaluated("positive"))
        XCTAssertFalse(cursor.hasEvaluated("negative"))
        XCTAssertEqual(cursor.faceProfileRevision, "revision-2")
    }

    func testMembershipGenerationChangeClearsPositiveNegativeAndStaleHistory() {
        var cursor = RecipientMatchCursor(
            userId: "member",
            membershipEpoch: "membership-1",
            faceIdentityId: "face-1",
            faceProfileRevision: "revision-1",
            positiveAssetIds: ["positive"],
            negativeAssetIds: ["negative"],
            staleAssetIds: ["positive"]
        )

        cursor.reconcile(
            membershipEpoch: "membership-2",
            faceIdentityId: "face-1",
            faceProfileRevision: "revision-1"
        )

        XCTAssertTrue(cursor.positiveAssetIds.isEmpty)
        XCTAssertTrue(cursor.negativeAssetIds.isEmpty)
        XCTAssertTrue(cursor.staleAssetIds.isEmpty)
        XCTAssertEqual(cursor.membershipEpoch, "membership-2")
    }

    func testNewFaceIdentityClearsPositiveNegativeAndStaleHistory() {
        var cursor = RecipientMatchCursor(
            userId: "member",
            membershipEpoch: "membership-1",
            faceIdentityId: "face-1",
            faceProfileRevision: "revision-1",
            positiveAssetIds: ["positive"],
            negativeAssetIds: ["negative"],
            staleAssetIds: ["negative"]
        )

        cursor.reconcile(
            membershipEpoch: "membership-1",
            faceIdentityId: "face-2",
            faceProfileRevision: "revision-2"
        )

        XCTAssertTrue(cursor.positiveAssetIds.isEmpty)
        XCTAssertTrue(cursor.negativeAssetIds.isEmpty)
        XCTAssertTrue(cursor.staleAssetIds.isEmpty)
        XCTAssertEqual(cursor.faceIdentityId, "face-2")
    }

    func testRosterAmbiguityChangeMarksAllRecipientOutcomesStale() {
        var state = ScanState(eventId: "state")
        state.reconcileRecipient(
            userId: "member",
            membershipEpoch: "membership",
            faceIdentityId: "face",
            faceProfileRevision: "revision"
        )
        state.markRecipientEvaluation(userId: "member", assetId: "positive", matched: true)
        state.markRecipientEvaluation(userId: "member", assetId: "negative", matched: false)

        state.markAllRecipientEvaluationsStale()

        let cursor = state.recipientCursor(userId: "member")
        XCTAssertEqual(cursor?.staleAssetIds, ["positive", "negative"])
        XCTAssertTrue(cursor?.wasMatched("positive") == true)
        XCTAssertEqual(
            state.pendingRecipientUserIds(for: "positive", among: ["member"]),
            ["member"]
        )
        XCTAssertEqual(
            state.pendingRecipientUserIds(for: "negative", among: ["member"]),
            ["member"]
        )
    }

    func testSharingGenerationReplayClearsOnlyPositiveHistory() {
        var state = ScanState(eventId: "state")
        state.reconcileRecipient(
            userId: "member",
            membershipEpoch: "membership",
            faceIdentityId: "face",
            faceProfileRevision: "revision"
        )
        state.markRecipientEvaluation(userId: "member", assetId: "positive", matched: true)
        state.markRecipientEvaluation(userId: "member", assetId: "negative", matched: false)

        XCTAssertTrue(state.hasPositiveRecipientEvaluations)
        state.clearPositiveRecipientEvaluations()

        let cursor = state.recipientCursor(userId: "member")
        XCTAssertTrue(cursor?.positiveAssetIds.isEmpty == true)
        XCTAssertEqual(cursor?.negativeAssetIds, ["negative"])
        XCTAssertFalse(state.hasPositiveRecipientEvaluations)
    }

    func testLegacyScanStateDecodesWithoutCorpusFields() throws {
        let data = Data(#"{"eventId":"legacy-state","scannedAssetIds":["asset-1"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ScanState.self, from: data)

        XCTAssertEqual(decoded.eventId, "legacy-state")
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.scannedAssetIds, ["asset-1"])
        XCTAssertTrue(decoded.photoCorpus.isEmpty)
        XCTAssertTrue(decoded.recipientCursors.isEmpty)
        XCTAssertNil(decoded.sourceMembershipEpoch)
        XCTAssertNil(decoded.sourceSharingRevision)
    }

    func testSchemaThreeRecipientCursorDecodesWithoutStaleField() throws {
        let data = Data(#"""
        {
          "eventId":"schema-3",
          "schemaVersion":3,
          "recipientCursors":{
            "member":{
              "userId":"member",
              "membershipEpoch":"membership",
              "faceIdentityId":"face",
              "faceProfileRevision":"revision",
              "positiveAssetIds":["positive"],
              "negativeAssetIds":["negative"]
            }
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(ScanState.self, from: data)
        let cursor = try XCTUnwrap(decoded.recipientCursor(userId: "member"))
        XCTAssertEqual(cursor.positiveAssetIds, ["positive"])
        XCTAssertEqual(cursor.negativeAssetIds, ["negative"])
        XCTAssertTrue(cursor.staleAssetIds.isEmpty)
    }

    func testCorpusStateRoundTripsWithCachedFacesAndRecipientCursors() throws {
        let embedding = FaceEmbedding(normalized: [1, 0, 0])
        var state = ScanState(eventId: "event::install::generation")
        state.cache(PhotoCorpusRecord(
            assetId: "asset",
            creationDate: Date(timeIntervalSince1970: 10),
            faces: [CachedPhotoFace(embedding: embedding, sizeFraction: 0.4)],
            processedAt: Date(timeIntervalSince1970: 20)
        ))
        state.reconcileRecipient(
            userId: "member",
            membershipEpoch: "membership",
            faceIdentityId: "identity",
            faceProfileRevision: "revision"
        )
        state.markRecipientEvaluation(userId: "member", assetId: "asset", matched: true)
        state.markAllRecipientEvaluationsStale()
        state.sourceMembershipEpoch = "source-membership"
        state.sourceSharingRevision = "id:sharing-generation"

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(state)
        let decoded = try PropertyListDecoder().decode(ScanState.self, from: encoded)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.sourceSharingRevision, "id:sharing-generation")
        XCTAssertEqual(decoded.corpusRecord(for: "asset")?.faces.first?.embedding, embedding)
        XCTAssertFalse(decoded.recipientCursor(userId: "member")?.hasEvaluated("asset") == true)
        XCTAssertTrue(decoded.recipientCursor(userId: "member")?.wasMatched("asset") == true)
    }
}
