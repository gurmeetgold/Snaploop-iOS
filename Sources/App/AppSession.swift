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

private enum SetupDeferralStore {
    static func skippedName(userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "snaploop.setup.skipName.\(userId)")
    }

    static func skippedFace(userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "snaploop.setup.skipFace.\(userId)")
    }

    static func setSkippedName(_ skipped: Bool, userId: String) {
        UserDefaults.standard.set(skipped, forKey: "snaploop.setup.skipName.\(userId)")
    }

    static func setSkippedFace(_ skipped: Bool, userId: String) {
        UserDefaults.standard.set(skipped, forKey: "snaploop.setup.skipFace.\(userId)")
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
    @Published public private(set) var skippedNameSetup = false
    @Published public private(set) var skippedFaceSetup = false
    @Published public var faceSetupNotice: String?

    public init(user: User? = nil, faceProfile: FaceProfile? = nil) {
        self.user = user
        if let user, let faceProfile, faceProfile.userId == user.id {
            self.faceProfile = faceProfile
            self.resolvedFaceProfileUserId = user.id
        } else {
            self.faceProfile = nil
            self.resolvedFaceProfileUserId = nil
        }
        if let user {
            skippedNameSetup = SetupDeferralStore.skippedName(userId: user.id)
            skippedFaceSetup = SetupDeferralStore.skippedFace(userId: user.id)
        }
    }

    public var isRegistered: Bool { user != nil }

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
        skippedNameSetup = SetupDeferralStore.skippedName(userId: user.id)
        skippedFaceSetup = SetupDeferralStore.skippedFace(userId: user.id)
        faceSetupNotice = nil
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
        if user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            skippedNameSetup = false
            SetupDeferralStore.setSkippedName(false, userId: user.id)
        }
        SessionUserCache.save(user)
    }

    public func deferNameSetup() {
        guard let userId = user?.id else { return }
        skippedNameSetup = true
        SetupDeferralStore.setSkippedName(true, userId: userId)
    }

    public func deferFaceSetup() {
        guard let userId = user?.id else { return }
        skippedFaceSetup = true
        SetupDeferralStore.setSkippedFace(true, userId: userId)
    }

    /// Face Setup deletion is an intentional user choice, not an incomplete
    /// onboarding step. Keep the user in the main app and let them re-enter
    /// Face Setup explicitly from You whenever they want to configure it again.
    public func requireFaceSetupAfterDeletion() {
        guard let userId = user?.id else { return }
        faceProfile = nil
        resolvedFaceProfileUserId = userId
        skippedFaceSetup = true
        SetupDeferralStore.setSkippedFace(true, userId: userId)
        faceSetupNotice = "Face Setup was deleted. Automatic matching is off until you set it up again."
    }

    public func consumeFaceSetupNotice() -> String? {
        defer { faceSetupNotice = nil }
        return faceSetupNotice
    }

    public func clearAuthenticatedSession(preservePendingRoute: Bool = false) {
        user = nil
        faceProfile = nil
        resolvedFaceProfileUserId = nil
        skippedNameSetup = false
        skippedFaceSetup = false
        faceSetupNotice = nil
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
