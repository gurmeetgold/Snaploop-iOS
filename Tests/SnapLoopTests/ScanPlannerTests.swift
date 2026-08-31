import XCTest
@testable import SnapLoop

final class ScanPlannerTests: XCTestCase {

    private func config(batch: Int) -> RemoteConfigValues {
        var c = RemoteConfigValues.default
        c.maxAssetsPerSyncBatch = batch
        return c
    }

    private let day: TimeInterval = 86_400

    private func makeEvent(start: Date, end: Date) -> Event {
        Event(id: "e1", joinCode: "ABC234", creatorUserId: "u1", name: "Trip",
              startsAt: start, endsAt: end, createdAt: start)
    }

    private func asset(_ id: String, _ date: Date) -> PhotoAsset {
        PhotoAsset(id: id, creationDate: date)
    }

    func testDefaultBatchScansOneHundredAssetsBeforeRequestingNextBatch() {
        let start = Date(timeIntervalSince1970: 900_000)
        let event = makeEvent(start: start, end: start.addingTimeInterval(10 * day))
        let assets = (0..<101).map { asset("a\($0)", start.addingTimeInterval(Double($0) * 60)) }

        XCTAssertEqual(RemoteConfigValues.default.maxAssetsPerSyncBatch, 100)

        let plan = ScanPlanner(config: .default)
            .plan(assets: assets, event: event, state: ScanState(eventId: "e1"))

        XCTAssertEqual(plan.toScan.count, 100)
        XCTAssertEqual(plan.remaining, 1)
        XCTAssertTrue(plan.hasMore)
    }

    func testFiltersToEventDateRange() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(2 * day)
        let event = makeEvent(start: start, end: end)

        let assets = [
            asset("before", start.addingTimeInterval(-day)),   // out
            asset("inA", start.addingTimeInterval(day)),       // in
            asset("inB", end),                                 // in (inclusive)
            asset("after", end.addingTimeInterval(day)),       // out
        ]
        let plan = ScanPlanner(config: config(batch: 100))
            .plan(assets: assets, event: event, state: ScanState(eventId: "e1"))

        XCTAssertEqual(plan.toScan.map(\.id), ["inA", "inB"])
        XCTAssertEqual(plan.remaining, 0)
    }

    func testCanonicalWindowIncludesExactEndBoundaryAndExcludesNextMillisecond() {
        let timeZone = TimeZone(identifier: "America/Toronto")!
        let calendar = EventLifecycle.calendar(timeZone: timeZone)
        let selectedStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12))!
        let selectedEnd = calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 12))!
        let bounds = EventLifecycle.canonicalBounds(
            startsAt: selectedStart,
            endsAt: selectedEnd,
            calendar: calendar
        )
        let event = Event(
            id: "e1",
            joinCode: "ABC234",
            creatorUserId: "u1",
            name: "Trip",
            startsAt: bounds.lowerBound,
            endsAt: bounds.upperBound,
            photoWindowVersion: Event.canonicalPhotoWindowVersion,
            photoWindowTimeZoneId: timeZone.identifier,
            photoWindowStartDayNumber: EventLifecycle.localDayNumber(selectedStart, calendar: calendar),
            photoWindowEndDayNumber: EventLifecycle.localDayNumber(selectedEnd, calendar: calendar),
            createdAt: bounds.lowerBound
        )
        let assets = [
            asset("before", bounds.lowerBound.addingTimeInterval(-0.001)),
            asset("start", bounds.lowerBound),
            asset("end", bounds.upperBound),
            asset("after", bounds.upperBound.addingTimeInterval(0.001)),
        ]

        let plan = ScanPlanner(config: config(batch: 100))
            .plan(assets: assets, event: event, state: ScanState(eventId: "e1"))

        XCTAssertEqual(plan.toScan.map(\.id), ["start", "end"])
    }

    func testNeverRescansAlreadyScannedAssets() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let event = makeEvent(start: start, end: start.addingTimeInterval(5 * day))
        let assets = (0..<5).map { asset("a\($0)", start.addingTimeInterval(Double($0) * day)) }

        var state = ScanState(eventId: "e1")
        state.markScanned(["a0", "a2", "a4"])

        let plan = ScanPlanner(config: config(batch: 100))
            .plan(assets: assets, event: event, state: state)

        XCTAssertEqual(plan.toScan.map(\.id), ["a1", "a3"])
        XCTAssertEqual(plan.alreadyScanned, 3)
    }

    func testBatchCapAndRemaining() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let event = makeEvent(start: start, end: start.addingTimeInterval(10 * day))
        let assets = (0..<10).map { asset("a\($0)", start.addingTimeInterval(Double($0) * 3600)) }

        let plan = ScanPlanner(config: config(batch: 4))
            .plan(assets: assets, event: event, state: ScanState(eventId: "e1"))

        XCTAssertEqual(plan.toScan.count, 4)
        XCTAssertEqual(plan.remaining, 6)
        XCTAssertTrue(plan.hasMore)
    }

    func testOrderedOldestFirstWithStableTieBreak() {
        let start = Date(timeIntervalSince1970: 4_000_000)
        let event = makeEvent(start: start, end: start.addingTimeInterval(10 * day))
        let sameInstant = start.addingTimeInterval(day)
        let assets = [
            asset("z", sameInstant),
            asset("a", sameInstant),
            asset("m", start.addingTimeInterval(2 * day)),
        ]
        let plan = ScanPlanner(config: config(batch: 100))
            .plan(assets: assets, event: event, state: ScanState(eventId: "e1"))
        // Same instant → tie-break by id ascending; then the later date.
        XCTAssertEqual(plan.toScan.map(\.id), ["a", "z", "m"])
    }

    func testTwoPassesCoverEverythingExactlyOnce() {
        let start = Date(timeIntervalSince1970: 5_000_000)
        let event = makeEvent(start: start, end: start.addingTimeInterval(10 * day))
        let assets = (0..<7).map { asset("a\($0)", start.addingTimeInterval(Double($0) * 3600)) }
        let planner = ScanPlanner(config: config(batch: 4))

        var state = ScanState(eventId: "e1")
        let first = planner.plan(assets: assets, event: event, state: state)
        state.markScanned(first.toScan.map(\.id))
        let second = planner.plan(assets: assets, event: event, state: state)
        state.markScanned(second.toScan.map(\.id))
        let third = planner.plan(assets: assets, event: event, state: state)

        XCTAssertEqual(first.toScan.count, 4)
        XCTAssertEqual(second.toScan.count, 3)
        XCTAssertTrue(third.isEmpty)
        // Every asset scanned exactly once.
        XCTAssertEqual(state.scannedCount, 7)
    }

    func testEmptyLibraryYieldsEmptyPlan() {
        let start = Date(timeIntervalSince1970: 6_000_000)
        let event = makeEvent(start: start, end: start.addingTimeInterval(day))
        let plan = ScanPlanner(config: config(batch: 10))
            .plan(assets: [], event: event, state: ScanState(eventId: "e1"))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.hasMore)
    }
}
