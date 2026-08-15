import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Production thumbnail encoder. Downscales with ImageIO's thumbnail generator
/// (decodes at target size — memory-efficient, never loads full pixels) and
/// re-encodes as JPEG at the configured quality. No UIKit, no main-thread work.
public struct ImageIOThumbnailEncoder: ThumbnailEncoder {

    public init() {}

    public func encodeJPEG(from imageData: Data, maxPixelSize: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw AppError.thumbnailEncodingFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]

        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError.thumbnailEncodingFailed
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw AppError.thumbnailEncodingFailed
        }

        let clampedQuality = min(1, max(0, quality))
        CGImageDestinationAddImage(dest, thumb, [
            kCGImageDestinationLossyCompressionQuality: clampedQuality
        ] as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw AppError.thumbnailEncodingFailed
        }
        return out as Data
    }
}
