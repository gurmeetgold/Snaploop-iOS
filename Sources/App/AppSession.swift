import Foundation
import SwiftUI

/// Observable holder for the signed-in user's session state — the current
/// `User` and their `FaceProfile` (needed to seed an event's matching roster on
/// join). Kept small and separate from `AppEnvironment` (which holds services).
@MainActor
public final class AppSession: ObservableObject {
    @Published public var user: User?
    @Published public var faceProfile: FaceProfile?

    /// A pending deep-link route captured before the user was ready (e.g. a link
    /// tapped on a fresh install). Replayed once registration + face setup are
    /// complete — this is what makes deferred deep linking "land on Join".
    @Published public var pendingRoute: DeepLinkRoute?

    /// The event currently in focus — set when the user opens a trip from Home
    /// or Trips. The Shared and Requests tabs are scoped to this event, mirroring
    /// the "active trip" the UI is centered on (shown via the switcher chevron
    /// next to the avatar).
    @Published public var activeEvent: Event?

    public init(user: User? = nil, faceProfile: FaceProfile? = nil) {
        self.user = user
        self.faceProfile = faceProfile
    }

    public var isRegistered: Bool { user != nil }
    public var hasFaceProfile: Bool { faceProfile != nil }

    /// A dev session so previews and the Phase-2 skeleton have a signed-in user.
    public static func dev() -> AppSession {
        let user = User(id: "dev-user", phoneNumber: "+15555550100",
                        displayName: "You", hasFaceProfile: true,
                        createdAt: Date())
        let profile = FaceProfile(userId: "dev-user",
                                  embedding: FaceEmbedding(normalized: [1, 0, 0]),
                                  version: 1, updatedAt: Date())
        return AppSession(user: user, faceProfile: profile)
    }
}
