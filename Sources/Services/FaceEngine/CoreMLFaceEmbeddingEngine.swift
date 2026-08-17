import CoreGraphics
import CoreML
import Foundation
import Vision

/// Identity-trained AuraFace v1 embedding engine.
///
/// Expected bundled resource: `SnapLoopFaceEmbedding.mlmodel` (compiled by
/// Xcode to `.mlmodelc`). The model input is a 112x112 aligned RGB face and the
/// output is a 512-D embedding. The downloaded Core ML conversion has the
/// model's pixel normalization baked into the graph.
public final class CoreMLFaceEmbeddingEngine: FaceEmbeddingEngine, @unchecked Sendable {
    public static let modelResourceName = "SnapLoopFaceEmbedding"

    public let identifier = FaceModelPolicy.modelIdentifier
    public let modelVersion = FaceModelPolicy.currentVersion
    public let expectedInputSize = 112
    public var isAvailable: Bool { true }
    public var isIdentityGrade: Bool { true }

    private let visionModel: VNCoreMLModel

    public init?() {
        guard let url = Bundle.main.url(
            forResource: Self.modelResourceName,
            withExtension: "mlmodelc"
        ) else {
            Log.matching.notice("AuraFace v5 model is not bundled; identity matching is unavailable.")
            return nil
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: configuration)
            self.visionModel = try VNCoreMLModel(for: model)
        } catch {
            Log.matching.error("Could not load AuraFace v5 model: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func embedding(forAlignedFace image: CGImage) async throws -> FaceEmbedding {
        guard image.width == expectedInputSize,
              image.height == expectedInputSize else {
            throw AppError.faceEmbeddingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error {
                    Log.matching.error("AuraFace inference failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: AppError.faceEmbeddingFailed)
                    return
                }

                guard let observation = request.results?
                    .compactMap({ $0 as? VNCoreMLFeatureValueObservation })
                    .first,
                      let array = observation.featureValue.multiArrayValue,
                      array.count == 512 else {
                    continuation.resume(throwing: AppError.faceEmbeddingFailed)
                    return
                }

                let vector = (0..<array.count).map { array[$0].floatValue }
                guard let embedding = FaceEmbedding(vector) else {
                    continuation.resume(throwing: AppError.faceEmbeddingFailed)
                    return
                }
                continuation.resume(returning: embedding)
            }

            request.imageCropAndScaleOption = .scaleFill

            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up)
                    .perform([request])
            } catch {
                continuation.resume(throwing: AppError.faceEmbeddingFailed)
            }
        }
    }
}
