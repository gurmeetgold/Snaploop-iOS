import Foundation

/// Face descriptor generation currently active in SnapLoop.
///
/// v1 = original placeholder embedding.
/// v2 = single-template DEBUG Vision feature-print pipeline.
/// v3 = guided multi-template enrollment + multi-template decision engine,
///      but still on loose, sometimes-mis-oriented crops.
/// v4 = landmark-aligned pipeline (`FaceAligner` → `FaceEmbeddingEngine`):
///      eye-normalized, orientation-correct, fixed-size crops fed to a
///      pluggable embedding engine (interim aligned feature-print in DEBUG, a
///      real Core ML identity model when one is bundled). v3 descriptors were
///      computed in a different, unaligned space and MUST NOT be compared
///      against v4 — bumping the version forces a clean re-enrollment,
///      event-roster template refresh, and camera-roll re-scan.
///
/// NOTE: within v4 the *interim* dev engine and a *real* Core ML engine still
/// produce different embedding spaces. Only one engine is active per build, so
/// this is safe in practice; switching the active engine kind for a shipped
/// build must bump this to v5 to force re-enrollment again.
public enum FaceModelPolicy {
    public static let currentVersion = 4

    /// Number of diverse templates SnapLoop tries to collect during guided
    /// enrollment. The matcher works with fewer, but 5 gives us useful pose
    /// diversity without making setup feel long.
    public static let targetTemplateCount = 5

    /// The current Xcode DEBUG engine is still a development descriptor.
    #if DEBUG
    public static let usesDevelopmentDescriptor = true
    #else
    public static let usesDevelopmentDescriptor = false
    #endif

    /// Release builds must never silently use the development descriptor.
    public static var requiresCommercialEngineForRelease: Bool {
        !usesDevelopmentDescriptor
    }
}
