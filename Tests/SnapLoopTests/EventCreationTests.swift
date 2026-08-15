import XCTest
@testable import SnapLoop

final class EventCreationTests: XCTestCase {

    private let day: TimeInterval = 86_400

    private func factory(maxDays: Int = 15) -> EventFactory {
        var config = RemoteConfigValues.default
        config.maxEventDurationDays = maxDays
        let gens = EventFactory.Generators(
            id: { "fixed-id" },
            joinCode: { "ABC234" },
            inviteToken: { InviteToken(String(repeating: "A", count: InviteToken.length))! }
        )
        return EventFactory(config: config,
                            clock: FixedClock(Date(timeIntervalSince1970: 1_000_000)),
                            generators: gens)
    }

    func testCreatesEventWithStableIdentityFields() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let draft = EventDraft(name: "Trip", category: .trip, startsAt: start, endsAt: start + 3 * day)
        let event = try factory().make(draft: draft, creatorUserId: "u1")
        XCTAssertEqual(event.id, "fixed-id")
        XCTAssertEqual(event.joinCode, "ABC234")
        XCTAssertEqual(event.inviteToken.count, InviteToken.length)
        XCTAssertEqual(event.status, .active)
        XCTAssertEqual(event.creatorUserId, "u1")
    }

    func testAllowsPastStartDateForCatchUpScan() throws {
        let start = Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(-30 * day) // in the past
        let draft = EventDraft(name: "Last week", startsAt: start, endsAt: start + 2 * day)
        XCTAssertNoThrow(try factory().make(draft: draft, creatorUserId: "u1"))
    }

    func testEnforcesMaxDurationFromConfig() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        // 20 days with a 15-day cap.
        let draft = EventDraft(name: "Long", startsAt: start, endsAt: start + 20 * day)
        XCTAssertThrowsError(try factory(maxDays: 15).make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .eventDurationTooLong(maxDays: 15))
        }
    }

    func testRejectsEmptyName() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let draft = EventDraft(name: "   ", startsAt: start, endsAt: start + day)
        XCTAssertThrowsError(try factory().make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .invalidEventName)
        }
    }

    func testRejectsEndBeforeStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let draft = EventDraft(name: "Bad", startsAt: start, endsAt: start - day)
        XCTAssertThrowsError(try factory().make(draft: draft, creatorUserId: "u1")) {
            XCTAssertEqual($0 as? AppError, .invalidEventDates)
        }
    }

    func testEditPreservesIdentityAndUpdatesDetails() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let f = factory()
        let event = try f.make(draft: EventDraft(name: "Trip", startsAt: start, endsAt: start + day),
                               creatorUserId: "u1")
        let edited = try f.applyEdit(
            EventDraft(name: "Great Trip", category: .party,
                       startsAt: start, endsAt: start + 2 * day, locationName: "Banff"),
            to: event)
        XCTAssertEqual(edited.id, event.id)
        XCTAssertEqual(edited.inviteToken, event.inviteToken)
        XCTAssertEqual(edited.name, "Great Trip")
        XCTAssertEqual(edited.category, .party)
        XCTAssertEqual(edited.locationName, "Banff")
    }
}
