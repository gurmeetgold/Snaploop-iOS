import XCTest
@testable import SnapLoop

final class InviteTokenTests: XCTestCase {

    func testGeneratedTokenHasCorrectLengthAndAlphabet() {
        var rng = SeededGenerator(seed: 42)
        let token = InviteToken.generate(using: &rng)
        XCTAssertEqual(token.value.count, InviteToken.length)
        let allowed = Set(InviteToken.alphabet)
        XCTAssertTrue(token.value.allSatisfy { allowed.contains($0) })
    }

    func testGenerationIsDeterministicForASeed() {
        var a = SeededGenerator(seed: 7)
        var b = SeededGenerator(seed: 7)
        XCTAssertEqual(InviteToken.generate(using: &a), InviteToken.generate(using: &b))
    }

    func testInitRejectsMalformedTokens() {
        XCTAssertNil(InviteToken("short"))
        XCTAssertNil(InviteToken(String(repeating: "@", count: InviteToken.length)))
    }

    func testURLIsCanonicalAndRoundTrips() {
        var rng = SeededGenerator(seed: 1)
        let token = InviteToken.generate(using: &rng)
        let url = InviteLink.url(forToken: token)
        XCTAssertEqual(url.absoluteString, "https://\(InviteLink.host)/e/\(token.value)")
        XCTAssertEqual(DeepLinkRouter.route(for: url), .joinEventByToken(token))
    }

    // The central Phase-2 guarantee: editing event details never changes the link.
    func testEditingEventDetailsDoesNotChangeInviteLink() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let factory = EventFactory(config: .default, clock: clock)
        let start = clock.now()
        let draft = EventDraft(name: "Montreal", category: .trip,
                               startsAt: start, endsAt: start + 3 * 86_400)
        let event = try factory.make(draft: draft, creatorUserId: "u1")

        let linkBefore = InviteLink.url(forToken: InviteToken(event.inviteToken)!)

        var edited = EventDraft(name: "Weekend in Montreal", category: .party,
                                startsAt: start + 86_400, endsAt: start + 5 * 86_400,
                                locationName: "Old Port", coverImagePath: "covers/x.jpg")
        edited.name = "Weekend in Montreal"
        let updated = try factory.applyEdit(edited, to: event)

        XCTAssertEqual(updated.id, event.id)
        XCTAssertEqual(updated.joinCode, event.joinCode)
        XCTAssertEqual(updated.inviteToken, event.inviteToken)
        let linkAfter = InviteLink.url(forToken: InviteToken(updated.inviteToken)!)
        XCTAssertEqual(linkBefore, linkAfter)
    }
}
