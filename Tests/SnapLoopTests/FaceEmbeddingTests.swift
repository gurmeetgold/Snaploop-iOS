import XCTest
@testable import SnapLoop

final class FaceEmbeddingTests: XCTestCase {

    func testInitNormalizesToUnitLength() {
        let e = FaceEmbedding([3, 4])!   // norm 5
        XCTAssertEqual(e.vector[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(e.vector[1], 0.8, accuracy: 1e-6)
    }

    func testInitRejectsEmptyAndZeroVectors() {
        XCTAssertNil(FaceEmbedding([]))
        XCTAssertNil(FaceEmbedding([0, 0, 0]))
    }

    func testCosineSimilarityOfIdenticalDirectionIsOne() {
        let a = FaceEmbedding([1, 2, 3])!
        let b = FaceEmbedding([2, 4, 6])!   // same direction, different magnitude
        XCTAssertEqual(a.cosineSimilarity(to: b)!, 1.0, accuracy: 1e-6)
    }

    func testCosineSimilarityOfOrthogonalIsZero() {
        let a = FaceEmbedding([1, 0])!
        let b = FaceEmbedding([0, 1])!
        XCTAssertEqual(a.cosineSimilarity(to: b)!, 0.0, accuracy: 1e-6)
    }

    func testCosineSimilarityIsNilOnDimensionMismatch() {
        let a = FaceEmbedding([1, 0, 0])!
        let b = FaceEmbedding([1, 0])!
        XCTAssertNil(a.cosineSimilarity(to: b))
    }

    func testSimilarityStaysWithinBounds() {
        let a = FaceEmbedding([1, 1, 1])!
        let b = FaceEmbedding([-1, -1, -1])!
        let sim = a.cosineSimilarity(to: b)!
        XCTAssertGreaterThanOrEqual(sim, -1.0)
        XCTAssertLessThanOrEqual(sim, 1.0)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-6)
    }
}
