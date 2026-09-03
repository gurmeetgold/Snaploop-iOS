import CoreGraphics
import CoreML
import Foundation
import Vision

/// Protects Vision's completion callback and VNImageRequestHandler.perform error
/// path from ever resuming the same checked continuation twice.
private final class VisionContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

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

        let embedding: FaceEmbedding = try await withCheckedThrowingContinuation { continuation in
            let gate = VisionContinuationGate<FaceEmbedding>(continuation)
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error {
                    Log.matching.error("AuraFace inference failed: \(String(describing: error), privacy: .public)")
                    gate.fail(AppError.faceEmbeddingFailed)
                    return
                }

                guard let observation = request.results?
                    .compactMap({ $0 as? VNCoreMLFeatureValueObservation })
                    .first,
                      let array = observation.featureValue.multiArrayValue,
                      array.count == 512 else {
                    gate.fail(AppError.faceEmbeddingFailed)
                    return
                }

                let vector = (0..<array.count).map { array[$0].floatValue }
                guard let embedding = FaceEmbedding(vector) else {
                    gate.fail(AppError.faceEmbeddingFailed)
                    return
                }
                gate.succeed(embedding)
            }

            request.imageCropAndScaleOption = .scaleFill

            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up)
                    .perform([request])
            } catch {
                // Vision can report through the completion callback and throw
                // from perform during interruption. The gate guarantees one
                // terminal continuation resume regardless of callback ordering.
                gate.fail(AppError.faceEmbeddingFailed)
            }
        }

        try Task.checkCancellation()
        return embedding
    }
}
