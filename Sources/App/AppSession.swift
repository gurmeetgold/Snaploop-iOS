import Foundation
import SwiftUI

/// Small local cache used only to paint the authenticated shell immediately.
/// Firebase remains authoritative and refreshes this record after launch.
enum SessionUserCache {
    private static let key = "snaploop.session.cachedUser"

    static func load(userId: String) -> User? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let user = try? JSONDecoder().decode(User.self, from: data),
              user.id == userId else { return nil }
        return user
    }

    static func save(_ user: User) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

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

    public func beginAuthenticatedSession(user: User, faceProfile: FaceProfile?) {
        activeEvent = nil
        self.user = user
        self.faceProfile = faceProfile
        SessionUserCache.save(user)
    }

    /// Explicit sign-out clears account-scoped state and any stale persisted
    /// invite. Authentication bootstrap failures may opt to preserve a route so
    /// it can be replayed after the user signs in again.
    public func clearAuthenticatedSession(preservePendingRoute: Bool = false) {
        user = nil
        faceProfile = nil
        activeEvent = nil
        SessionUserCache.clear()
        if !preservePendingRoute {
            pendingRoute = nil
            PendingInviteStore.clear()
        }
    }

    public static func dev() -> AppSession {
        let user = User(
            id: "dev-user",
            phoneNumber: "+15555550100",
            displayName: "You",
            hasFaceProfile: true,
            createdAt: Date()
        )
        let profile = FaceProfile(
            userId: "dev-user",
            embedding: FaceEmbedding(normalized: [1, 0, 0]),
            version: FaceModelPolicy.currentVersion,
            updatedAt: Date()
        )
        return AppSession(user: user, faceProfile: profile)
    }
}
