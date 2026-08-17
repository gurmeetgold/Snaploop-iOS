import Foundation

/// A fixed-length face descriptor produced on-device by the Core ML embedding model.
public struct FaceEmbedding: Equatable, Codable, Sendable {
    public let vector: [Float]

    public init?(_ raw: [Float]) {
        guard !raw.isEmpty else { return nil }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        self.vector = raw.map { $0 / norm }
    }

    public init(normalized vector: [Float]) {
        self.vector = vector
    }

    public var dimension: Int { vector.count }
    /// Read-only compatibility alias used by diagnostic UI. Never log or
    /// persist these values from diagnostics.
    public var values: [Float] { vector }

    public func cosineSimilarity(to other: FaceEmbedding) -> Double? {
        guard dimension == other.dimension else { return nil }
        var dot: Float = 0
        for i in 0..<vector.count { dot += vector[i] * other.vector[i] }
        return Double(min(1, max(-1, dot)))
    }

    public static func centroid(of embeddings: [FaceEmbedding]) -> FaceEmbedding? {
        guard let first = embeddings.first else { return nil }
        let dimension = first.dimension
        guard embeddings.allSatisfy({ $0.dimension == dimension }) else { return nil }
        var sum = Array(repeating: Float(0), count: dimension)
        for embedding in embeddings {
            for index in 0..<dimension { sum[index] += embedding.vector[index] }
        }
        return FaceEmbedding(sum)
    }
}
