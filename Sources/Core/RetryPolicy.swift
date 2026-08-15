import Foundation

/// Deterministic exponential-backoff policy for retryable operations (transfer
/// uploads, sync uploads, network calls). Pure: given an attempt number it
/// returns the delay; jitter is injectable so tests stay deterministic.
public struct RetryPolicy: Sendable {
    public let baseDelay: TimeInterval    // delay before the first retry
    public let multiplier: Double         // growth factor per attempt
    public let maxDelay: TimeInterval     // cap
    public let maxAttempts: Int           // total attempts before giving up
    public let jitterFraction: Double     // ± fraction of the computed delay

    public init(
        baseDelay: TimeInterval = 2,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 60,
        maxAttempts: Int = 5,
        jitterFraction: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitterFraction = jitterFraction
    }

    /// Whether another attempt is allowed. `attempt` is 1-based (1 = the first
    /// try). Retry is permitted while `attempt < maxAttempts`.
    public func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// Base (un-jittered) delay before the retry that follows `attempt`
    /// (1-based). Clamped to `maxDelay`.
    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let raw = baseDelay * pow(multiplier, Double(attempt - 1))
        return min(raw, maxDelay)
    }

    /// Delay with jitter applied. `jitter01` is a value in `0...1` (inject a
    /// fixed value in tests; production passes `Double.random(in: 0...1)`).
    public func jitteredDelay(afterAttempt attempt: Int, jitter01: Double) -> TimeInterval {
        let base = delay(afterAttempt: attempt)
        let spread = base * jitterFraction
        // Map 0...1 to -spread...+spread.
        let offset = (jitter01 * 2 - 1) * spread
        return max(0, base + offset)
    }
}
