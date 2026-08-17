import Foundation
import SwiftUI

/// Observable holder for the signed-in user's session state.
@MainActor
public final class AppSession: ObservableObject {
    @Published public var user: User?
    @Published public var faceProfile: FaceProfile?
    @Published public var pendingRoute: DeepLinkRoute?
    @Published public var activeEvent: Event?

    public init(user: User? = nil, faceProfile: FaceProfile? = nil) {
        self.user = user
        self.faceProfile = faceProfile
    }

    public var isRegistered: Bool { user != nil }
    public var hasFaceProfile: Bool { faceProfile?.version == FaceModelPolicy.currentVersion }

    /// Atomic account switch for shared-device testing. Clear account-scoped UI
    /// state first, then install only the new user's objects. Local reference
    /// images and scan-state stores remain keyed by UID separately.
    public func beginAuthenticatedSession(user: User, faceProfile: FaceProfile?) {
        self.activeEvent = nil
        self.user = nil
        self.faceProfile = nil
        self.user = user
        self.faceProfile = faceProfile
    }

    public func clearAuthenticatedSession() {
        user = nil
        faceProfile = nil
        activeEvent = nil
        // Keep pendingRoute: an invite tapped before/while signing in should
        // still resume after the next successful authentication.
    }

    public static func dev() -> AppSession {
        let user = User(id: "dev-user", phoneNumber: "+15555550100",
                        displayName: "You", hasFaceProfile: true,
                        createdAt: Date())
        let profile = FaceProfile(userId: "dev-user",
                                  embedding: FaceEmbedding(normalized: [1, 0, 0]),
                                  version: FaceModelPolicy.currentVersion, updatedAt: Date())
        return AppSession(user: user, faceProfile: profile)
    }
}
