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

    func testInMemorySinkTracksAndResetsIdentity() {
        let sink = InMemoryAnalytics()
        sink.identify(userId: "internal-user-123")
        XCTAssertEqual(sink.identifiedUserId, "internal-user-123")

        sink.reset()
        XCTAssertNil(sink.identifiedUserId)
    }

    func testCollectionKillSwitchSuppressesCaptureAndIdentity() {
        let sink = InMemoryAnalytics()
        sink.setCollectionEnabled(false)

        sink.log(.signupCompleted())
        sink.identify(userId: "internal-user-123")

        XCTAssertFalse(sink.isCollectionEnabled)
        XCTAssertTrue(sink.events.isEmpty)
        XCTAssertNil(sink.identifiedUserId)

        sink.setCollectionEnabled(true)
        sink.log(.signupCompleted())
        sink.identify(userId: "internal-user-123")

        XCTAssertTrue(sink.isCollectionEnabled)
        XCTAssertEqual(sink.names(), ["signup_completed"])
        XCTAssertEqual(sink.identifiedUserId, "internal-user-123")
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

    func testCoreProductFunnelEventsAreAvailable() {
        let events: [AnalyticsEvent] = [
            .phoneVerificationStarted(),
            .phoneVerificationSucceeded(),
            .signupCompleted(),
            .loginSucceeded(),
            .faceSetupStarted(),
            .faceSetupCompleted(wasUpdate: false),
            .photoPermissionRequested(),
            .photoPermissionResult(state: .limited),
            .eventCreated(eventId: "private-event", category: .trip),
            .inviteSent(eventId: "private-event", channel: "in_app"),
            .invitationOpened(source: .token),
            .invitationAccepted(source: .token),
            .eventJoined(source: .token),
            .invitationDeclined(source: .token),
        ]

        XCTAssertEqual(
            events.map(\.name),
            [
                "phone_verification_started",
                "phone_verification_succeeded",
                "signup_completed",
                "login_succeeded",
                "face_setup_started",
                "face_setup_completed",
                "photo_permission_requested",
                "photo_permission_result",
                "event_created",
                "invite_sent",
                "invitation_opened",
                "invitation_accepted",
                "event_joined",
                "invitation_declined",
            ]
        )
    }

    func testProductionFunnelPropertiesArePrivacyMinimized() {
        XCTAssertEqual(
            AnalyticsEvent.eventCreated(
                eventId: "must-not-egress",
                category: .trip
            ).productionParameters,
            ["category": .string(EventCategory.trip.rawValue)]
        )

        XCTAssertEqual(
            AnalyticsEvent.inviteSent(
                eventId: "must-not-egress",
                channel: "in_app"
            ).productionParameters,
            ["channel": .string("in_app")]
        )

        XCTAssertEqual(
            AnalyticsEvent.invitationOpened(source: .token)
                .productionParameters,
            ["source": .string("token")]
        )

        XCTAssertEqual(
            AnalyticsEvent.faceSetupCompleted(wasUpdate: true)
                .productionParameters,
            ["was_update": .bool(true)]
        )

        XCTAssertEqual(
            AnalyticsEvent.photoPermissionResult(state: .limited)
                .productionParameters,
            ["state": .string("limited")]
        )
    }

    func testProductionAnalyticsDropsPrivateEventIdentifiers() {
        let events: [AnalyticsEvent] = [
            .inviteLinkOpened(eventId: "private-event-id"),
            .eventCreated(eventId: "private-event-id", category: .trip),
            .inviteSent(eventId: "private-event-id", channel: "messages"),
            .joinConversion(eventId: "private-event-id"),
            .firstSyncCompleted(eventId: "private-event-id", matched: 3),
            .photoDiscovered(eventId: "private-event-id", firstForUserInEvent: true),
        ]

        for event in events {
            XCTAssertNil(
                event.productionParameters["event_id"],
                "\(event.name) must not transmit event_id"
            )
        }

        XCTAssertEqual(
            AnalyticsEvent.firstSyncCompleted(eventId: "private", matched: 3)
                .productionParameters["matched"],
            .int(3)
        )
        XCTAssertEqual(
            AnalyticsEvent.photoDiscovered(
                eventId: "private",
                firstForUserInEvent: true
            ).productionParameters["first_for_user_in_event"],
            .bool(true)
        )
    }

    func testScanTelemetryUsesOnlyCoarseReviewedProperties() {
        let event = AnalyticsEvent.scanCompleted(
            source: .manual,
            scanned: 42,
            matchedPhotos: 7,
            remaining: 0,
            alreadyCaughtUp: true
        )

        XCTAssertEqual(event.name, "scan_completed")
        XCTAssertEqual(
            Set(event.productionParameters.keys),
            Set(["source", "scanned", "matched_photos", "remaining", "already_caught_up"])
        )
        XCTAssertEqual(event.productionParameters["source"], .string("manual"))
        XCTAssertEqual(event.productionParameters["scanned"], .int(42))
        XCTAssertEqual(event.productionParameters["matched_photos"], .int(7))
    }

    func testObservabilityDefaultsAreConservative() {
        let values = RemoteConfigValues.default
        XCTAssertTrue(values.analyticsEnabled)
        XCTAssertTrue(values.performanceMonitoringEnabled)
        XCTAssertFalse(values.sessionReplayEnabled)
        XCTAssertFalse(values.feedbackSurveysEnabled)
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
