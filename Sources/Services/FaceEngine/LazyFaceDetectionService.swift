import Foundation

/// Defers Core ML model loading until face matching is actually used.
/// This keeps first app launch responsive after a fresh install, when iOS may
/// need extra time to prepare the bundled model.
public final class LazyFaceDetectionService: FaceDetectionService, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: FaceDetectionService?

    public init() {}

    private func service() -> FaceDetectionService {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let created = PipelineFaceDetectionService.makeDefault()
        cached = created
        return created
    }

    public var isReadyForMatching: Bool { service().isReadyForMatching }
    public var engineIdentifier: String { service().engineIdentifier }
    public var modelVersion: Int { service().modelVersion }

    public func detectFaces(in imageData: Data) async throws -> [DetectedFace] {
        try await service().detectFaces(in: imageData)
    }

    public func embeddingForSelfie(_ imageData: Data) async throws -> FaceEmbedding {
        try await service().embeddingForSelfie(imageData)
    }
}
