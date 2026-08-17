import CoreGraphics
import Foundation

/// The identity-embedding step, isolated behind a protocol so the rest of
/// SnapLoop never depends on *how* an embedding is produced — same pattern as
/// `AuthService`, `EventRepository`, etc.
///
/// The contract is deliberately narrow: given an already-aligned, fixed-size
/// face crop, return an L2-normalized identity embedding. Detection, landmark
/// finding, and geometric alignment happen *before* this (see `FaceAligner`);
/// this step is only the neural descriptor. That separation is what lets us
/// swap a generic Vision feature-print (dev) for a real identity-trained Core
/// ML model (production) without touching matching, scanning, or storage.
public protocol FaceEmbeddingEngine: Sendable {
    /// Monotonic version of the descriptor *space* this engine produces.
    /// Embeddings from different versions are NOT comparable — the matcher and
    /// migration use this to refuse cross-generation comparisons (see
    /// `FaceModelPolicy`).
    var modelVersion: Int { get }

    /// Whether this engine is cleared to drive real matching. A dev/stub engine
    /// returns false so `CameraSyncCoordinator` refuses to mark photos scanned.
    var isIdentityGrade: Bool { get }

    /// The square pixel size this engine expects its input crop to be aligned
    /// to (e.g. 112 for ArcFace-family models). `FaceAligner` reads this so the
    /// alignment output matches the model input with no implicit resizing.
    var expectedInputSize: Int { get }

    /// Produces an L2-normalized embedding for one aligned face crop.
    /// Throws `AppError.faceEmbeddingFailed` on a bad/degenerate crop and
    /// `AppError.faceRecognitionNotReady` if the engine has no usable model.
    func embedding(forAlignedFace image: CGImage) async throws -> FaceEmbedding
}
