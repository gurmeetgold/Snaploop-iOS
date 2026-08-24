import Foundation

public struct InviteToken: Equatable, Sendable {
    public let value: String
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    static let length = 22

    public init?(_ raw: String) {
        let set = Set(Self.alphabet)
        guard raw.count == Self.length, raw.allSatisfy({ set.contains($0) }) else { return nil }
        self.value = raw
    }

    init(unchecked value: String) { self.value = value }

    public static func generate(using generator: inout some RandomNumberGenerator) -> InviteToken {
        let chars = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return InviteToken(unchecked: String(chars))
    }

    public static func generate() -> InviteToken {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }
}

public enum InviteLink {
    public static let scheme = "https"

    /// Keep the technical custom scheme stable so installed versions can always
    /// open an invitation from the web fallback page.
    public static let customScheme = "snaploop"

    /// Keep development data on the development Hosting project while every
    /// Release/TestFlight/App Store build generates production invitation links.
    #if DEBUG
    public static let host = "snaploop-dev.web.app"
    #else
    public static let host = "getsnaploop.web.app"
    #endif

    public static func url(forToken token: InviteToken) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.path = "/e/\(token.value)"
        return comps.url!
    }

    /// Browser fallback for an already-installed app. Use the same `/e/<token>`
    /// route shape as the Universal Link instead of a query-only join URL. This
    /// keeps the web fallback and DeepLinkRouter on one canonical route and
    /// avoids Safari treating malformed/legacy join URLs as invalid addresses.
    public static func customURL(forToken token: InviteToken) -> URL {
        var comps = URLComponents()
        comps.scheme = customScheme
        comps.host = "e"
        comps.path = "/\(token.value)"
        return comps.url!
    }

    public static func shareText(eventName: String, token: InviteToken) -> String {
        "Join \"\(eventName)\" in SnapLoop:\n\(url(forToken: token).absoluteString)"
    }
}
