import XCTest
@testable import SnapLoop

final class EventPhotoWindowTests: XCTestCase {
    private var config = RemoteConfigValues.default

    private func calendar(_ identifier: String = "America/Toronto") -> Calendar {
        EventLifecycle.calendar(timeZone: TimeZone(identifier: identifier)!)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testFactoryPersistsCanonicalWholeDayPhotoWindowAndTimezone() throws {
        let cal = calendar()
        let now = date(2026, 8, 16, calendar: cal)
        let selectedStart = date(2026, 8, 15, hour: 17, calendar: cal)
        let selectedEnd = date(2026, 8, 18, hour: 9, calendar: cal)
        let factory = EventFactory(
            config: config,
            clock: FixedClock(now),
            calendar: cal,
            generators: .init(
                id: { "event" },
                joinCode: { "ABC234" },
                inviteToken: { InviteToken(unchecked: "ABCDEFGHIJKLMNOPQRSTUV") }
            )
        )

        let event = try factory.make(
            draft: EventDraft(name: "Trip", startsAt: selectedStart, endsAt: selectedEnd),
            creatorUserId: "creator"
        )

        XCTAssertEqual(event.photoWindowVersion, Event.canonicalPhotoWindowVersion)
        XCTAssertEqual(event.photoWindowTimeZoneId, "America/Toronto")
        XCTAssertEqual(event.startsAt, cal.startOfDay(for: selectedStart))
        let dayAfterEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: selectedEnd))!
        XCTAssertEqual(event.endsAt, dayAfterEnd.addingTimeInterval(-0.001))
        XCTAssertEqual(event.dateRange, event.startsAt...event.endsAt)
        XCTAssertEqual(
            event.photoWindowEndDayNumber! - event.photoWindowStartDayNumber!,
            3
        )
    }

    func testRenameOnlyLegacyEventOutsideCurrentWindowPreservesDatesExactly() throws {
        let cal = calendar("UTC")
        let oldStart = date(2025, 1, 10, hour: 15, calendar: cal)
        let oldEnd = date(2025, 1, 12, hour: 9, calendar: cal)
        let legacy = Event(
            id: "legacy",
            joinCode: "ABC234",
            creatorUserId: "creator",
            name: "Old name",
            startsAt: oldStart,
            endsAt: oldEnd,
            createdAt: oldStart
        )
        let draft = EventDraft(
            name: "New name",
            startsAt: oldStart,
            endsAt: oldEnd
        )
        let now = date(2026, 8, 16, calendar: cal)
        let factory = EventFactory(config: config, clock: FixedClock(now), calendar: cal)

        let edited = try factory.applyEdit(draft, to: legacy, datesChanged: false)

        XCTAssertEqual(edited.name, "New name")
        XCTAssertEqual(edited.startsAt, oldStart)
        XCTAssertEqual(edited.endsAt, oldEnd)
        XCTAssertNil(edited.photoWindowVersion)
        XCTAssertNil(edited.photoWindowTimeZoneId)
    }

    func testIntentionalLegacyDateEditMigratesWindowToCanonicalV1() throws {
        let cal = calendar()
        let now = date(2026, 8, 16, calendar: cal)
        let legacy = Event(
            id: "legacy",
            joinCode: "ABC234",
            creatorUserId: "creator",
            name: "Event",
            startsAt: date(2026, 8, 15, hour: 15, calendar: cal),
            endsAt: date(2026, 8, 16, hour: 9, calendar: cal),
            createdAt: now
        )
        let newStart = date(2026, 8, 17, hour: 14, calendar: cal)
        let newEnd = date(2026, 8, 19, hour: 7, calendar: cal)
        let draft = EventDraft(name: "Event", startsAt: newStart, endsAt: newEnd)
        let factory = EventFactory(config: config, clock: FixedClock(now), calendar: cal)

        let edited = try factory.applyEdit(draft, to: legacy, datesChanged: true)

        XCTAssertTrue(edited.usesCanonicalPhotoWindow)
        XCTAssertEqual(edited.photoWindowTimeZoneId, "America/Toronto")
        XCTAssertEqual(edited.startsAt, cal.startOfDay(for: newStart))
        XCTAssertEqual(edited.photoWindowEndDayNumber! - edited.photoWindowStartDayNumber!, 2)
    }

    func testCanonicalPhotoWindowRevisionChangesOnlyWhenCivilWindowChanges() throws {
        let cal = calendar()
        let now = date(2026, 8, 16, calendar: cal)
        let factory = EventFactory(
            config: config,
            clock: FixedClock(now),
            calendar: cal,
            generators: .init(
                id: { "event" },
                joinCode: { "ABC234" },
                inviteToken: { InviteToken(unchecked: "ABCDEFGHIJKLMNOPQRSTUV") }
            )
        )
        let start = date(2026, 8, 15, calendar: cal)
        let end = date(2026, 8, 18, calendar: cal)
        let event = try factory.make(
            draft: EventDraft(name: "Original", startsAt: start, endsAt: end),
            creatorUserId: "creator"
        )
        let originalRevision = event.photoWindowRevision

        let rename = try factory.applyEdit(
            EventDraft(name: "Renamed", startsAt: event.startsAt, endsAt: event.endsAt),
            to: event,
            datesChanged: false
        )
        XCTAssertEqual(rename.photoWindowRevision, originalRevision)

        let shiftedEnd = cal.date(byAdding: .day, value: 1, to: end)!
        let dateEdit = try factory.applyEdit(
            EventDraft(name: "Renamed", startsAt: start, endsAt: shiftedEnd),
            to: rename,
            datesChanged: true
        )
        XCTAssertNotEqual(dateEdit.photoWindowRevision, originalRevision)
    }
}
