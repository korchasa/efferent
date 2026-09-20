import CryptoKit
@testable import Efferent
import GRDB
import XCTest

/// The journal of what an agent changed.
///
/// It exists because nothing else keeps that: the service is told counts and
/// codes on purpose, and Health keeps the record without keeping who asked for
/// it. So the tests here are about the two things the screen and undo need from
/// it — that an item comes back saying what it said, and that an edit applied
/// twice is still one line.
final class EditLogTests: XCTestCase {
    static let utc = Day.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    /// 8 Sep 2025, 13:00 UTC.
    static let noon = Date(timeIntervalSince1970: 1_757_336_400)

    private func lunch(id: String = "agent:meal:1") -> EditItem {
        .put(.init(
            id: id, metric: "dietaryEnergy", start: 1_757_336_400, end: 1_757_337_300,
            value: 520, unit: "kcal", stage: nil
        ))
    }

    // MARK: - One item, written down and read back

    func testAnAppliedItemComesBackSayingWhatItSaid() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            lunch(), at: 0, in: "1757336400000-abcdefgh", state: .written, day: "2025-09-08",
            at: Self.noon
        )

        let entries = try store.recentEdits()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.recordID, "agent:meal:1")
        XCTAssertEqual(entry.metric, "dietaryEnergy")
        XCTAssertEqual(entry.value, 520)
        XCTAssertEqual(entry.unit, "kcal")
        XCTAssertEqual(entry.day, "2025-09-08")
        XCTAssertEqual(entry.start, Date(timeIntervalSince1970: 1_757_336_400))
        XCTAssertEqual(entry.end, Date(timeIntervalSince1970: 1_757_337_300))
        XCTAssertEqual(entry.state, .written)
        XCTAssertNil(entry.code)
        XCTAssertNil(entry.personActedAt)
        XCTAssertTrue(entry.personCanAct)
        XCTAssertEqual(try store.edit(entry.id), entry)
    }

    func testARefusedItemKeepsTheWordItWasTurnedAwayWith() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            lunch(), at: 0, in: "1757336400000-abcdefgh", state: .refused, day: nil,
            code: .unauthorized, at: Self.noon
        )

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertEqual(entry.code, .unauthorized)
        // Nothing was written, so there is nothing to take back out.
        XCTAssertFalse(entry.personCanAct)
    }

    func testAnEditNobodyCouldOpenIsOneLineWithNoRecord() throws {
        let store = try Store.inMemory()
        try store.recordUnopenedEdit("1757336400000-abcdefgh", code: .badSignature, at: Self.noon)

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertEqual(entry.state, .refused)
        XCTAssertEqual(entry.code, .badSignature)
        XCTAssertEqual(entry.recordID, "")
        XCTAssertNil(entry.metric)
        XCTAssertFalse(entry.personCanAct)
    }

    // MARK: - The same item, again

    func testTheSameItemAppliedAgainStaysOneRowAndComesBackStanding() throws {
        let store = try Store.inMemory()
        let name = "1757336400000-abcdefgh"
        try store.recordEdit(lunch(), at: 0, in: name, state: .written, day: "2025-09-08", at: Self.noon)
        let first = try XCTUnwrap(store.recentEdits().first)
        try store.recordPersonAction(first.id, left: .removed, at: Self.noon.addingTimeInterval(60))

        // The record is gone from Health and a person took it out, so the row
        // says removal and says who did it.
        XCTAssertEqual(try store.edit(first.id)?.state, .removed)
        XCTAssertEqual(try store.edit(first.id)?.askedBy, .person)
        XCTAssertNotNil(try store.edit(first.id)?.personActedAt)

        // A run that died between writing and answering applies the whole edit
        // again. The record is back in Health, so the line must say so.
        try store.recordEdit(
            lunch(), at: 0, in: name, state: .written, day: "2025-09-08",
            at: Self.noon.addingTimeInterval(120)
        )

        let entries = try store.recentEdits()
        XCTAssertEqual(entries.count, 1, "the same item stood twice in the journal")
        XCTAssertEqual(entries.first?.state, .written)
        XCTAssertEqual(entries.first?.askedBy, .agent, "the agent wrote it, again")
        XCTAssertNil(entries.first?.personActedAt)
    }

    func testTwoItemsOfOneEditAreTwoLines() throws {
        let store = try Store.inMemory()
        let name = "1757336400000-abcdefgh"
        try store.recordEdit(lunch(), at: 0, in: name, state: .written, day: "2025-09-08", at: Self.noon)
        try store.recordEdit(
            lunch(id: "agent:meal:2"), at: 1, in: name, state: .written, day: "2025-09-08",
            at: Self.noon
        )

        XCTAssertEqual(try store.recentEdits().count, 2)
    }

    func testTheNewestIsFirst() throws {
        let store = try Store.inMemory()
        try store.recordEdit(lunch(), at: 0, in: "a", state: .written, day: "2025-09-07", at: Self.noon)
        try store.recordEdit(
            lunch(id: "agent:meal:2"), at: 0, in: "b", state: .written, day: "2025-09-08",
            at: Self.noon.addingTimeInterval(3600)
        )

        XCTAssertEqual(try store.recentEdits().map(\.recordID), ["agent:meal:2", "agent:meal:1"])
    }

    // MARK: - What the screen counts

    func testTheSummaryCountsByStateAndOnlyPastTheWatermark() throws {
        let store = try Store.inMemory()
        let old = Self.noon
        let fresh = Self.noon.addingTimeInterval(3600)
        try store.recordEdit(lunch(), at: 0, in: "a", state: .written, day: "2025-09-08", at: old)
        try store.recordEdit(
            lunch(id: "agent:meal:2"), at: 1, in: "a", state: .written, day: "2025-09-08", at: fresh
        )
        try store.recordEdit(
            lunch(id: "agent:meal:3"), at: 2, in: "a", state: .refused, day: nil,
            code: .badRange, at: fresh
        )
        try store.recordEdit(
            .delete(id: "agent:meal:9"), at: 3, in: "a", state: .removed, day: "2025-09-08", at: fresh
        )

        let summary = try store.editSummary(
            seenAt: old, todayFrom: Self.noon.addingTimeInterval(-13 * 3600)
        )
        XCTAssertEqual(summary.ever.total, 4)
        XCTAssertEqual(summary.ever.written, 2)
        XCTAssertEqual(summary.ever.standing, 2)
        XCTAssertEqual(summary.today.total, 4)
        // The one written at the watermark itself has been seen.
        XCTAssertEqual(summary.unseen.total, 3)
        XCTAssertEqual(summary.unseen.written, 1)
        XCTAssertEqual(summary.unseen.refused, 1)
        XCTAssertEqual(summary.unseen.removed, 1)
    }

    func testNothingLookedAtYetCountsTheWholeJournalAsUnseen() throws {
        let store = try Store.inMemory()
        try store.recordEdit(lunch(), at: 0, in: "a", state: .written, day: "2025-09-08", at: Self.noon)

        XCTAssertNil(try store.editsSeenAt())
        let summary = try store.editSummary(seenAt: nil, todayFrom: Self.noon.addingTimeInterval(-3600))
        XCTAssertEqual(summary.unseen.written, 1)

        try store.recordEditsSeen(at: Self.noon.addingTimeInterval(60))
        XCTAssertEqual(
            try store.editsSeenAt()?.timeIntervalSince1970,
            Self.noon.addingTimeInterval(60).timeIntervalSince1970
        )
        let seen = try store.editsSeenAt()
        let after = try store.editSummary(
            seenAt: seen, todayFrom: Self.noon.addingTimeInterval(-3600)
        )
        XCTAssertEqual(after.unseen.total, 0)
        XCTAssertEqual(after.ever.total, 1)
    }

    // MARK: - Another archive

    func testAnotherArchiveEmptiesTheJournal() throws {
        let store = try Store.inMemory()
        XCTAssertTrue(try store.activateArchive("aaaaaaaaaaaaaaaaaaaaaaaaaa"))
        try store.recordEdit(lunch(), at: 0, in: "a", state: .written, day: "2025-09-08", at: Self.noon)
        try store.recordEditsSeen(at: Self.noon)

        XCTAssertTrue(try store.activateArchive("bbbbbbbbbbbbbbbbbbbbbbbbbb"))

        // The ids in it name records this phone no longer tracks, so keeping
        // them would offer an undo that cannot work.
        XCTAssertEqual(try store.recentEdits().count, 0)
        XCTAssertNil(try store.editsSeenAt())
    }

    // MARK: - What the applier writes down

    func testTheApplierWritesDownEveryItemItTouched() async throws {
        var world = try ApplierTests.World()
        world.writer.refuse["agent:sleep:1"] = .unauthorized
        let written = try world.submit(ApplierTests.breakfast + "," + ApplierTests.sleep)
        let name = try world.submit(#"{"op":"delete","id":"agent:water:1"}"#)

        _ = try await world.applier().run()

        let entries = try world.store.recentEdits()
        XCTAssertEqual(entries.count, 3)

        // Health has nothing under that id, so the removal is nobody's business:
        // it is refused the way it always was, and no decision is asked for.
        let removed = try XCTUnwrap(entries.first { $0.editName == name })
        XCTAssertEqual(removed.state, .refused)
        XCTAssertEqual(removed.code, .notFound)
        XCTAssertEqual(removed.recordID, "agent:water:1")
        // A deletion names no metric and no instant: the record was gone before
        // anything could ask it anything.
        XCTAssertNil(removed.metric)
        XCTAssertNil(removed.day)
        XCTAssertFalse(removed.personCanAct)

        let meal = try XCTUnwrap(entries.first { $0.editName == written && $0.item == 0 })
        XCTAssertEqual(meal.state, .written)
        XCTAssertEqual(meal.metric, "dietaryEnergy")
        XCTAssertEqual(meal.value, 520)
        XCTAssertEqual(meal.unit, "kcal")
        XCTAssertEqual(meal.day, "2025-09-07")

        let sleep = try XCTUnwrap(entries.first { $0.recordID == "agent:sleep:1" })
        XCTAssertEqual(sleep.state, .refused)
        XCTAssertEqual(sleep.code, .unauthorized)
        XCTAssertEqual(sleep.stage, "asleepCore")
        XCTAssertNil(sleep.day)
    }

    func testAnEditTheApplierCouldNotOpenIsWrittenDownToo() async throws {
        var world = try ApplierTests.World()
        let stranger = Curve25519.Signing.PrivateKey()
        let name = try world.submit(ApplierTests.breakfast, signedBy: stranger)

        _ = try await world.applier().run()

        let entry = try XCTUnwrap(world.store.recentEdits().first)
        XCTAssertEqual(entry.editName, name)
        XCTAssertEqual(entry.state, .refused)
        XCTAssertEqual(entry.code, .badSignature)
        XCTAssertEqual(entry.recordID, "")
    }

    // MARK: - Rows an older build left behind

    /// Nothing waits for an answer any more, but a phone updated from a build
    /// that asked may still hold a row that does. It has to keep reading as
    /// what it was, and it must not look like something that can be taken back.
    func testAHeldItemStillReadsAsOneAndRebuildsIntoTheItemItCameFrom() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            lunch(), at: 0, in: "1757336400000-abcdefgh", state: .waiting, day: "2025-09-08",
            code: .awaitingApproval, at: Self.noon
        )

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertEqual(entry.state, .waiting)
        XCTAssertEqual(entry.code, .awaitingApproval)
        XCTAssertFalse(entry.personCanAct, "nothing was ever written")
        XCTAssertEqual(entry.asItem, lunch())
    }

    func testARemovalThatWasWaitingRebuildsAsARemoval() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            .delete(id: "agent:meal:1"), at: 0, in: "a", state: .waiting, day: nil,
            code: .awaitingApproval, at: Self.noon
        )

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertEqual(entry.asItem, .delete(id: "agent:meal:1"))
    }

    func testAnUnreadableEditRebuildsIntoNothing() throws {
        let store = try Store.inMemory()
        try store.recordUnopenedEdit("a", code: .badSignature, at: Self.noon)
        XCTAssertNil(try XCTUnwrap(store.recentEdits().first).asItem)
    }

    func testWhatIsWaitingIsCountedWithNoWatermarkOverIt() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            lunch(), at: 0, in: "a", state: .waiting, day: "2025-09-08",
            code: .awaitingApproval, at: Self.noon
        )
        try store.recordEditsSeen(at: Self.noon.addingTimeInterval(60))

        let summary = try store.editSummary(
            seenAt: store.editsSeenAt(), todayFrom: Self.noon.addingTimeInterval(-3600)
        )
        // Looked at and still unanswered: the screen must keep asking.
        XCTAssertEqual(summary.ever.waiting, 1)
        XCTAssertEqual(summary.unseen.total, 0)
        XCTAssertEqual(summary.ever.total, 0, "a question is not something the agent did")
        XCTAssertTrue(summary.ever.anything)
    }

    // MARK: - What an item pushed out

    /// The whole of what undo puts back, and the reason a change may land
    /// without anybody being asked first.
    func testWhatAnItemPushedOutComesBackWithTheRow() throws {
        let store = try Store.inMemory()
        let meal = DisplacedRecord(
            metric: "dietaryEnergy",
            start: Self.noon,
            end: Self.noon.addingTimeInterval(900),
            value: 520,
            unit: "kcal",
            day: "2025-09-08"
        )
        try store.recordEdit(
            lunch(), at: 0, in: "a", state: .written, day: "2025-09-08",
            displaced: [meal], at: Self.noon
        )

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertEqual(entry.displaced, [meal])
        XCTAssertEqual(entry.displaced.first?.asPut(id: entry.recordID).value, 520)
        XCTAssertTrue(entry.personCanAct)
    }

    /// A deletion an older build wrote down kept nothing, so there is nothing
    /// to put back, and the screen must not offer a button that empties a day.
    func testADeletionWithNothingKeptCannotBeUndone() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            .delete(id: "agent:meal:1"), at: 0, in: "a", state: .removed, day: "2025-09-08",
            at: Self.noon
        )

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertTrue(entry.displaced.isEmpty)
        XCTAssertFalse(entry.personCanAct)
    }

    /// A deletion that kept what it removed can be undone: writing that record
    /// back under the same id is the whole of it.
    func testADeletionThatKeptWhatItRemovedCanBeUndone() throws {
        let store = try Store.inMemory()
        try store.recordEdit(
            .delete(id: "agent:meal:1"), at: 0, in: "a", state: .removed, day: "2025-09-08",
            displaced: [DisplacedRecord(
                metric: "dietaryEnergy",
                start: Self.noon,
                end: Self.noon.addingTimeInterval(900),
                value: 520,
                unit: "kcal",
                day: "2025-09-08"
            )],
            at: Self.noon
        )

        let entry = try XCTUnwrap(store.recentEdits().first)
        XCTAssertTrue(entry.personCanAct)
        XCTAssertEqual(entry.displaced.first?.asPut(id: "agent:meal:1").metric, "dietaryEnergy")
    }

    func testAnEditComesBackWholeSoAnOutcomeCanBeRebuilt() throws {
        let store = try Store.inMemory()
        try store.recordEdit(lunch(), at: 0, in: "a", state: .written, day: "2025-09-08", at: Self.noon)
        try store.recordEdit(
            lunch(id: "agent:meal:2"), at: 1, in: "a", state: .waiting, day: "2025-09-08",
            code: .awaitingApproval, at: Self.noon
        )
        try store.recordEdit(lunch(id: "agent:meal:3"), at: 0, in: "b", state: .written, day: "2025-09-08", at: Self.noon)

        let rows = try store.edits(of: "a")
        XCTAssertEqual(rows.map(\.item), [0, 1], "in the order the items arrived in")
        XCTAssertEqual(rows.map(\.state), [.written, .waiting])
        XCTAssertEqual(try store.edits(of: "b").count, 1, "one edit's rows, not another's")
    }

    func testAnEditAppliedTwiceLeavesTheJournalAsItWas() async throws {
        var world = try ApplierTests.World()
        world.service.outcomeStatus = 500
        try world.submit(ApplierTests.breakfast)

        _ = try await world.applier().run()
        // The outcome never landed, so the edit is still in the queue and the
        // next run applies it again.
        world.service.outcomeStatus = 200
        _ = try await world.applier().run()

        XCTAssertEqual(try world.store.recentEdits().count, 1)
        XCTAssertEqual(try world.store.recentEdits().first?.state, .written)
    }

    // MARK: - The v8 migration

    /// A row of every state an older build could write, carried across the
    /// split of `state` into what happened to the record and who asked for it.
    ///
    /// The journal is the only copy there is — the service is told counts and
    /// codes and nothing else — so a mistake in this mapping is history lost in
    /// silence, on a phone that has just updated. Each old `undone` row is read
    /// off its own evidence: no metric means the item was a removal, so taking
    /// it back wrote a record; a metric with nothing displaced means a plain
    /// addition, so taking it back removed one.
    func testEveryStateAnOlderBuildWroteIsMappedOntoAnOperationAndAnActor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editlog-v7-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let kept = DisplacedRecord(
            metric: "dietaryEnergy",
            start: Self.noon,
            end: Self.noon.addingTimeInterval(900),
            value: 410,
            unit: "kcal",
            day: "2025-09-08"
        )
        let displaced = try XCTUnwrap(String(data: JSONEncoder().encode([kept]), encoding: .utf8))
        let took = Self.noon.addingTimeInterval(3600).timeIntervalSince1970

        // The shape the journal had before this migration, filled by hand: the
        // point is to read what an older build actually wrote, not what today's
        // writer would produce.
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Database.migrator().migrate(queue, upTo: "v7.editLog.owed.goes")
            try queue.write { db in
                func row(
                    _ item: Int, _ state: String, metric: String?, code: String? = nil,
                    displaced: String? = nil, undoneAt: Double? = nil
                ) throws {
                    try db.execute(
                        sql: """
                        INSERT INTO editLog
                            (editName, item, recordId, state, metric, startAt, endAt, value, unit,
                             stage, day, code, appliedAt, undoneAt, displaced)
                        VALUES ('a', ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            item, "agent:meal:\(item)", state, metric,
                            metric == nil ? nil : Self.noon.timeIntervalSince1970,
                            metric == nil ? nil : Self.noon.addingTimeInterval(900).timeIntervalSince1970,
                            metric == nil ? nil : 520, metric == nil ? nil : "kcal",
                            "2025-09-08", code, Self.noon.timeIntervalSince1970, undoneAt, displaced,
                        ]
                    )
                }
                try row(0, "applied", metric: "dietaryEnergy")
                try row(1, "deleted", metric: nil, displaced: displaced)
                try row(2, "refused", metric: "dietaryEnergy", code: "unauthorized")
                try row(3, "waiting", metric: "dietaryEnergy", code: "awaitingApproval")
                try row(4, "declined", metric: "dietaryEnergy", code: "declined")
                try row(5, "undone", metric: "dietaryEnergy", undoneAt: took)
                try row(6, "undone", metric: "dietaryEnergy", displaced: displaced, undoneAt: took)
                try row(7, "undone", metric: nil, displaced: displaced, undoneAt: took)
                try row(8, "deleted", metric: nil)
            }
        }

        let rows = try Store(url: url).edits(of: "a")
        XCTAssertEqual(rows.count, 9, "the migration dropped a row")
        XCTAssertEqual(
            rows.map { "\($0.state.rawValue)/\($0.askedBy.rawValue)" },
            [
                "written/agent",
                "removed/agent",
                "refused/agent",
                "waiting/agent",
                "declined/agent",
                // The person took out an addition, which is a removal.
                "removed/person",
                // The person put back what a replacement pushed out.
                "written/person",
                // The person put back what a removal took away.
                "written/person",
                "removed/agent",
            ]
        )

        // The moment they acted came across with the column's new name.
        XCTAssertEqual(rows[5].personActedAt?.timeIntervalSince1970, took)
        XCTAssertNil(rows[0].personActedAt)
        // What was displaced still reads, and still says what can be done next.
        XCTAssertEqual(rows[1].displaced, [kept])
        XCTAssertTrue(rows[1].personCanAct, "a removal that kept what it took can be written back")
        XCTAssertFalse(rows[8].personCanAct, "a removal that kept nothing has nothing to write back")
        XCTAssertFalse(rows[5].personCanAct, "the person has already had their say")
    }
}
