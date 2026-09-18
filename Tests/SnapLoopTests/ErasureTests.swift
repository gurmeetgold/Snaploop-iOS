import XCTest
@testable import SnapLoop

final class ErasureTests: XCTestCase {

    private func user(_ id: String) -> User {
        User(id: id, phoneNumber: "+1555", displayName: id, hasFaceProfile: true, createdAt: Date())
    }
    private func profile(_ id: String) -> FaceProfile {
        FaceProfile(userId: id, embedding: FaceEmbedding([1, 0, 0])!, version: 1, updatedAt: Date())
    }

    // MARK: Pure plan

    func testDeleteFaceProfilePlanIsMinimal() {
        XCTAssertEqual(ErasurePlanner.planDeleteFaceProfile(userId: "u"),
                       [.deleteFaceProfile(userId: "u")])
    }

    func testDeleteAccountPlanOrdersMembershipsThenProfileThenUserDoc() {
        let plan = ErasurePlanner.planDeleteAccount(userId: "u", memberEventIds: ["e2", "e1"])
        XCTAssertEqual(plan, [
            .removeEventMembership(eventId: "e1", userId: "u"),
            .removeEventMembership(eventId: "e2", userId: "u"),
            .deleteFaceProfile(userId: "u"),
            .deleteUserDocument(userId: "u"),
        ])
        XCTAssertEqual(plan.last, .deleteUserDocument(userId: "u"))
    }

    // MARK: Biometric launch policy

    func testFaceMatchLaunchCountriesAreCanadaAndIndiaOnly() {
        XCTAssertEqual(BiometricJurisdictionCatalog.countries.map(\.code), ["CA", "IN"])
        XCTAssertFalse(BiometricJurisdictionCatalog.countries.contains(where: { $0.code == "US" }))
    }

    func testFaceMatchJurisdictionAllowsIndiaAndEligibleCanada() {
        XCTAssertTrue(BiometricJurisdiction(countryCode: "IN").isFaceMatchAvailable)
        XCTAssertTrue(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "ON").isFaceMatchAvailable)
    }

    func testFaceMatchJurisdictionBlocksQuebecUSAndUnsupportedCountries() {
        XCTAssertFalse(BiometricJurisdiction(countryCode: "CA", subdivisionCode: "QC").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "AK").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "IL").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "NY").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "US", subdivisionCode: "TX").isFaceMatchAvailable)
        XCTAssertFalse(BiometricJurisdiction(countryCode: "GB", subdivisionCode: "ENG").isFaceMatchAvailable)
    }

    func testBiometricConsentRequiresCurrentDisclosureEligibleJurisdictionAndUnexpiredWindow() {
        let now = Date()
        let active = BiometricConsentRecord(
            userId: "u",
            acceptedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            jurisdictionCountry: "IN",
            appVersion: "1.0",
            locale: "en_IN"
        )
        XCTAssertTrue(active.isActive)

        let activeCanada = BiometricConsentRecord(
            userId: "u",
            acceptedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            jurisdictionCountry: "CA",
            jurisdictionSubdivision: "ON",
            appVersion: "1.0",
            locale: "en_CA"
        )
        XCTAssertTrue(activeCanada.isActive)

        let blockedQuebec = BiometricConsentRecord(
            userId: "u",
            acceptedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            jurisdictionCountry: "CA",
            jurisdictionSubdivision: "QC",
            appVersion: "1.0",
            locale: "fr_CA"
        )
        XCTAssertFalse(blockedQuebec.isActive)

        let expired = BiometricConsentRecord(
            userId: "u",
            acceptedAt: now.addingTimeInterval(-172_800),
            expiresAt: now.addingTimeInterval(-86_400),
            jurisdictionCountry: "IN",
            appVersion: "1.0",
            locale: "en_IN"
        )
        XCTAssertFalse(expired.isActive)

        let oldDisclosure = BiometricConsentRecord(
            userId: "u",
            policyVersion: BiometricConsentRecord.currentPolicyVersion,
            disclosureId: "biometric-consent-old",
            disclosureSHA256: BiometricConsentRecord.currentDisclosureSHA256,
            acceptedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            jurisdictionCountry: "IN",
            appVersion: "1.0",
            locale: "en_IN"
        )
        XCTAssertFalse(oldDisclosure.isActive)
    }

    // MARK: Execution

    func testDeleteFaceProfileRemovesEmbeddingButKeepsMemberships() async throws {
        let events = InMemoryEventRepository()
        let faces = InMemoryFaceProfileStore(seed: profile("u"))
        let users = InMemoryUserDirectory(seed: user("u"))
        let event = Event(id: "e1", joinCode: "ABC234", creatorUserId: "u", name: "Trip",
                          startsAt: Date(), endsAt: Date().addingTimeInterval(86_400), createdAt: Date())
        try await events.createEvent(event)
        try await events.addMember(eventId: "e1", member: EventMember(userId: "u", role: .participant, joinedAt: Date(), faceTemplateVersion: 1))

        let svc = ErasureService(events: events, faceProfiles: faces, users: users)
        try await svc.deleteFaceProfile(userId: "u")

        XCTAssertFalse(faces.exists(userId: "u"))
        XCTAssertTrue(users.exists(userId: "u"))
        let members = try await events.members(eventId: "e1")
        XCTAssertEqual(members.count, 1, "Deleting only the face profile keeps memberships")
    }

    func testDeleteAccountCascadesEverything() async throws {
        let events = InMemoryEventRepository()
        let faces = InMemoryFaceProfileStore(seed: profile("u"))
        let users = InMemoryUserDirectory(seed: user("u"))

        let event = Event(id: "e1", joinCode: "ABC234", creatorUserId: "creator", name: "Trip",
                          startsAt: Date(), endsAt: Date().addingTimeInterval(86_400), createdAt: Date())
        try await events.createEvent(event)
        try await events.addMember(eventId: "e1", member: EventMember(userId: "u", role: .participant, joinedAt: Date(), faceTemplateVersion: 1))
        try await events.join(eventId: "e1", participant: EventParticipant(userId: "u", displayName: "U", faceEmbedding: profile("u").embedding, faceProfileVersion: 1, joinedAt: Date()))

        let svc = ErasureService(events: events, faceProfiles: faces, users: users)
        try await svc.deleteAccount(userId: "u")

        XCTAssertFalse(faces.exists(userId: "u"), "Biometric template purged")
        XCTAssertFalse(users.exists(userId: "u"), "User doc purged")
        let members = try await events.members(eventId: "e1")
        let roster = try await events.participants(eventId: "e1")
        XCTAssertTrue(members.isEmpty, "Membership removed")
        XCTAssertTrue(roster.isEmpty, "Event-side embedding revoked")
    }
}