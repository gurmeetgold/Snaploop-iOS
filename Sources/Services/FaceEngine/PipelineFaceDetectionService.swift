import CoreGraphics
import Foundation
import UIKit

public struct FacePipelineSample: Sendable, Identifiable {
    public let id: Int
    public let alignedJPEG: Data?
    public let sizeFraction: Double
    public let quality: Double?
    public let interocularPixels: Double
    public let yawDegrees: Double?
    public let pitchDegrees: Double?
    public let rollDegrees: Double?
    public let embedding: FaceEmbedding?
    public let rejectionReason: String?
}

public struct FacePipelineDiagnostics: Sendable {
    public let engineIdentifier: String
    public let modelVersion: Int
    public let facesDetected: Int
    public let facesWithUsableLandmarks: Int
    public let alignmentFailures: Int
    public let samples: [FacePipelineSample]

    public var embeddedCount: Int { samples.filter { $0.embedding != nil }.count }
}

/// Optional diagnostic surface for face engines. The production environment
/// wraps the real pipeline in a lazy loader, so diagnostics must travel through
/// a protocol instead of relying on a concrete-type cast in the UI.
public protocol FaceDiagnosticsProviding: Sendable {
    func diagnose(in imageData: Data) async throws -> FacePipelineDiagnostics
}

public final class PipelineFaceDetectionService: FaceDetectionService, FaceDiagnosticsProviding, @unchecked Sendable {
    private let engine: FaceEmbeddingEngine
    private let minScanQuality: Double
    private let minInterocularPixels: Double

    /// v5.1 intentionally lowers the old 18px hard floor to 12px. This does not
    /// declare a match; it only lets borderline distant faces reach AuraFace so
    /// the identity score + ambiguity rules can make the final precision-first
    /// decision. Very tiny faces still fail closed.
    public init(engine: FaceEmbeddingEngine, minScanQuality: Double = 0.15, minInterocularPixels: Double = 12) {
        self.engine = engine
        self.minScanQuality = minScanQuality
        self.minInterocularPixels = minInterocularPixels
    }

    public var isReadyForMatching: Bool { engine.isAvailable && engine.isIdentityGrade }
    public var engineIdentifier: String { engine.identifier }
    public var modelVersion: Int { engine.modelVersion }

    public func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
        let diagnostics = try await diagnose(in: imageData)
        return diagnostics.samples.compactMap { sample in
            guard let embedding = sample.embedding else { return nil }
            return DetectedFace(embedding: embedding, sizeFraction: sample.sizeFraction)
        }
    }

    public func diagnose(in imageData: Data) async throws -> FacePipelineDiagnostics {
        guard isReadyForMatching else { throw AppError.faceRecognitionNotReady }
        let alignment = try await FaceAligner.diagnostics(in: imageData, outputSize: engine.expectedInputSize)
        var samples: [FacePipelineSample] = []
        samples.reserveCapacity(alignment.alignedFaces.count)

        for (index, face) in alignment.alignedFaces.enumerated() {
            let alignedJPEG = UIImage(cgImage: face.image).jpegData(compressionQuality: 0.92)
            var reason: String?
            var embedding: FaceEmbedding?

            if let quality = face.quality, quality < minScanQuality {
                reason = String(format: "quality %.2f < %.2f", quality, minScanQuality)
            } else if face.interocularPixels < minInterocularPixels {
                reason = String(format: "eye distance %.1fpx < %.1fpx", face.interocularPixels, minInterocularPixels)
            } else if let yaw = face.yawDegrees, abs(yaw) > FaceModelPolicy.maximumRecognitionYawDegrees {
                reason = String(format: "yaw %.0f° outside ±%.0f°", yaw, FaceModelPolicy.maximumRecognitionYawDegrees)
            } else {
                do {
                    embedding = try await engine.embedding(forAlignedFace: face.image)
                } catch {
                    reason = "embedding failed"
                    Log.matching.error("Skipping one face after v5 embedding failure: \(String(describing: error), privacy: .public)")
                }
            }

            samples.append(FacePipelineSample(
                id: index,
                alignedJPEG: alignedJPEG,
                sizeFraction: face.sizeFraction,
                quality: face.quality,
                interocularPixels: face.interocularPixels,
                yawDegrees: face.yawDegrees,
                pitchDegrees: face.pitchDegrees,
                rollDegrees: face.rollDegrees,
                embedding: embedding,
                rejectionReason: reason
            ))
        }

        return FacePipelineDiagnostics(
            engineIdentifier: engine.identifier,
            modelVersion: engine.modelVersion,
            facesDetected: alignment.facesDetected,
            facesWithUsableLandmarks: alignment.facesWithUsableLandmarks,
            alignmentFailures: alignment.alignmentFailures,
            samples: samples
        )
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
