import Foundation

/// An injectable source of "now". Pure business logic (event lifecycle, TTLs)
/// depends on this protocol instead of `Date()` so tests are deterministic.
public protocol Clock: Sendable {
    func now() -> Date
}

/// Production clock — wall-clock time.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Test clock — a fixed, controllable instant.
public final class FixedClock: Clock, @unchecked Sendable {
    public var current: Date
    public init(_ current: Date) { self.current = current }
    public func now() -> Date { current }
    /// Advance the clock by a number of seconds (handy in tests).
    public func advance(by seconds: TimeInterval) { current.addTimeInterval(seconds) }
}
