import Foundation

/// One face found in one photo during an on-device scan. Produced by the
/// face-detection + embedding pipeline; consumed by the matcher. Pure value
/// type — no Vision types leak past this boundary.
public struct DetectedFace: Equatable, Sendable {
    /// Embedding of this face.
    public let embedding: FaceEmbedding

    /// Face bounding-box size as a fraction of the image's shorter edge
    /// (0...1). Used to drop tiny background faces before matching.
    public let sizeFraction: Double

    public init(embedding: FaceEmbedding, sizeFraction: Double) {
        self.embedding = embedding
        self.sizeFraction = sizeFraction
    }
}

/// The scannable identity of a photo-library asset, decoupled from PhotoKit so
/// the scan planner and matcher can be tested without a real library.
public struct PhotoAsset: Identifiable, Equatable, Sendable {
    /// PhotoKit `localIdentifier`. Stable per-device; used as the scan-state key.
    public let id: String
    /// When the photo was taken (`PHAsset.creationDate`). Used for date-range
    /// filtering against the event window.
    public let creationDate: Date

    public init(id: String, creationDate: Date) {
        self.id = id
        self.creationDate = creationDate
    }
}
