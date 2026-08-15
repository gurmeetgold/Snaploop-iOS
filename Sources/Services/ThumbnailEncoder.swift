import Foundation

/// Encodes a downscaled JPEG thumbnail from source image data. Behind a
/// protocol so the sync coordinator stays testable and platform-free; the
/// production implementation (ImageIO) lives in the Transfers feature.
public protocol ThumbnailEncoder: Sendable {
    func encodeJPEG(from imageData: Data, maxPixelSize: Int, quality: Double) throws -> Data
}
