import Foundation

/// A short, human-shareable event code. The canonical value is assigned by the
/// backend and is **stable for the event's lifetime**; this type only handles
/// normalization and validation of user-typed input so a code pasted with
/// spaces or lowercase still resolves.
public struct JoinCode: Equatable, Sendable {
    public let value: String   // canonical: uppercased, no separators

    /// Allowed characters. Excludes visually ambiguous 0/O and 1/I/L.
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 6

    /// Parses/normalizes user input. Returns `nil` if it can't be a valid code.
    public init?(input: String) {
        let cleaned = input
            .uppercased()
            .unicodeScalars
            .map(Character.init)
            .filter { $0 != " " && $0 != "-" }
        let candidate = String(cleaned)
        guard candidate.count == Self.length,
              candidate.allSatisfy({ Self.alphabet.contains($0) })
        else { return nil }
        self.value = candidate
    }

    /// For codes already known-canonical (e.g. from the backend).
    public init(canonical: String) { self.value = canonical }

    /// Display form, grouped for readability: `ABC-123`.
    public var formatted: String {
        guard value.count == Self.length else { return value }
        let mid = value.index(value.startIndex, offsetBy: 3)
        return "\(value[..<mid])-\(value[mid...])"
    }
}
