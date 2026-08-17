import Foundation

/// Face descriptor generation currently active in SnapLoop.
///
/// v1 = original placeholder embedding.
/// v2 = single-template DEBUG Vision feature-print pipeline.
/// v3 = guided multi-template enrollment + multi-template decision engine.
///
/// Production release still requires a commercially licensed identity-trained
/// face engine. v3 keeps that engine behind the existing FaceDetectionService
/// seam so the vendor can be swapped without changing the rest of the app.
public enum FaceModelPolicy {
    public static let currentVersion = 3

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
