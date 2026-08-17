import Foundation
import SwiftUI

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

    public func beginAuthenticatedSession(user: User, faceProfile: FaceProfile?) {
        activeEvent = nil
        self.user = nil
        self.faceProfile = nil
        self.user = user
        self.faceProfile = faceProfile
        // pendingRoute is intentionally preserved here. If this authentication
        // was started by a freshly tapped invite, it must resume after sign-in.
    }

    /// Full account reset used by Sign Out and failed session bootstrap. This
    /// clears stale event/invite UI so a different account on the same iPhone
    /// cannot inherit an invite from the previous signed-in user.
    public func clearAuthenticatedSession(clearPendingRoute: Bool = true) {
        user = nil
        faceProfile = nil
        activeEvent = nil
        if clearPendingRoute { pendingRoute = nil }
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
