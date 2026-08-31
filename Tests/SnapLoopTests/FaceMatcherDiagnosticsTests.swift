import XCTest
@testable import SnapLoop

final class FaceMatcherDiagnosticsTests: XCTestCase {
    private func participant(
        userId: String,
        identityId: String,
        vector: [Float]
    ) -> EventParticipant {
        let embedding = FaceEmbedding(vector)!
        return EventParticipant(
            userId: userId,
            displayName: nil,
            faceIdentityId: identityId,
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(
                    id: "\(userId)-center",
                    embedding: embedding,
                    pose: .center,
                    quality: 1,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                FaceTemplate(
                    id: "\(userId)-side",
                    embedding: embedding,
                    pose: .sideA,
                    quality: 1,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func face(_ vector: [Float], sizeFraction: Double = 0.5) -> DetectedFace {
        DetectedFace(embedding: FaceEmbedding(vector)!, sizeFraction: sizeFraction)
    }

    func testDiagnosticsCountAcceptedFaceWithoutIdentityBearingOutput() {
        let matcher = FaceMatcher(config: .default)
        let result = matcher.appearancesWithDiagnostics(
            in: [face([1, 0, 0])],
            participants: [participant(userId: "p1", identityId: "identity-1", vector: [1, 0, 0])]
        )

        XCTAssertEqual(result.appearances.count, 1)
        XCTAssertEqual(result.diagnostics.detectedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.eligibleFaceCount, 1)
        XCTAssertEqual(result.diagnostics.acceptedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.belowThresholdFaceCount, 0)
        XCTAssertEqual(result.diagnostics.ambiguityRejectedFaceCount, 0)
        XCTAssertEqual(result.diagnostics.rosterCount, 1)
        XCTAssertEqual(result.diagnostics.matchableParticipantCount, 1)
    }

    func testDiagnosticsCountBelowThresholdWithoutRecordingScores() {
        let matcher = FaceMatcher(config: .default)
        let result = matcher.appearancesWithDiagnostics(
            in: [face([0, 1, 0])],
            participants: [participant(userId: "p1", identityId: "identity-1", vector: [1, 0, 0])]
        )

        XCTAssertTrue(result.appearances.isEmpty)
        XCTAssertEqual(result.diagnostics.detectedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.acceptedFaceCount, 0)
        XCTAssertEqual(result.diagnostics.belowThresholdFaceCount, 1)
        XCTAssertEqual(result.diagnostics.ambiguityRejectedFaceCount, 0)
    }

    func testDiagnosticsCountAmbiguityRejection() {
        let matcher = FaceMatcher(config: .default)
        let result = matcher.appearancesWithDiagnostics(
            in: [face([1, 0, 0])],
            participants: [
                participant(userId: "p1", identityId: "identity-1", vector: [1, 0, 0]),
                participant(userId: "p2", identityId: "identity-2", vector: [1, 0, 0])
            ]
        )

        XCTAssertTrue(result.appearances.isEmpty)
        XCTAssertEqual(result.diagnostics.detectedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.acceptedFaceCount, 0)
        XCTAssertEqual(result.diagnostics.belowThresholdFaceCount, 0)
        XCTAssertEqual(result.diagnostics.ambiguityRejectedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.rosterCount, 2)
        XCTAssertEqual(result.diagnostics.matchableParticipantCount, 2)
    }

    func testDiagnosticsCountTinyFaceRejectionBeforeMatching() {
        let matcher = FaceMatcher(config: .default)
        let result = matcher.appearancesWithDiagnostics(
            in: [face([1, 0, 0], sizeFraction: 0)],
            participants: [participant(userId: "p1", identityId: "identity-1", vector: [1, 0, 0])]
        )

        XCTAssertTrue(result.appearances.isEmpty)
        XCTAssertEqual(result.diagnostics.detectedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.sizeRejectedFaceCount, 1)
        XCTAssertEqual(result.diagnostics.eligibleFaceCount, 0)
        XCTAssertEqual(result.diagnostics.acceptedFaceCount, 0)
        XCTAssertEqual(result.diagnostics.belowThresholdFaceCount, 0)
    }
}
