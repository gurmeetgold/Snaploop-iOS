import Foundation

/// Small local persistence for an invite captured before authentication. This
/// survives an app relaunch on an already-installed device without changing any
/// backend or deep-link identifiers.
enum PendingInviteStore {
    private static let key = "mypicsroom.pendingInviteRoute"

    static func save(_ route: DeepLinkRoute) {
        UserDefaults.standard.set(route.id, forKey: key)
    }

    static func load() -> DeepLinkRoute? {
        guard let raw = UserDefaults.standard.string(forKey: key), raw.count > 2 else { return nil }
        let value = String(raw.dropFirst(2))
        if raw.hasPrefix("t:"), let token = InviteToken(value) {
            return .joinEventByToken(token)
        }
        if raw.hasPrefix("c:"), let code = JoinCode(input: value) {
            return .joinEventByCode(code)
        }
        if raw.hasPrefix("a:"), let token = InviteToken(value) {
            return .acceptEventByToken(token)
        }
        if raw.hasPrefix("b:"), let code = JoinCode(input: value) {
            return .acceptEventByCode(code)
        }
        if raw.hasPrefix("d:"), let token = InviteToken(value) {
            return .declineEventByToken(token)
        }
        return nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
