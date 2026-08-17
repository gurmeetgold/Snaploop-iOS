import CoreGraphics
import Foundation
import UIKit
import Vision

public struct AlignedFace: Sendable {
    public let image: CGImage
    public let sizeFraction: Double
    public let quality: Double?
    public let interocularPixels: Double
    public let yawDegrees: Double?
    public let pitchDegrees: Double?
    public let rollDegrees: Double?
}

public struct FaceAlignmentDiagnostics: Sendable {
    public let facesDetected: Int
    public let facesWithUsableLandmarks: Int
    public let alignmentFailures: Int
    public let alignedFaces: [AlignedFace]
}

/// Canonical five-point alignment for ArcFace-family embedding models.
public enum FaceAligner {
    private static let canonical112: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041)
    ]

    public static func alignedFaces(in imageData: Data, outputSize: Int) async throws -> [AlignedFace] {
        try await diagnostics(in: imageData, outputSize: outputSize).alignedFaces
    }

    public static func diagnostics(in imageData: Data, outputSize: Int) async throws -> FaceAlignmentDiagnostics {
        try await Task.detached(priority: .userInitiated) {
            try diagnoseSync(imageData: imageData, outputSize: outputSize)
        }.value
    }

    private static func diagnoseSync(imageData: Data, outputSize: Int) throws -> FaceAlignmentDiagnostics {
        guard let ui = UIImage(data: imageData),
              let upright = uprightImage(ui),
              let cg = upright.cgImage else {
            throw AppError.faceEmbeddingFailed
        }

        let landmarkRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try handler.perform([landmarkRequest])
        try? handler.perform([qualityRequest])

        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let shorter = max(1, min(width, height))
        let qualities = qualityRequest.results ?? []
        let scale = CGFloat(outputSize) / 112.0
        let target = canonical112.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        let observations = landmarkRequest.results ?? []

        var alignedFaces: [AlignedFace] = []
        var usableLandmarks = 0
        var alignmentFailures = 0

        for face in observations {
            guard let source = fivePoints(face, width: width, height: height) else {
                alignmentFailures += 1
                continue
            }
            usableLandmarks += 1

            guard let transform = estimateSimilarity(source: source, target: target),
                  let aligned = render(upright, transform: transform, outputSize: outputSize) else {
                alignmentFailures += 1
                continue
            }

            let interocular = hypot(source[1].x - source[0].x, source[1].y - source[0].y)
            let facePixels = max(face.boundingBox.width * width, face.boundingBox.height * height)
            let quality = nearestQuality(to: face, from: qualities)
            let yaw = face.yaw.map { $0.doubleValue * 180 / .pi }
            let pitch = face.pitch.map { $0.doubleValue * 180 / .pi }
            let roll = face.roll.map { $0.doubleValue * 180 / .pi }

            alignedFaces.append(AlignedFace(
                image: aligned,
                sizeFraction: Double(facePixels / shorter),
                quality: quality,
                interocularPixels: Double(interocular),
                yawDegrees: yaw,
                pitchDegrees: pitch,
                rollDegrees: roll
            ))
        }

        return FaceAlignmentDiagnostics(
            facesDetected: observations.count,
            facesWithUsableLandmarks: usableLandmarks,
            alignmentFailures: alignmentFailures,
            alignedFaces: alignedFaces
        )
    }

    private static func fivePoints(_ face: VNFaceObservation, width: CGFloat, height: CGFloat) -> [CGPoint]? {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let nose = landmarks.nose,
              let lips = landmarks.outerLips else { return nil }

        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map { p in
                let nx = face.boundingBox.minX + CGFloat(p.x) * face.boundingBox.width
                let ny = face.boundingBox.minY + CGFloat(p.y) * face.boundingBox.height
                return CGPoint(x: nx * width, y: (1 - ny) * height)
            }
        }
        func mean(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
            let ps = points(region)
            guard !ps.isEmpty else { return nil }
            let sx = ps.reduce(CGFloat.zero) { $0 + $1.x }
            let sy = ps.reduce(CGFloat.zero) { $0 + $1.y }
            return CGPoint(x: sx / CGFloat(ps.count), y: sy / CGFloat(ps.count))
        }

        guard let eyeA = mean(leftEye), let eyeB = mean(rightEye), let nosePoint = mean(nose) else { return nil }
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        let mouth = points(lips)
        guard let mouthLeft = mouth.min(by: { $0.x < $1.x }),
              let mouthRight = mouth.max(by: { $0.x < $1.x }) else { return nil }
        return [eyes[0], eyes[1], nosePoint, mouthLeft, mouthRight]
    }

    static func estimateSimilarity(source: [CGPoint], target: [CGPoint]) -> CGAffineTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)
        let sMean = CGPoint(x: source.reduce(0) { $0 + $1.x } / n, y: source.reduce(0) { $0 + $1.y } / n)
        let tMean = CGPoint(x: target.reduce(0) { $0 + $1.x } / n, y: target.reduce(0) { $0 + $1.y } / n)

        var a: CGFloat = 0, b: CGFloat = 0, denom: CGFloat = 0
        for i in source.indices {
            let px = source[i].x - sMean.x, py = source[i].y - sMean.y
            let qx = target[i].x - tMean.x, qy = target[i].y - tMean.y
            a += px * qx + py * qy
            b += px * qy - py * qx
            denom += px * px + py * py
        }
        guard denom > 0 else { return nil }
        let mag = hypot(a, b)
        guard mag > 0 else { return nil }
        let scale = mag / denom
        let angle = atan2(b, a)
        let c = cos(angle) * scale, s = sin(angle) * scale
        let tx = tMean.x - (c * sMean.x - s * sMean.y)
        let ty = tMean.y - (s * sMean.x + c * sMean.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    private static func render(_ source: UIImage, transform: CGAffineTransform, outputSize: Int) -> CGImage? {
        let size = CGSize(width: outputSize, height: outputSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.concatenate(transform)
            source.draw(at: .zero)
        }.cgImage
    }

    private static func nearestQuality(to face: VNFaceObservation, from candidates: [VNFaceObservation]) -> Double? {
        candidates.max { iou($0.boundingBox, face.boundingBox) < iou($1.boundingBox, face.boundingBox) }?.faceCaptureQuality.map(Double.init)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let ia = intersection.width * intersection.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? ia / ua : 0
    }

    static func uprightImage(_ image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
