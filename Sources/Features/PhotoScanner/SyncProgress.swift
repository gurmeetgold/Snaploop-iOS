import Foundation

/// Staged progress for a sync pass, so the UI shows real status without
/// exposing match-count internals that can be confused with the user's own
/// Gallery count.
public struct SyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing
        case scanning
        case finishing
    }

    public let phase: Phase
    public let checked: Int
    public let matched: Int
    public let remaining: Int

    public init(phase: Phase, checked: Int = 0, matched: Int = 0, remaining: Int = 0) {
        self.phase = phase
        self.checked = checked
        self.matched = matched
        self.remaining = remaining
    }

    public var statusText: String {
        switch phase {
        case .preparing:
            return "Finding new photos…"
        case .scanning:
            return "\(checked) photos checked · \(remaining) remaining"
        case .finishing:
            return "Finishing scan…"
        }
    }
}
