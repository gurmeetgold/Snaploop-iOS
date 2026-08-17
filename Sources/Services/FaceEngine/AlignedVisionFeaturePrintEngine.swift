import CoreGraphics
import Foundation
import UIKit
import Vision

/// Legacy development baseline only. v5 never selects this automatically.
public final class AlignedVisionFeaturePrintEngine: FaceEmbeddingEngine, @unchecked Sendable {
    public let identifier = "vision-feature-print-aligned-baseline"
    public let modelVersion: Int
    public let expectedInputSize: Int
    public var isAvailable: Bool { true }
    public var isIdentityGrade: Bool { false }

    public init(modelVersion: Int = 4, inputSize: Int = 160) {
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
