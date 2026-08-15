import XCTest
@testable import SnapLoop

final class ExpiryAndRetryTests: XCTestCase {

    private let day: TimeInterval = 86_400

    private func event() -> Event {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return Event(id: "e", joinCode: "ABC234", creatorUserId: "u", name: "Party",
                     startsAt: start, endsAt: start + 5 * day, createdAt: start)
    }

    // MARK: Expiry messaging

    func testMessagingTransitionsThroughLifecycle() {
        let e = event()
        let config = RemoteConfigValues.default  // grace 3 days

        let active = ExpiryMessaging.message(for: e, clock: FixedClock(e.startsAt + day), config: config)
        XCTAssertEqual(active.headline, "Happening now")

        let grace = ExpiryMessaging.message(for: e, clock: FixedClock(e.endsAt + day), config: config)
        XCTAssertTrue(grace.detail.contains("until"))
        XCTAssertTrue(grace.detail.lowercased().contains("thumbnail"))

        let expired = ExpiryMessaging.message(for: e, clock: FixedClock(e.endsAt + 10 * day), config: config)
        XCTAssertEqual(expired.headline, "This event has ended")
    }

    func testMessagingNeverUsesAnxietyLanguage() {
        let e = event()
        for offset in [1.0, 6.0, 10.0] {
            let msg = ExpiryMessaging.message(for: e, clock: FixedClock(e.endsAt + offset * day),
                                              config: .default)
            XCTAssertFalse(msg.detail.lowercased().contains("vanish"))
            XCTAssertFalse(msg.detail.lowercased().contains("lost forever"))
        }
    }

    // MARK: Retry / backoff

    func testDelayGrowsExponentiallyAndCaps() {
        let p = RetryPolicy(baseDelay: 2, multiplier: 2, maxDelay: 16, maxAttempts: 10, jitterFraction: 0)
        XCTAssertEqual(p.delay(afterAttempt: 1), 2)
        XCTAssertEqual(p.delay(afterAttempt: 2), 4)
        XCTAssertEqual(p.delay(afterAttempt: 3), 8)
        XCTAssertEqual(p.delay(afterAttempt: 4), 16)
        XCTAssertEqual(p.delay(afterAttempt: 5), 16, "Capped at maxDelay")
    }

    func testShouldRetryStopsAtMaxAttempts() {
        let p = RetryPolicy(maxAttempts: 3)
        XCTAssertTrue(p.shouldRetry(afterAttempt: 1))
        XCTAssertTrue(p.shouldRetry(afterAttempt: 2))
        XCTAssertFalse(p.shouldRetry(afterAttempt: 3))
    }

    func testJitterStaysWithinBounds() {
        let p = RetryPolicy(baseDelay: 10, multiplier: 1, maxDelay: 100, maxAttempts: 5, jitterFraction: 0.2)
        // base delay = 10, jitter ±2 → range [8, 12]
        XCTAssertEqual(p.jitteredDelay(afterAttempt: 1, jitter01: 0.0), 8, accuracy: 1e-9)
        XCTAssertEqual(p.jitteredDelay(afterAttempt: 1, jitter01: 0.5), 10, accuracy: 1e-9)
        XCTAssertEqual(p.jitteredDelay(afterAttempt: 1, jitter01: 1.0), 12, accuracy: 1e-9)
    }

    func testJitterNeverNegative() {
        let p = RetryPolicy(baseDelay: 1, multiplier: 1, maxDelay: 10, maxAttempts: 5, jitterFraction: 2.0)
        XCTAssertGreaterThanOrEqual(p.jitteredDelay(afterAttempt: 1, jitter01: 0.0), 0)
    }
}
