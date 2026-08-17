import CoreGraphics
import Foundation
import UIKit
import Vision

/// One aligned face ready for embedding.
public struct AlignedFace: Sendable {
    /// Square, eye-normalized crop at the embedding model's expected input size.
    public let image: CGImage
    /// Face size as a fraction of the source image's shorter edge (for the
    /// existing `minFaceSizeFraction` gate).
    public let sizeFraction: Double
    /// Vision capture-quality in 0...1 when available (blur/exposure proxy).
    public let quality: Double?
    /// Absolute inter-ocular distance in source pixels — a hard proxy for "is
    /// this face big enough to be worth trusting".
    public let interocularPixels: Double
}

/// Landmark-based face alignment — the piece missing from V2/V3.
///
/// Root cause it fixes: the previous pipeline cropped a 1.55× square around the
/// raw face rectangle and always ran Vision at `orientation: .up`. That fed the
/// descriptor faces that were (a) rotated whenever the source photo carried EXIF
/// orientation, and (b) never eye-aligned, so the same person at two head
/// angles produced very different descriptors. Any identity model — generic or
/// trained — needs a canonicalized input to separate identities; this provides
/// it.
///
/// Method: detect landmarks, take both eye centers, and apply the 2-point
/// similarity transform (rotation + uniform scale + translation) that maps them
/// onto fixed canonical positions in a square output. Everything is done in
/// UIKit top-left pixel space to avoid the flipped-origin bugs that plague
/// Core Image alignment code. Orientation is baked upright *before* Vision runs.
public enum FaceAligner {

    /// Canonical eye positions as fractions of the square output. Eyes on a
    /// horizontal line at 40% height, symmetric about center with 30% spacing —
    /// the de-facto ArcFace-family convention.
    private static let leftEyeDest = CGPoint(x: 0.35, y: 0.40)
    private static let rightEyeDest = CGPoint(x: 0.65, y: 0.40)

    /// Aligns every detectable face in an image (group photos included).
    public static func alignedFaces(
        in imageData: Data,
        outputSize: Int
    ) async throws -> [AlignedFace] {
        try await Task.detached(priority: .userInitiated) {
            try alignSync(imageData: imageData, outputSize: outputSize)
        }.value
    }

    private static func alignSync(imageData: Data, outputSize: Int) throws -> [AlignedFace] {
        guard let ui = UIImage(data: imageData),
              let upright = uprightImage(ui),
              let cg = upright.cgImage else {
            throw AppError.faceEmbeddingFailed
        }

        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let shorterEdge = max(1, min(width, height))

        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        // Capture quality is best-effort; alignment must not fail if it errors.
        try? handler.perform([quality])
        try handler.perform([landmarks])

        let observations = landmarks.results ?? []
        let qualityByIndex = (quality.results ?? []).enumerated().reduce(into: [Int: Double]()) {
            if let q = $1.element.faceCaptureQuality { $0[$1.offset] = Double(q) }
        }

        var results: [AlignedFace] = []
        for (index, obs) in observations.enumerated() {
            guard let eyes = eyeCentersInPixels(obs, imageWidth: width, imageHeight: height) else {
                continue   // no usable landmarks → skip rather than mis-align
            }
            let interocular = hypot(eyes.right.x - eyes.left.x, eyes.right.y - eyes.left.y)
            guard interocular > 1 else { continue }   // degenerate

            guard let aligned = warp(
                source: upright,
                leftEye: eyes.left,
                rightEye: eyes.right,
                outputSize: outputSize
            ) else { continue }

            let faceSize = max(obs.boundingBox.width * width, obs.boundingBox.height * height)
            results.append(AlignedFace(
                image: aligned,
                sizeFraction: Double(faceSize / shorterEdge),
                quality: qualityByIndex[index],
                interocularPixels: Double(interocular)
            ))
        }
        return results
    }

    // MARK: - Landmarks → pixel eye centers

    private static func eyeCentersInPixels(
        _ obs: VNFaceObservation,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> (left: CGPoint, right: CGPoint)? {
        guard let landmarks = obs.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye else {
            return nil
        }
        // Landmark points are normalized within the face bounding box, in
        // Vision's lower-left origin. Convert region centroid → normalized image
        // coords → top-left pixel coords.
        func pixelCentroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = region.normalizedPoints
            guard !pts.isEmpty else { return .zero }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y)) }
            let mean = CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
            let box = obs.boundingBox
            let nx = box.origin.x + mean.x * box.width
            let ny = box.origin.y + mean.y * box.height
            return CGPoint(x: nx * imageWidth, y: (1 - ny) * imageHeight)
        }
        // Vision's "leftEye" is the subject's left eye, which appears on the
        // right side of the image. Assign by actual x so the transform is
        // never mirrored.
        let a = pixelCentroid(leftEye)
        let b = pixelCentroid(rightEye)
        return a.x <= b.x ? (left: a, right: b) : (left: b, right: a)
    }

    // MARK: - Similarity-transform warp (top-left pixel space)

    private static func warp(
        source: UIImage,
        leftEye: CGPoint,
        rightEye: CGPoint,
        outputSize: Int
    ) -> CGImage? {
        let n = CGFloat(outputSize)
        let destLeft = CGPoint(x: leftEyeDest.x * n, y: leftEyeDest.y * n)
        let destRight = CGPoint(x: rightEyeDest.x * n, y: rightEyeDest.y * n)

        let srcDx = rightEye.x - leftEye.x
        let srcDy = rightEye.y - leftEye.y
        let srcDist = hypot(srcDx, srcDy)
        let destDist = destRight.x - destLeft.x
        guard srcDist > 0.0001 else { return nil }

        let scale = destDist / srcDist
        // Rotate the source eye vector onto the horizontal dest vector.
        let angle = -atan2(srcDy, srcDx)

        // Applied to a point: translate(-leftEye) → scale → rotate → translate(destLeft).
        var t = CGAffineTransform(translationX: destLeft.x, y: destLeft.y)
        t = t.rotated(by: angle)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -leftEye.x, y: -leftEye.y)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: n, height: n), format: format)
        let out = renderer.image { ctx in
            ctx.cgContext.concatenate(t)
            source.draw(at: .zero)
        }
        return out.cgImage
    }

    // MARK: - Orientation

    /// Bakes any EXIF/UIImage orientation into an upright bitmap so Vision and
    /// the warp both operate in a single, unambiguous coordinate space.
    static func uprightImage(_ image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
