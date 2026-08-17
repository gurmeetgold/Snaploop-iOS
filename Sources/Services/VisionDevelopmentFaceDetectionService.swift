import Foundation
import UIKit
import Vision

/// Face crop returned by Vision for Face Setup and diagnostics.
public struct FaceCropCandidate: Identifiable, Sendable {
    public let id: UUID
    public let jpegData: Data
    public let sizeFraction: Double

    public init(jpegData: Data, sizeFraction: Double) {
        self.id = UUID()
        self.jpegData = jpegData
        self.sizeFraction = sizeFraction
    }
}

/// Shared Vision-only face locator/cropper.
///
/// This deliberately contains no identity logic. It is safe to use in Face
/// Setup even after SnapLoop moves to a dedicated Core ML identity model.
public enum VisionFaceCropper {

    public static func candidates(
        in imageData: Data,
        jpegQuality: CGFloat = 0.94
    ) async throws -> [FaceCropCandidate] {
        try await Task.detached(priority: .userInitiated) {
            try candidatesSync(in: imageData, jpegQuality: jpegQuality)
        }.value
    }

    private static func candidatesSync(
        in imageData: Data,
        jpegQuality: CGFloat
    ) throws -> [FaceCropCandidate] {
        guard let image = UIImage(data: imageData),
              let cgImage = normalizedCGImage(from: image) else {
            throw AppError.faceEmbeddingFailed
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try handler.perform([request])

        let observations = request.results ?? []
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let shorterEdge = max(1, min(imageWidth, imageHeight))

        return observations.compactMap { observation in
            let box = observation.boundingBox

            // Vision uses a lower-left normalized origin; CGImage cropping uses
            // a top-left pixel origin.
            var rect = CGRect(
                x: box.minX * imageWidth,
                y: (1 - box.maxY) * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight
            )

            // Include hair/chin/context while keeping background small. A
            // square crop also makes descriptor generation much more stable.
            let side = max(rect.width, rect.height) * 1.55
            let center = CGPoint(x: rect.midX, y: rect.midY)
            rect = CGRect(
                x: center.x - side / 2,
                y: center.y - side / 2,
                width: side,
                height: side
            )

            let bounds = CGRect(
                x: 0,
                y: 0,
                width: imageWidth,
                height: imageHeight
            )

            rect = rect.intersection(bounds).integral
            guard rect.width >= 24,
                  rect.height >= 24,
                  let cropped = cgImage.cropping(to: rect) else {
                return nil
            }

            let result = UIImage(cgImage: cropped)
            guard let jpeg = result.jpegData(compressionQuality: jpegQuality) else {
                return nil
            }

            let rawFaceSize = max(
                box.width * imageWidth,
                box.height * imageHeight
            )

            return FaceCropCandidate(
                jpegData: jpeg,
                sizeFraction: Double(rawFaceSize / shorterEdge)
            )
        }
    }

    static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: image.size,
            format: format
        )

        let normalized = renderer.image { _ in
            image.draw(
                in: CGRect(
                    origin: .zero,
                    size: image.size
                )
            )
        }

        return normalized.cgImage
    }
}

/// DEBUG-only identity descriptor used to exercise the full SnapLoop pipeline.
///
/// Vision detects a face, SnapLoop crops that face tightly, then Vision creates
/// an image feature print for that face crop. This produces a real on-device
/// descriptor and lets us test scanning, matching, Storage, Firestore, My
/// Photos, Shared Album, and "Not Me" without cloud inference.
///
/// IMPORTANT: Apple's feature-print API is an image-similarity primitive, not a
/// face-recognition model trained for identity. Therefore this is intentionally
/// used only in DEBUG builds. Release builds continue to block camera matching
/// until the dedicated identity-trained Core ML model is installed.
public struct VisionDevelopmentFaceDetectionService: FaceDetectionService {

    public init() {}

    public var isReadyForMatching: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public func detectFaces(
        in imageData: Data
    ) async throws -> [DetectedFace] {
        #if DEBUG
        let candidates = try await VisionFaceCropper.candidates(in: imageData)

        var detected: [DetectedFace] = []
        detected.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let embedding = try await embeddingForFaceCrop(candidate.jpegData) {
                detected.append(
                    DetectedFace(
                        embedding: embedding,
                        sizeFraction: candidate.sizeFraction
                    )
                )
            }
        }

        return detected
        #else
        throw AppError.faceRecognitionNotReady
        #endif
    }

    public func embeddingForSelfie(
        _ imageData: Data
    ) async throws -> FaceEmbedding {
        #if DEBUG
        let candidates = try await VisionFaceCropper.candidates(in: imageData)

        guard !candidates.isEmpty else {
            throw AppError.noFaceDetectedInSelfie
        }

        guard candidates.count == 1 else {
            throw AppError.multipleFacesInSelfie
        }

        guard let embedding = try await embeddingForFaceCrop(
            candidates[0].jpegData
        ) else {
            throw AppError.faceEmbeddingFailed
        }

        return embedding
        #else
        throw AppError.faceRecognitionNotReady
        #endif
    }

    private func embeddingForFaceCrop(
        _ jpegData: Data
    ) async throws -> FaceEmbedding? {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: jpegData),
                  let cgImage = VisionFaceCropper.normalizedCGImage(from: image) else {
                throw AppError.faceEmbeddingFailed
            }

            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: .up
            )

            try handler.perform([request])

            guard let observation = request.results?.first else {
                throw AppError.faceEmbeddingFailed
            }

            let vector: [Float]

            switch observation.elementType {
            case .float:
                vector = observation.data.withUnsafeBytes { raw in
                    let typed = raw.bindMemory(to: Float.self)
                    return Array(typed.prefix(observation.elementCount))
                }

            case .double:
                let doubles: [Double] = observation.data.withUnsafeBytes { raw in
                    let typed = raw.bindMemory(to: Double.self)
                    return Array(typed.prefix(observation.elementCount))
                }
                vector = doubles.map(Float.init)

            default:
                throw AppError.faceEmbeddingFailed
            }

            return FaceEmbedding(vector)
        }.value
    }
}
