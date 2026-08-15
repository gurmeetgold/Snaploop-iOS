import XCTest
@testable import SnapLoop

final class AnalyticsTests: XCTestCase {

    func testInMemorySinkCapturesEvents() {
        let sink = InMemoryAnalytics()
        sink.log(.signupCompleted())
        sink.log(.selfieCompleted())
        sink.log(.joinConversion(eventId: "e1"))
        XCTAssertEqual(sink.names(), ["signup_completed", "selfie_completed", "join_conversion"])
    }

    func testNorthStarEventCarriesEventAndFirstFlag() {
        let event = AnalyticsEvent.photoDiscovered(eventId: "e1", firstForUserInEvent: true)
        XCTAssertEqual(event.name, "photo_discovered")
        XCTAssertEqual(event.parameters["event_id"], .string("e1"))
        XCTAssertEqual(event.parameters["first_for_user_in_event"], .bool(true))
    }

    func testFullFunnelIsInstrumentable() {
        let sink = InMemoryAnalytics()
        // The invite→discovery funnel the acceptance test cares about.
        sink.log(.inviteLinkOpened(eventId: "e1"))
        sink.log(.signupCompleted())
        sink.log(.selfieCompleted())
        sink.log(.permissionGranted(kind: "photos", granted: true))
        sink.log(.joinConversion(eventId: "e1"))
        sink.log(.firstSyncCompleted(eventId: "e1", matched: 3))
        sink.log(.photoDiscovered(eventId: "e1", firstForUserInEvent: true))
        XCTAssertEqual(sink.events.count, 7)
        XCTAssertTrue(sink.names().contains("photo_discovered"))
    }

    /// Biometric-exclusion audit: every parameter value across every event
    /// factory is a harmless scalar — the AnalyticsValue type has no case that
    /// can carry embeddings/Data, so this holds by construction. This test
    /// pins that guarantee against every known event.
    func testNoAnalyticsEventCarriesBiometricData() {
        let events: [AnalyticsEvent] = [
            .installOpened(),
            .inviteLinkOpened(eventId: "e"),
            .eventCreated(eventId: "e", category: .trip),
            .inviteSent(eventId: "e", channel: "messages"),
            .signupCompleted(),
            .selfieCompleted(),
            .permissionGranted(kind: "photos", granted: true),
            .joinConversion(eventId: "e"),
            .firstSyncCompleted(eventId: "e", matched: 5),
            .photoDiscovered(eventId: "e", firstForUserInEvent: false),
            .eventParticipation(ordinal: 2),
        ]
        let bannedKeys = ["embedding", "vector", "face", "template", "descriptor"]
        for event in events {
            for (key, value) in event.parameters {
                XCTAssertFalse(bannedKeys.contains { key.lowercased().contains($0) },
                               "Analytics key '\(key)' looks biometric")
                // Values are only safe scalars.
                switch value {
                case .string, .int, .double, .bool: break
                }
            }
        }
    }
}
