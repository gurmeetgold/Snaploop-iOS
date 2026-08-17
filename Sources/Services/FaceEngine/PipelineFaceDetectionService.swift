import CoreGraphics
import Foundation

/// The rebuilt recognition pipeline, behind the existing `FaceDetectionService`
/// seam so scanning, matching, storage, and the UI are untouched:
///
///   image → detect + landmarks → geometric alignment → aligned crop
///         → identity embedding (pluggable engine) → L2-normalized embedding
///
/// The embedding step is a `FaceEmbeddingEngine`, so the exact same pipeline
/// runs the interim aligned feature-print (dev) or a real Core ML identity
/// model (production) with no other code change.
public final class PipelineFaceDetectionService: FaceDetectionService, @unchecked Sendable {

    private let engine: FaceEmbeddingEngine
    /// Faces below this Vision capture-quality are dropped from *scanning* (not
    /// enrollment, which has its own stricter guided gate). nil quality (older
    /// OS / no score) is treated as "unknown, keep".
    private let minScanQuality: Double
    /// Faces whose eyes are closer than this in pixels are too small/distant to
    /// trust for identity.
    private let minInterocularPixels: Double

    public init(
        engine: FaceEmbeddingEngine,
        minScanQuality: Double = 0.30,
        minInterocularPixels: Double = 18
    ) {
        self.engine = engine
        self.minScanQuality = minScanQuality
        self.minInterocularPixels = minInterocularPixels
    }

    public var isReadyForMatching: Bool {
        if engine.isIdentityGrade { return true }
        // A non-identity engine (aligned feature-print) is allowed to drive
        // matching only in DEBUG, purely for end-to-end testing — never in a
        // shipped build, matching the previous V3 contract.
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
        let aligned = try await FaceAligner.alignedFaces(
            in: imageData, outputSize: engine.expectedInputSize)

        var detected: [DetectedFace] = []
        detected.reserveCapacity(aligned.count)

        for face in aligned {
            if let quality = face.quality, quality < minScanQuality { continue }
            if face.interocularPixels < minInterocularPixels { continue }
            do {
                let embedding = try await engine.embedding(forAlignedFace: face.image)
                detected.append(DetectedFace(embedding: embedding, sizeFraction: face.sizeFraction))
            } catch {
                // One bad face must not drop the rest of a group photo.
                Log.matching.error("Skipping a face during scan: \(String(describing: error), privacy: .public)")
            }
        }
        return detected
    }

    public func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
        let aligned = try await FaceAligner.alignedFaces(
            in: imageData, outputSize: engine.expectedInputSize)

        guard !aligned.isEmpty else { throw AppError.noFaceDetectedInSelfie }
        guard aligned.count == 1 else { throw AppError.multipleFacesInSelfie }
        return try await engine.embedding(forAlignedFace: aligned[0].image)
    }

    /// Aligned-crop accessor for the benchmark/diagnostic screen — lets the Face
    /// Test tool show exactly what the model sees.
    public func alignedFaces(in imageData: Data) async throws -> [AlignedFace] {
        try await FaceAligner.alignedFaces(in: imageData, outputSize: engine.expectedInputSize)
    }

    /// Factory that picks the best available engine: the real Core ML model if
    /// one is bundled, otherwise the interim aligned feature-print in DEBUG,
    /// otherwise a not-ready service in release.
    public static func makeDefault() -> FaceDetectionService {
        if let coreML = CoreMLFaceEmbeddingEngine() {
            return PipelineFaceDetectionService(engine: coreML)
        }
        #if DEBUG
        return PipelineFaceDetectionService(engine: AlignedVisionFeaturePrintEngine())
        #else
        return StubFaceDetectionService()
        #endif
    }
}
