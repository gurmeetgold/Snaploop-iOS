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
    public static let customScheme = "snaploop"

    /// Xcode/MVP builds must use the deployed Firebase Hosting domain. The
    /// production `snaploop.app` host should only be enabled after DNS,
    /// Associated Domains, AASA, and the App Store landing path are live.
    public static var host: String {
        #if DEBUG
        return "snaploop-dev.web.app"
        #else
        return "snaploop.app"
        #endif
    }

    public static func url(forToken token: InviteToken) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.path = "/e/\(token.value)"
        return comps.url!
    }

    public static func customURL(forToken token: InviteToken) -> URL {
        URL(string: "\(customScheme)://e/\(token.value)")!
    }

    public static func shareText(eventName: String, token: InviteToken) -> String {
        "Join \"\(eventName)\" on SnapLoop:\n\(url(forToken: token).absoluteString)"
    }
}
