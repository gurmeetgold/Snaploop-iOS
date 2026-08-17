import Foundation

/// The stable, opaque token that identifies an event in its invite URL. Assigned
/// once at creation and **never regenerated** — editing an event's name, dates,
/// or cover leaves this untouched, which is what keeps a shared link valid
/// forever (Google-Doc semantics).
public struct InviteToken: Equatable, Sendable {
    public let value: String

    /// URL-safe alphabet (base62). No ambiguous separators, safe unescaped in a URL path.
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    static let length = 22   // ~131 bits — collision-resistant, unguessable.

    public init?(_ raw: String) {
        let set = Set(Self.alphabet)
        guard raw.count == Self.length, raw.allSatisfy({ set.contains($0) }) else { return nil }
        self.value = raw
    }

    init(unchecked value: String) { self.value = value }

    /// Generates a fresh token. `generator` is injectable so tests are
    /// deterministic; production uses the system CSPRNG.
    public static func generate(using generator: inout some RandomNumberGenerator) -> InviteToken {
        let chars = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return InviteToken(unchecked: String(chars))
    }

    public static func generate() -> InviteToken {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }
}

/// Builds and parses SnapLoop invite links. Kept pure and free of app config so
/// it can be unit-tested; the base host is the app's Universal Link domain.
public enum InviteLink {
    /// Development invite landing host. Before App Store release this changes to the production SnapLoop domain with Associated Domains.
    public static let host = "snaploop-dev.web.app"
    public static let scheme = "https"
    /// Custom URL scheme fallback (also registered), used by QR in some flows.
    public static let customScheme = "snaploop"

    /// The canonical shareable URL for an event token, e.g.
    /// `https://snaploop.app/e/AbC…`. Deterministic — same token, same URL,
    /// forever.
    public static func url(forToken token: InviteToken) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.path = "/e/\(token.value)"
        return comps.url!
    }

    /// Human share text wrapping the link.
    public static func shareText(eventName: String, token: InviteToken) -> String {
        "Join \"\(eventName)\" on SnapLoop and get every photo of you from the event:\n\(url(forToken: token).absoluteString)"
    }
}
