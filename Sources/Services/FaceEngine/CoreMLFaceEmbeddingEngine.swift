import CoreML
import CoreGraphics
import Foundation
import Vision

/// Production identity-embedding engine: runs a bundled Core ML face model over
/// an aligned crop and returns its L2-normalized embedding.
///
/// This is the seam the whole rebuild exists to enable. It expects a compiled
/// Core ML model resource (`SnapLoopFaceEmbedding.mlpackage`, added to the
/// SnapLoop target — see `tools/FACE_MODEL.md` for how to produce one). No such
/// model ships in the repo, so on a normal checkout `init?` returns nil and the
/// app cleanly falls back to the dev engine (DEBUG) or refuses matching
/// (release) — it never silently pretends to be identity-grade.
///
/// The model is expected to take an image input and emit a single MultiArray
/// embedding. Feature names are discovered from the model description, so any
/// ArcFace/MobileFaceNet-style export works without hardcoding I/O names.
public final class CoreMLFaceEmbeddingEngine: FaceEmbeddingEngine, @unchecked Sendable {

    public static let modelResourceName = "SnapLoopFaceEmbedding"

    private let visionModel: VNCoreMLModel
    public let modelVersion: Int
    public let expectedInputSize: Int
    public var isIdentityGrade: Bool { true }

    /// Fails (returns nil) when no bundled model is present, so callers can
    /// choose a fallback rather than crash.
    public init?(modelVersion: Int = FaceModelPolicy.currentVersion, inputSize: Int = 112) {
        guard let url = Self.compiledModelURL() else {
            Log.matching.notice("No bundled face model; CoreMLFaceEmbeddingEngine unavailable.")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            // Let Core ML pick the Neural Engine when available; fall back
            // automatically otherwise (see `preferredComputeUnits`).
            config.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: config)
            self.visionModel = try VNCoreMLModel(for: model)
            self.modelVersion = modelVersion
            self.expectedInputSize = inputSize
        } catch {
            Log.matching.error("Failed to load face model: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func compiledModelURL() -> URL? {
        // A .mlpackage/.mlmodel added to the target is compiled to .mlmodelc.
        Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc")
    }

    public func embedding(forAlignedFace image: CGImage) async throws -> FaceEmbedding {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error {
                    continuation.resume(throwing: AppError.faceEmbeddingFailed)
                    Log.matching.error("Face embedding inference failed: \(String(describing: error), privacy: .public)")
                    return
                }
                guard let feature = request.results?
                    .compactMap({ $0 as? VNCoreMLFeatureValueObservation })
                    .first,
                    let multiArray = feature.featureValue.multiArrayValue else {
                    continuation.resume(throwing: AppError.faceEmbeddingFailed)
                    return
                }
                guard let embedding = FaceEmbedding(Self.floats(from: multiArray)) else {
                    continuation.resume(throwing: AppError.faceEmbeddingFailed)
                    return
                }
                continuation.resume(returning: embedding)
            }
            // The crop is already square and aligned; fill without re-cropping.
            request.imageCropAndScaleOption = .scaleFill
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            } catch {
                continuation.resume(throwing: AppError.faceEmbeddingFailed)
            }
        }
    }

    private static func floats(from array: MLMultiArray) -> [Float] {
        let count = array.count
        if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        // Fall back through NSNumber for double/other element types.
        return (0..<count).map { array[$0].floatValue }
    }
}
