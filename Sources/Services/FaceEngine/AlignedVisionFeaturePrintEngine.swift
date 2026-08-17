import CoreGraphics
import Foundation
import UIKit
import Vision

/// Interim, DEV-ONLY embedding engine: Apple's `VNGenerateImageFeaturePrint`
/// over a properly aligned face crop.
///
/// Honest framing: the feature-print is still a generic image-similarity
/// descriptor, NOT an identity-trained face model — that ceiling is unchanged
/// from V2. What changes is the floor: it now receives eye-aligned, correctly
/// oriented, fixed-size crops instead of loose, sometimes-rotated squares, so
/// same-person separation improves meaningfully even though the descriptor is
/// the same primitive. This exists to (a) make the app testable end-to-end
/// before a real model is dropped in, and (b) give the benchmark harness a
/// baseline to measure the real model against. `isIdentityGrade` is false, so
/// scanning treats results as development-grade exactly like V3 did.
public final class AlignedVisionFeaturePrintEngine: FaceEmbeddingEngine, @unchecked Sendable {

    public let modelVersion: Int
    public let expectedInputSize: Int
    public var isIdentityGrade: Bool { false }

    public init(modelVersion: Int = FaceModelPolicy.currentVersion, inputSize: Int = 160) {
        self.modelVersion = modelVersion
        self.expectedInputSize = inputSize
    }

    public func embedding(forAlignedFace image: CGImage) async throws -> FaceEmbedding {
        try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            guard let observation = request.results?.first else {
                throw AppError.faceEmbeddingFailed
            }

            let vector: [Float]
            switch observation.elementType {
            case .float:
                vector = observation.data.withUnsafeBytes { raw in
                    Array(raw.bindMemory(to: Float.self).prefix(observation.elementCount))
                }
            case .double:
                let doubles: [Double] = observation.data.withUnsafeBytes { raw in
                    Array(raw.bindMemory(to: Double.self).prefix(observation.elementCount))
                }
                vector = doubles.map(Float.init)
            default:
                throw AppError.faceEmbeddingFailed
            }

            guard let embedding = FaceEmbedding(vector) else {
                throw AppError.faceEmbeddingFailed
            }
            return embedding
        }.value
    }
}
