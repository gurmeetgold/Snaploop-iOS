import CoreGraphics
import Foundation

public final class PipelineFaceDetectionService: FaceDetectionService, @unchecked Sendable {
    private let engine: FaceEmbeddingEngine
    private let minScanQuality: Double
    private let minInterocularPixels: Double

    public init(engine: FaceEmbeddingEngine, minScanQuality: Double = 0.20, minInterocularPixels: Double = 18) {
        self.engine = engine
        self.minScanQuality = minScanQuality
        self.minInterocularPixels = minInterocularPixels
    }

    public var isReadyForMatching: Bool { engine.isAvailable && engine.isIdentityGrade }
    public var engineIdentifier: String { engine.identifier }
    public var modelVersion: Int { engine.modelVersion }

    public func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
        guard isReadyForMatching else { throw AppError.faceRecognitionNotReady }
        let aligned = try await FaceAligner.alignedFaces(in: imageData, outputSize: engine.expectedInputSize)
        var detected: [DetectedFace] = []
        detected.reserveCapacity(aligned.count)

        for face in aligned {
            if let quality = face.quality, quality < minScanQuality { continue }
            if face.interocularPixels < minInterocularPixels { continue }
            if let yaw = face.yawDegrees, abs(yaw) > FaceModelPolicy.maximumRecognitionYawDegrees { continue }
            do {
                let embedding = try await engine.embedding(forAlignedFace: face.image)
                detected.append(DetectedFace(embedding: embedding, sizeFraction: face.sizeFraction))
            } catch {
                Log.matching.error("Skipping one face after v5 embedding failure: \(String(describing: error), privacy: .public)")
            }
        }
        return detected
    }

    public func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
        guard isReadyForMatching else { throw AppError.faceRecognitionNotReady }
        let aligned = try await FaceAligner.alignedFaces(in: imageData, outputSize: engine.expectedInputSize)
        guard !aligned.isEmpty else { throw AppError.noFaceDetectedInSelfie }
        guard aligned.count == 1 else { throw AppError.multipleFacesInSelfie }
        return try await engine.embedding(forAlignedFace: aligned[0].image)
    }

    public func alignedFaces(in imageData: Data) async throws -> [AlignedFace] {
        try await FaceAligner.alignedFaces(in: imageData, outputSize: engine.expectedInputSize)
    }

    public static func makeDefault() -> FaceDetectionService {
        guard let coreML = CoreMLFaceEmbeddingEngine() else {
            return StubFaceDetectionService()
        }
        return PipelineFaceDetectionService(engine: coreML)
    }
}
