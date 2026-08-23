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
    @Published public private(set) var resolvedFaceProfileUserId: String?

    public init(user: User? = nil, faceProfile: FaceProfile? = nil) {
        self.user = user
        if let user, let faceProfile, faceProfile.userId == user.id {
            self.faceProfile = faceProfile
            self.resolvedFaceProfileUserId = user.id
        } else {
            self.faceProfile = nil
            self.resolvedFaceProfileUserId = user == nil ? nil : nil
        }
    }

    public var isRegistered: Bool { user != nil }

    /// A face profile is valid only when it belongs to the currently authenticated UID.
    /// This prevents stale in-memory face state from a previously signed-in account from
    /// being treated as the current user's enrollment.
    public var hasFaceProfile: Bool {
        guard let user, let faceProfile else { return false }
        return faceProfile.userId == user.id && faceProfile.version == FaceModelPolicy.currentVersion
    }

    public var isFaceProfileResolved: Bool {
        guard let user else { return false }
        return resolvedFaceProfileUserId == user.id
    }

    public func beginAuthenticatedSession(user: User, faceProfile: FaceProfile?, faceProfileResolved: Bool = false) {
        activeEvent = nil
        self.user = user
        self.faceProfile = (faceProfile?.userId == user.id) ? faceProfile : nil
        resolvedFaceProfileUserId = faceProfileResolved ? user.id : nil
        SessionUserCache.save(user)
    }

    public func setResolvedFaceProfile(_ profile: FaceProfile?, forUserId userId: String) {
        guard user?.id == userId else { return }
        if let profile, profile.userId != userId {
            faceProfile = nil
        } else {
            faceProfile = profile
        }
        resolvedFaceProfileUserId = userId
    }

    public func updateUser(_ user: User) {
        guard self.user?.id == user.id else { return }
        self.user = user
        SessionUserCache.save(user)
    }

    /// Explicit sign-out clears account-scoped state and any stale persisted
    /// invite. Authentication bootstrap failures may opt to preserve a route so
    /// it can be replayed after the user signs in again.
    public func clearAuthenticatedSession(preservePendingRoute: Bool = false) {
        user = nil
        faceProfile = nil
        resolvedFaceProfileUserId = nil
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
        let session = AppSession(user: user, faceProfile: profile)
        session.resolvedFaceProfileUserId = user.id
        return session
    }
}
