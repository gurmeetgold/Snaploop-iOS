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

    /// Scan behavior can change without changing the neural embedding space.
    /// v5.1 uses higher-resolution source images and revised pre-model gates, so
    /// incrementing this key intentionally causes eligible camera assets to be
    /// rescanned during this evaluation cycle while v5 embeddings remain valid.
    public static let scanGeneration = "face-v5.1"

    public static let targetTemplateCount = 5

    /// Evaluation operating point only. The final threshold must come from
    /// SnapLoop's genuine/impostor benchmark, not from one user's photos.
    public static let evaluationMatchThreshold = 0.52
    public static let evaluationAmbiguityMargin = 0.08

    /// A five-pose enrollment should be allowed to corroborate a borderline
    /// query. We deliberately keep the headline threshold unchanged and permit
    /// a small near-threshold band only when TWO independent enrollment poses
    /// agree. This improves recall without turning a lone weak similarity into
    /// a match. Participant-to-participant ambiguity checks still apply.
    public static let corroboratedBestTemplateSlack = 0.04
    public static let supportingTemplateSlack = 0.06

    /// A clearly strong pose-specific hit may stand alone even when another
    /// enrollment pose does not corroborate it.
    public static let strongSingleTemplateBonus = 0.10

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
