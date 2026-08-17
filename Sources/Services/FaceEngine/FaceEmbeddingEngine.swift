import CoreGraphics
import Foundation

/// Neural identity descriptor seam. Detection/alignment happen before this.
public protocol FaceEmbeddingEngine: Sendable {
    var identifier: String { get }
    var modelVersion: Int { get }
    var isAvailable: Bool { get }
    var isIdentityGrade: Bool { get }
    var expectedInputSize: Int { get }
    func embedding(forAlignedFace image: CGImage) async throws -> FaceEmbedding
}
