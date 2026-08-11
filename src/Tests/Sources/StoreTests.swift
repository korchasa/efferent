@testable import Efferent
import XCTest

final class StoreTests: XCTestCase {
    private func uuid(_ last: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C33\(last)"))
    }

    func testMarkingADayTwiceLeavesOneWaiting() throws {
        let store = try Store.inMemory()

        XCTAssertEqual(try store.markDirty(["2026-08-07"]), 1)
        XCTAssertEqual(try store.markDirty(["2026-08-07"]), 0, "the same day was queued twice")
        XCTAssertEqual(try store.pendingDays(limit: 10), ["2026-08-07"])
    }

    /// Newest first, because today is what anyone reading this actually wants,
    /// and the first export walks backwards anyway.
    func testDaysComeBackMostRecentFirst() throws {
        let store = try Store.inMemory()
        try store.markDirty(["2026-08-05", "2026-08-09", "2026-08-07"])

        XCTAssertEqual(
            try store.pendingDays(limit: 10), ["2026-08-09", "2026-08-07", "2026-08-05"]
        )
    }

    func testASentDayStopsWaitingAndKeepsItsFingerprint() throws {
        let store = try Store.inMemory()
        try store.markDirty(["2026-08-07"])

        try store.recordSent(day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [])

        XCTAssertTrue(try store.pendingDays(limit: 10).isEmpty)
        XCTAssertEqual(try store.digest(for: "2026-08-07"), Data([0xAB]))
        XCTAssertEqual(try store.stats().sentDays, 1)
        XCTAssertNotNil(try store.stats().lastUploadAt)
    }

    /// The watch syncs late, so a day that was already sent grows afterwards and
    /// has to go again. Marking has to reach a day that is no longer dirty.
    func testADaySentYesterdayCanBeMarkedAgain() throws {
        let store = try Store.inMemory()
        try store.recordSent(day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [])

        XCTAssertEqual(try store.markDirty(["2026-08-07"]), 1)

        XCTAssertEqual(try store.pendingDays(limit: 10), ["2026-08-07"])
        XCTAssertEqual(
            try store.digest(for: "2026-08-07"), Data([0xAB]),
            "the fingerprint is what says the day did not change; marking must not clear it"
        )
    }

    /// A rebuilt day that came out identical is owed nothing — but it must stop
    /// being pending, or every pass would rebuild the same week forever.
    func testAnUnchangedDayStopsWaitingWithoutBeingSent() throws {
        let store = try Store.inMemory()
        try store.recordSent(day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [])
        try store.markDirty(["2026-08-07"])

        try store.markClean(day: "2026-08-07")

        XCTAssertTrue(try store.pendingDays(limit: 10).isEmpty)
        XCTAssertEqual(try store.digest(for: "2026-08-07"), Data([0xAB]))
    }

    // MARK: - Deletions

    /// HealthKit reports a removed record as a bare identifier — no date, no
    /// type — and the record it names is already gone from Health. This table is
    /// the only thing left that knows which day has to be rebuilt without it.
    func testARemovedRecordNamesTheDayItWasIn() throws {
        let store = try Store.inMemory()
        let workout = try uuid("01")
        try store.recordSent(
            day: "2026-08-07", digest: Data([0x01]), sampleIdentifiers: [workout, uuid("02")]
        )

        XCTAssertEqual(try store.days(ofRemoved: [workout]), ["2026-08-07"])
    }

    func testAnUnknownRecordNamesNoDay() throws {
        let store = try Store.inMemory()
        try store.recordSent(day: "2026-08-07", digest: Data([0x01]), sampleIdentifiers: [uuid("01")])

        XCTAssertTrue(try store.days(ofRemoved: [uuid("99")]).isEmpty)
    }

    /// A record that is no longer in a day must not leave a row pointing at it.
    /// Otherwise deleting it later would rebuild a day it is not in, and leave
    /// the day it *is* in untouched — a correction that silently does nothing.
    func testResendingADayForgetsTheRecordsThatLeftIt() throws {
        let store = try Store.inMemory()
        let moved = try uuid("01")
        try store.recordSent(day: "2026-08-07", digest: Data([0x01]), sampleIdentifiers: [moved])

        try store.recordSent(day: "2026-08-07", digest: Data([0x02]), sampleIdentifiers: [])

        XCTAssertTrue(try store.days(ofRemoved: [moved]).isEmpty)
    }

    // MARK: - Reader state

    /// The anchor is HealthKit's "you have seen everything up to here". Saved
    /// without the days it stands for, those days would never be offered again.
    func testTheAnchorLandsWithTheDaysItStandsFor() throws {
        let store = try Store.inMemory()

        try store.markDirty(
            ["2026-08-07"],
            anchor: Anchor(typeIdentifier: "HKQuantityTypeIdentifierStepCount", value: Data([0xAB]))
        )

        XCTAssertEqual(try store.anchor(for: "HKQuantityTypeIdentifierStepCount"), Data([0xAB]))
        XCTAssertEqual(try store.pendingDays(limit: 10), ["2026-08-07"])
    }

    /// A re-scan that finds nothing new still has to move the anchor forward, or
    /// the reader hands back the same window again on every wake-up.
    func testTheAnchorMovesEvenWhenNoDayChanged() throws {
        let store = try Store.inMemory()
        try store.markDirty([String](), anchor: Anchor(typeIdentifier: "steps", value: Data([0x01])))

        try store.markDirty([String](), anchor: Anchor(typeIdentifier: "steps", value: Data([0x02])))

        XCTAssertEqual(try store.anchor(for: "steps"), Data([0x02]))
    }

    func testTheInstallDayIsDecidedOnceAndKept() throws {
        let store = try Store.inMemory()

        let first = try store.installedDay(defaultingTo: "2026-08-07")
        let later = try store.installedDay(defaultingTo: "2026-09-01")

        XCTAssertEqual(first, "2026-08-07")
        XCTAssertEqual(later, "2026-08-07", "hourly history would restart every launch")
    }

    func testHowFarBackTheExportReachedSurvivesAReadBack() throws {
        let store = try Store.inMemory()
        XCTAssertNil(try store.backfillReached())

        try store.recordBackfillReached("2015-12-12")

        XCTAssertEqual(try store.stats().backfillReached, "2015-12-12")
    }
}
