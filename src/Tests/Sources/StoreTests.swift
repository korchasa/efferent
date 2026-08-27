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

    // MARK: - Changing archives

    func testActivatingAnotherArchiveRequeuesKnownDaysAndKeepsHealthState() throws {
        let store = try Store.inMemory()
        let sample = try uuid("01")
        try store.rememberArchive("old-bucket")
        try store.markDirty(
            ["2026-08-06"],
            anchor: Anchor(typeIdentifier: "steps", value: Data([0x01]))
        )
        try store.recordSent(
            day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [sample]
        )
        try store.recordBackfillReached("2011-03-04")
        try store.recordReconciled(at: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try store.installedDay(defaultingTo: "2026-08-01")

        XCTAssertTrue(try store.activateArchive("new-bucket"))

        XCTAssertEqual(
            try store.pendingDays(limit: 10), ["2026-08-07", "2026-08-06"],
            "days known from the previous archive were not queued for the new one"
        )
        XCTAssertEqual(try store.stats().sentDays, 0)
        XCTAssertNil(try store.stats().lastUploadAt)
        XCTAssertNil(try store.stats().backfillReached)
        XCTAssertNil(try store.lastReconciledAt())
        XCTAssertEqual(try store.anchor(for: "steps"), Data([0x01]))
        XCTAssertEqual(try store.days(ofRemoved: [sample]), ["2026-08-07"])
        XCTAssertEqual(try store.installedDay(defaultingTo: "2026-09-01"), "2026-08-01")
        XCTAssertFalse(try store.activateArchive("new-bucket"), "the same archive reset twice")
    }

    func testRememberingALegacyArchiveDoesNotRequeueItsDays() throws {
        let store = try Store.inMemory()
        try store.recordSent(day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [])

        try store.rememberArchive("legacy-bucket")

        XCTAssertEqual(try store.stats().sentDays, 1)
        XCTAssertTrue(try store.pendingDays(limit: 10).isEmpty)
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

    // MARK: - When the archive turns out not to hold it

    /// The difference between the two ways of owing a day, and the reason there
    /// are two. A fingerprint is a claim about the archive; when the archive
    /// turns out not to hold the day, the claim has to go with it, or the day
    /// rebuilds identically, matches, and is never sent again.
    func testADayTheArchiveLostLosesItsFingerprintToo() throws {
        let store = try Store.inMemory()
        try store.recordSent(day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [])

        try store.markMissing(["2026-08-07"])

        XCTAssertEqual(try store.pendingDays(limit: 10), ["2026-08-07"])
        XCTAssertNil(
            try store.digest(for: "2026-08-07"),
            "the fingerprint outlived the day it was a claim about"
        )
    }

    func testMarkingADayMissingTwiceStillOwesItOnce() throws {
        let store = try Store.inMemory()
        try store.recordSent(day: "2026-08-07", digest: Data([0xAB]), sampleIdentifiers: [])

        try store.markMissing(["2026-08-07"])
        try store.markMissing(["2026-08-07"])

        XCTAssertEqual(try store.pendingDays(limit: 10), ["2026-08-07"])
        XCTAssertEqual(try store.stats().pendingDays, 1)
    }

    /// A day nobody ever heard of is owed just the same. The comparison is
    /// against what the archive *should* hold rather than against what was
    /// sent, so it also picks up days a backfill never reached.
    func testADayNeverSeenBeforeCanBeOwed() throws {
        let store = try Store.inMemory()

        XCTAssertEqual(try store.markMissing(["2026-08-07", "2026-08-08"]), 2)

        XCTAssertEqual(try store.pendingDays(limit: 10), ["2026-08-08", "2026-08-07"])
    }

    func testWhenTheArchiveWasLastCheckedSurvivesAReadBack() throws {
        let store = try Store.inMemory()
        XCTAssertNil(try store.lastReconciledAt(), "a fresh install has never checked")

        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordReconciled(at: moment)

        XCTAssertEqual(try store.lastReconciledAt(), moment)
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

        // An invented day. A fixture taken from whoever's data was to hand puts
        // a fact about that person into a public repository for no reason —
        // when Health first has anything to say is not the test's business.
        try store.recordBackfillReached("2011-03-04")

        XCTAssertEqual(try store.stats().backfillReached, "2011-03-04")
    }
}
