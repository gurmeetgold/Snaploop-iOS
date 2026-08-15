import Foundation

/// Where an incoming link/QR/code should take the user. Pure routing intent —
/// resolving it (fetching the event, gating on face setup) happens in the view
/// layer. This is what post-install deferred deep linking restores: the app
/// stashes the parsed route and replays it once the user is registered.
public enum DeepLinkRoute: Equatable, Sendable, Identifiable {
    /// Open the Join screen for an event identified by its invite token.
    case joinEventByToken(InviteToken)
    /// Open the Join screen for an event identified by its short code.
    case joinEventByCode(JoinCode)

    public var id: String {
        switch self {
        case .joinEventByToken(let t): return "t:\(t.value)"
        case .joinEventByCode(let c): return "c:\(c.value)"
        }
    }
}

/// Parses inbound URLs (Universal Links, the custom scheme, and pasted codes)
/// into a `DeepLinkRoute`. Pure and total — never throws, returns `nil` for
/// anything it doesn't recognize so the caller can fall back gracefully.
public enum DeepLinkRouter {

    /// Parse a URL. Handles:
    ///   • `https://snaploop.app/e/<token>`         (Universal Link)
    ///   • `snaploop://e/<token>` / `snaploop://join?token=<token>` (custom scheme)
    ///   • `https://snaploop.app/c/<CODE>`          (short-code link)
    public static func route(for url: URL) -> DeepLinkRoute? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Normalize path segments, dropping the empty leading one.
        let segments = comps.path.split(separator: "/").map(String.init)

        // Query token (custom scheme "snaploop://join?token=…").
        if let tokenParam = comps.queryItems?.first(where: { $0.name == "token" })?.value,
           let token = InviteToken(tokenParam) {
            return .joinEventByToken(token)
        }

        // Path forms: /e/<token>, /c/<code>. For the custom scheme the "host"
        // carries the first segment, so fold it in.
        var path = segments
        if comps.scheme == InviteLink.customScheme, let host = comps.host, !host.isEmpty {
            path.insert(host, at: 0)
        }

        guard path.count >= 2 else { return nil }
        switch path[0] {
        case "e":
            if let token = InviteToken(path[1]) { return .joinEventByToken(token) }
        case "c":
            if let code = JoinCode(input: path[1]) { return .joinEventByCode(code) }
        default:
            break
        }
        return nil
    }

    /// Parse a manually pasted string that could be a full URL or a bare code.
    public static func route(forManualEntry raw: String) -> DeepLinkRoute? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, let route = route(for: url) {
            return route
        }
        if let code = JoinCode(input: trimmed) { return .joinEventByCode(code) }
        return nil
    }
}
