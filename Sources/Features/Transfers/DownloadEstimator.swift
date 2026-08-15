import Foundation

/// Estimates download size for a set of photos/videos and decides whether to
/// nudge the user toward Wi-Fi before a big batch. Pure and deterministic.
public struct DownloadEstimator {

    /// Rough compressed bytes-per-pixel for a full-res JPEG original.
    public var jpegBytesPerPixel: Double
    /// Assumed seconds and bitrate when estimating a video (we don't carry
    /// duration in metadata for the MVP — this is intentionally conservative).
    public var assumedVideoSeconds: Double
    public var videoBitsPerSecond: Double
    /// Above this many bytes, recommend Wi-Fi.
    public var wifiRecommendationThreshold: Int64

    public init(
        jpegBytesPerPixel: Double = 0.30,
        assumedVideoSeconds: Double = 12,
        videoBitsPerSecond: Double = 12_000_000,
        wifiRecommendationThreshold: Int64 = 150 * 1_000_000  // 150 MB
    ) {
        self.jpegBytesPerPixel = jpegBytesPerPixel
        self.assumedVideoSeconds = assumedVideoSeconds
        self.videoBitsPerSecond = videoBitsPerSecond
        self.wifiRecommendationThreshold = wifiRecommendationThreshold
    }

    public func estimatedBytes(for photo: EventPhoto) -> Int64 {
        switch photo.mediaType {
        case .photo:
            let pixels = Double(max(0, photo.width) * max(0, photo.height))
            return Int64(pixels * jpegBytesPerPixel)
        case .video:
            return Int64(assumedVideoSeconds * videoBitsPerSecond / 8.0)
        }
    }

    public func estimatedBytes(for photos: [EventPhoto]) -> Int64 {
        photos.reduce(0) { $0 + estimatedBytes(for: $1) }
    }

    public func shouldRecommendWiFi(for photos: [EventPhoto]) -> Bool {
        estimatedBytes(for: photos) >= wifiRecommendationThreshold
    }

    /// Human-readable size for the pre-download prompt ("About 240 MB").
    public func humanReadableSize(for photos: [EventPhoto]) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: estimatedBytes(for: photos))
    }
}
