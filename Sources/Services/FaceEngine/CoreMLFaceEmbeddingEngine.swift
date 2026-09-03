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
            // The current AuraFace Core ML graph can trigger an Apple Neural
            // Engine compiler failure (Espresso/ANE, signal 9) on some devices.
            // CPU + GPU keeps inference fully on-device while excluding the ANE
            // compilation path that was crashing every camera sync.
            configuration.computeUnits = .cpuAndGPU
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
        try Task.checkCancellation()

        // `VNImageRequestHandler.perform` is synchronous. Using a checked
        // continuation here is unnecessary and unsafe during app interruption:
        // Vision may report an error through the request callback and also throw
        // from `perform`, which is the exact double-resume crash seen on device.
        // Execute synchronously and inspect results after `perform` returns so
        // this function has exactly one completion/error path.
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill

        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up)
                .perform([request])
        } catch {
            Log.matching.error("AuraFace inference failed: \(String(describing: error), privacy: .public)")
            throw AppError.faceEmbeddingFailed
        }

        try Task.checkCancellation()

        guard let observation = request.results?
            .compactMap({ $0 as? VNCoreMLFeatureValueObservation })
            .first,
              let array = observation.featureValue.multiArrayValue,
              array.count == 512 else {
            throw AppError.faceEmbeddingFailed
        }

        let vector = (0..<array.count).map { array[$0].floatValue }
        guard let embedding = FaceEmbedding(vector) else {
            throw AppError.faceEmbeddingFailed
        }

        return embedding
    }
}
