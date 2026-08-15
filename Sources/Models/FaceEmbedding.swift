import Foundation

/// A fixed-length face descriptor produced on-device by the Core ML embedding
/// model. Stored L2-normalized so similarity is a plain dot product.
///
/// This is a pure value type with no dependency on Vision or Core ML, which is
/// what lets the matcher be unit-tested with hand-authored vectors.
public struct FaceEmbedding: Equatable, Codable, Sendable {

    /// The L2-normalized components.
    public let vector: [Float]

    /// Creates an embedding, normalizing to unit length. Returns `nil` for an
    /// empty vector or a zero vector (no meaningful direction).
    public init?(_ raw: [Float]) {
        guard !raw.isEmpty else { return nil }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        self.vector = raw.map { $0 / norm }
    }

    /// Internal initializer for values already known to be unit-normalized
    /// (e.g. decoded from storage). Not validated — use `init?` for raw input.
    public init(normalized vector: [Float]) {
        self.vector = vector
    }

    public var dimension: Int { vector.count }

    /// Cosine similarity in `-1...1`. Because both vectors are unit length this
    /// is just the dot product. Returns `nil` if dimensions differ (a
    /// programming/config error the caller must handle, never silently 0).
    public func cosineSimilarity(to other: FaceEmbedding) -> Double? {
        guard dimension == other.dimension else { return nil }
        var dot: Float = 0
        for i in 0..<vector.count { dot += vector[i] * other.vector[i] }
        // Clamp to guard against tiny floating-point overshoot past ±1.
        return Double(min(1, max(-1, dot)))
    }
}
