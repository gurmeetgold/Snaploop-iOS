import XCTest
@testable import SnapLoop

final class FaceMatcherTests: XCTestCase {

    // Use a config with known, easy-to-reason-about thresholds.
    private let config = RemoteConfigValues(
        matchConfidenceThreshold: 0.60,
        matchAmbiguityMargin: 0.06,
        minFaceSizeFraction: 0.05,
        maxAssetsPerSyncBatch: 100,
        thumbnailMaxPixelSize: 1024,
        thumbnailJPEGQuality: 0.7,
        signedURLTTLHours: 48,
        defaultEventDurationDays: 15,
        maxEventDurationDays: 30,
        eventGracePeriodDays: 3,
        maxParticipantsPerEvent: 250
    )

    private func emb(_ raw: [Float]) -> FaceEmbedding { FaceEmbedding(raw)! }

    private func participant(_ id: String, _ raw: [Float]) -> EventParticipant {
        let embedding = emb(raw)
        return EventParticipant(
            userId: id,
            displayName: id,
            faceEmbedding: embedding,
            faceTemplates: [
                FaceTemplate(embedding: embedding, pose: .center, quality: 1, createdAt: Date()),
                FaceTemplate(embedding: embedding, pose: .alternate, quality: 1, createdAt: Date())
            ],
            faceProfileVersion: FaceModelPolicy.currentVersion,
            joinedAt: Date()
        )
    }

    private func face(_ raw: [Float], size: Double = 0.5) -> DetectedFace {
        DetectedFace(embedding: emb(raw), sizeFraction: size)
    }

    // MARK: Threshold

    func testExactMatchAboveThresholdProducesAppearance() {
        let matcher = FaceMatcher(config: config)
        let alice = participant("alice", [1, 0, 0])
        let result = matcher.appearances(in: [face([1, 0, 0])], participants: [alice])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.participantUserId, "alice")
        XCTAssertEqual(result.first!.confidence, 1.0, accuracy: 1e-6)
    }

    func testBelowThresholdStaysSilent() {
        let matcher = FaceMatcher(config: config)
        // ~0.5 cosine — below 0.60 threshold.
        let alice = participant("alice", [1, 0, 0])
        let result = matcher.appearances(in: [face([1, 1, 0])], participants: [alice])
        XCTAssertTrue(result.isEmpty)
    }

    func testJustAboveThresholdMatches() {
        // cos = 0.62 target: pick a vector with dot ≈ 0.62 to [1,0].
        let matcher = FaceMatcher(config: config)
        let p = participant("p", [1, 0])
        let x: Float = 0.62, y = (1 - x * x).squareRoot()
        let result = matcher.appearances(in: [face([x, y])], participants: [p])
        XCTAssertEqual(result.first?.participantUserId, "p")
    }

    // MARK: Precision guards

    func testAmbiguousFaceBetweenTwoPeopleMatchesNobody() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0])
        let b = participant("b", [0.9, 0.2])
        let f = face([0.97, 0.12])
        let result = matcher.appearances(in: [f], participants: [a, b])
        XCTAssertTrue(result.isEmpty, "Ambiguous face must be dropped for precision")
    }

    func testClearWinnerBeatsRunnerUpByMargin() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0])
        let b = participant("b", [0, 1])
        let result = matcher.appearances(in: [face([1, 0])], participants: [a, b])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.participantUserId, "a")
    }

    func testTinyFaceIsIgnored() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0, 0])
        let result = matcher.appearances(in: [face([1, 0, 0], size: 0.01)], participants: [a])
        XCTAssertTrue(result.isEmpty, "Faces below min size fraction must be skipped")
    }

    // MARK: Aggregation

    func testMultipleFacesTakeHighestConfidencePerParticipant() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0])
        let weak: Float = 0.7, weakY = (1 - weak * weak).squareRoot()
        let faces = [face([weak, weakY]), face([1, 0])]
        let result = matcher.appearances(in: faces, participants: [a])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first!.confidence, 1.0, accuracy: 1e-6)
    }

    func testMultipleParticipantsInOnePhoto() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0, 0])
        let b = participant("b", [0, 1, 0])
        let result = matcher.appearances(in: [face([1, 0, 0]), face([0, 1, 0])],
                                         participants: [a, b])
        XCTAssertEqual(Set(result.map(\.participantUserId)), ["a", "b"])
    }

    // MARK: Robustness

    func testDimensionMismatchIsTreatedAsNoMatch() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0, 0, 0])
        let result = matcher.appearances(in: [face([1, 0, 0])], participants: [a])
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyInputsReturnEmpty() {
        let matcher = FaceMatcher(config: config)
        XCTAssertTrue(matcher.appearances(in: [], participants: []).isEmpty)
        XCTAssertTrue(matcher.appearances(in: [face([1, 0])], participants: []).isEmpty)
        XCTAssertTrue(matcher.appearances(in: [], participants: [participant("a", [1, 0])]).isEmpty)
    }

    func testResultsSortedByConfidenceDescending() {
        let matcher = FaceMatcher(config: config)
        let a = participant("a", [1, 0])
        let b = participant("b", [0, 1])
        let bx: Float = 0.2, by = (1 - bx * bx).squareRoot()
        let result = matcher.appearances(in: [face([1, 0]), face([bx, by])],
                                         participants: [a, b])
        XCTAssertEqual(result.map(\.participantUserId), ["a", "b"])
        XCTAssertGreaterThan(result[0].confidence, result[1].confidence)
    }
}
