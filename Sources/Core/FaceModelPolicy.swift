import CoreGraphics
import Foundation

/// SnapLoop face descriptor generations.
///
/// v1 = placeholder embedding.
/// v2 = single-template Vision feature print.
/// v3 = guided multi-template enrollment using the same generic descriptor.
/// v4 = landmark-aligned generic Vision feature print.
/// v5 = identity-trained AuraFace Core ML embeddings on canonical 112x112 faces.
///
/// Embeddings from different generations are intentionally incompatible.
public enum FaceModelPolicy {
    public static let currentVersion = 5
    public static let modelIdentifier = "auraface-v1-coreml-fp16"
    public static let targetTemplateCount = 5

    /// Evaluation operating point only. The final threshold must come from
    /// SnapLoop's genuine/impostor benchmark, not from one user's photos.
    public static let evaluationMatchThreshold = 0.52
    public static let evaluationAmbiguityMargin = 0.08

    /// Near-threshold matches require corroboration from another enrollment
    /// template. A clearly strong pose-specific hit may stand alone.
    public static let strongSingleTemplateBonus = 0.10
    public static let supportingTemplateSlack = 0.12

    /// Conservative scan gates. Tiny or extreme-pose faces are left unmatched.
    public static let minimumRecognitionFacePixels: CGFloat = 42
    public static let maximumRecognitionYawDegrees: Double = 55
    public static let minimumCaptureQuality: Double = 0.20

    /// This build uses an identity-trained model rather than Vision feature
    /// prints, but the complete SnapLoop system is still evaluation-only until
    /// the positive/negative benchmark and privacy/security review pass.
    public static let isProductionValidated = false

    // Kept for source compatibility with existing screens while v5 lands.
    public static let usesDevelopmentDescriptor = false
    public static var requiresCommercialEngineForRelease: Bool { false }
}
