import XCTest
@testable import SnapLoop

final class EventCreationTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func factory(maxDays: Int = 15) -> EventFactory {
        var config = RemoteConfigValues.default
        config.maxEventDurationDays = maxDays
        let gens = EventFactory.Generators(
            id: { "fixed-id" },
            joinCode: { "ABC234" },
            inviteToken: { InviteToken(String(repeating: "A", count: InviteToken.length))! }
        )
        return EventFactory(config: config,
                            clock: FixedClock(now),
                            generators: gens)
    }

    func testCreatesEventWithStableIdentityFields() throws {
        let draft = EventDraft(name: "Trip", category: .trip, startsAt: now, endsAt: now + 3 * day)
        let event = try factory().make(draft: draft, creatorUserId: "u1")
        XCTAssertEqual(event.id, "fixed-id")
        XCTAssertEqual(event.joinCode, "ABC234")
        XCTAssertEqual(event.inviteToken.count, InviteToken.length)
        XCTAssertEqual(event.status, .active)
        XCTAssertEqual(event.creatorUserId, "u1")
    }

    func testAllowsPastStartDateInsideSecurityWindow() {
        let start = now - 10 * day
        let draft = EventDraft(name: "Earlier event", startsAt: start, endsAt: start + 2 * day)
        XCTAssertNoThrow(try factory().make(draft: draft, creatorUserId: "u1"))
    }

    func testRejectsPastStartDateOutsideSecurityWindow() {
        let start = now - 16 * day
        let draft = EventDraft(name: "Too old", startsAt: start, endsAt: start + 2 * day)
        XCTAssertThrowsError(try factory().make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .eventDatesOutsideAllowedWindow(days: 15))
        }
    }

    func testEnforcesMaxDurationFromConfigAndMVP() {
        let draft = EventDraft(name: "Long", startsAt: now - 7 * day, endsAt: now + 9 * day)
        XCTAssertThrowsError(try factory(maxDays: 15).make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .eventDurationTooLong(maxDays: 15))
        }
    }

    func testRejectsEmptyName() {
        let draft = EventDraft(name: "   ", startsAt: now, endsAt: now + day)
        XCTAssertThrowsError(try factory().make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .invalidEventName)
        }
    }

    func testRejectsEndBeforeStart() {
        let draft = EventDraft(name: "Bad", startsAt: now, endsAt: now - day)
        XCTAssertThrowsError(try factory().make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .invalidEventDates)
        }
    }

    func testEditPreservesIdentityAndUpdatesDetails() throws {
        let f = factory()
        let event = try f.make(
            draft: EventDraft(name: "Trip", startsAt: now, endsAt: now + day),
            creatorUserId: "u1"
        )
        let edited = try f.applyEdit(
            EventDraft(name: "Great Trip", category: .party,
                       startsAt: now, endsAt: now + 2 * day, locationName: "Banff"),
            to: event
        )
        XCTAssertEqual(edited.id, event.id)
        XCTAssertEqual(edited.inviteToken, event.inviteToken)
        XCTAssertEqual(edited.name, "Great Trip")
        XCTAssertEqual(edited.category, .party)
        XCTAssertEqual(edited.locationName, "Banff")
    }
}
