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

    /// Atomic account switch for shared-device testing. A pending route is kept
    /// only when it was intentionally captured while signed out (for example an
    /// invite link opened before OTP sign-in).
    public func beginAuthenticatedSession(user: User, faceProfile: FaceProfile?) {
        activeEvent = nil
        self.user = nil
        self.faceProfile = nil
        self.user = user
        self.faceProfile = faceProfile
    }

    /// Clears all account-scoped state. Explicit sign-out uses the default and
    /// also discards stale invite UI from the previous account.
    public func clearAuthenticatedSession(preservePendingRoute: Bool = false) {
        user = nil
        faceProfile = nil
        activeEvent = nil
        if !preservePendingRoute {
            pendingRoute = nil
        }
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
