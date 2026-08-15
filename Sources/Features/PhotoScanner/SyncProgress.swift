import Foundation

/// Staged progress for a sync pass, so the UI shows real status
/// ("248 photos checked / 63 matched / 14 remaining") instead of a blank
/// spinner. Pure value type; the coordinator emits it as it works.
public struct SyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing      // querying the library, planning
        case scanning       // per-asset detection/matching
        case finishing      // saving state / wrapping up
    }

    public let phase: Phase
    public let checked: Int          // assets processed so far this pass
    public let matched: Int          // photos with ≥1 appearance so far
    public let remaining: Int        // assets still to process (this pass + beyond)

    public init(phase: Phase, checked: Int = 0, matched: Int = 0, remaining: Int = 0) {
        self.phase = phase
        self.checked = checked
        self.matched = matched
        self.remaining = remaining
    }

    /// Human status line (no technical internals).
    public var statusText: String {
        switch phase {
        case .preparing:
            return "Finding your photos…"
        case .scanning:
            return "\(checked) photos checked · \(matched) matched · \(remaining) remaining"
        case .finishing:
            return "Almost done…"
        }
    }
}
