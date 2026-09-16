@testable import Efferent
import XCTest

/// The wording of the edit screens.
///
/// Nearly all of what those screens are is here: the journal holds wire names,
/// whole seconds and one-word codes, and a person must never be shown one of
/// those. Worth testing on its own because a sentence that reads wrongly is a
/// defect nothing else in the app can catch.
final class EditWordsTests: XCTestCase {
    static let utc = Day.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    private func made(
        state: EditEntry.State = .applied,
        recordID: String = "agent:meal:1",
        metric: String? = "dietaryEnergy",
        start: Double? = 1_757_336_400,
        end: Double? = 1_757_337_300,
        value: Double? = 520,
        unit: String? = "kcal",
        stage: String? = nil,
        day: String? = "2025-09-08",
        code: OutcomeCode? = nil,
        undoneAt: Double? = nil,
        displaced: [DisplacedRecord] = []
    ) -> EditEntry {
        EditEntry(
            id: 1,
            editName: "1757336400000-abcdefgh",
            item: 0,
            recordID: recordID,
            state: state,
            metric: metric,
            start: start.map { Date(timeIntervalSince1970: $0) },
            end: end.map { Date(timeIntervalSince1970: $0) },
            value: value,
            unit: unit,
            stage: stage,
            day: day,
            code: code,
            at: Date(timeIntervalSince1970: 1_757_337_360),
            undoneAt: undoneAt.map { Date(timeIntervalSince1970: $0) },
            displaced: displaced
        )
    }

    /// A record of the same shape `made()` describes, as the thing an item
    /// pushed out of Health.
    private func pushedOut(value: Double = 410) -> DisplacedRecord {
        DisplacedRecord(
            metric: "dietaryEnergy",
            start: Date(timeIntervalSince1970: 1_757_336_400),
            end: Date(timeIntervalSince1970: 1_757_337_300),
            value: value,
            unit: "kcal",
            day: "2025-09-08"
        )
    }

    // MARK: - A row

    func testAQuantityIsSaidWithThePersonsWordForTheMetric() {
        XCTAssertEqual(EditWords.title(made()), "Energy · 520 kcal")
        XCTAssertEqual(
            EditWords.title(made(metric: "bodyMass", value: 78.4, unit: "kg", stage: nil)),
            "Body mass · 78.4 kg"
        )
    }

    func testSleepIsSaidByItsStageAndItsLength() {
        let night = made(
            metric: "sleep", start: 1_757_196_000, end: 1_757_221_200, value: nil, unit: nil,
            stage: "asleepCore", day: "2025-09-07"
        )
        XCTAssertEqual(EditWords.title(night), "Sleep · core sleep 7 h")
        XCTAssertEqual(EditWords.length(night), "7 h")
    }

    func testAMetricThisBuildDoesNotKnowIsPrintedAsItCame() {
        // Never invented: an unknown wire name says what the wire said rather
        // than a word this app made up for it.
        XCTAssertEqual(EditWords.title(made(metric: "dietaryZinc", value: 3, unit: "mg")), "dietaryZinc · 3 mg")
    }

    func testARemovalAndAnUnreadableEditSayWhatTheyAre() {
        XCTAssertEqual(
            EditWords.title(made(state: .deleted, metric: nil, start: nil, end: nil, value: nil, unit: nil)),
            "A record your agent removed"
        )
        XCTAssertEqual(
            EditWords.title(made(
                state: .refused, recordID: "", metric: nil, start: nil, end: nil, value: nil,
                unit: nil, day: nil, code: .badSignature
            )),
            "An edit this phone could not read"
        )
    }

    func testTheDetailSaysWhenItArrivedAndWhatItDid() {
        XCTAssertEqual(
            EditWords.detail(made(), in: Self.utc),
            "13:16 · for 8 Sep 2025, 13:00 – 13:15"
        )
        XCTAssertEqual(
            EditWords.detail(made(state: .refused, code: .unauthorized), in: Self.utc),
            "13:16 · writing this is switched off in Health"
        )
        XCTAssertEqual(
            EditWords.detail(
                made(state: .undone, undoneAt: 1_757_340_000), in: Self.utc
            ),
            "13:16 · undone at 14:00"
        )
    }

    func testAStretchAcrossMidnightNamesBothDates() {
        let night = made(
            metric: "sleep", start: 1_757_196_000, end: 1_757_221_200, value: nil, unit: nil,
            stage: "asleepCore", day: "2025-09-06"
        )
        XCTAssertEqual(
            EditWords.span(night, in: Self.utc),
            "from 6 Sep 2025 22:00 to 7 Sep 2025 05:00"
        )
    }

    // MARK: - A run, counted

    func testARunIsCountedAsASentence() {
        var tally = EditTally()
        tally.applied = 1
        XCTAssertEqual(EditWords.summary(tally), "Your agent changed 1 record in Health.")
        tally.deleted = 2
        tally.refused = 1
        XCTAssertEqual(
            EditWords.summary(tally),
            "Your agent changed 1 record, removed 2 records and had 1 record refused in Health."
        )
        XCTAssertEqual(EditWords.summary(EditTally()), "Your agent changed nothing.")
    }

    func testTheLegendCountsEveryStateAndSaysSoWhenThereAreNone() {
        var tally = EditTally()
        tally.applied = 3
        tally.undone = 1
        XCTAssertEqual(EditWords.counted(tally), "3 applied, 1 undone")
        XCTAssertEqual(EditWords.counted(EditTally()), "no edits")
    }

    // MARK: - One edit, in full

    func testTheFieldsSayEverythingTheJournalHoldsAndNoWireName() {
        let fields = EditWords.fields(made(), in: Self.utc)
        let names = fields.map(\.name)
        // No "day" line: the record landed on the day it began on, and the
        // instants above have already said which day that is.
        XCTAssertEqual(names, ["metric", "value", "from", "to", "written", "agent's id"])
        XCTAssertEqual(fields.first?.value, "Energy")
        XCTAssertEqual(fields[1].value, "520 kcal")
        XCTAssertEqual(fields[2].value, "8 Sep 2025 13:00")
        XCTAssertEqual(fields.last?.value, "agent:meal:1")
        // The one value on these screens that is data rather than a word.
        XCTAssertTrue(fields.last?.verbatim == true)
        XCTAssertFalse(fields.first?.verbatim == true)
    }

    func testTheDayIsPrintedWhenTheInstantsCannotSayIt() {
        let removed = made(
            state: .deleted, metric: nil, start: nil, end: nil, value: nil, unit: nil,
            day: "2025-09-08"
        )
        XCTAssertTrue(
            EditWords.fields(removed, in: Self.utc)
                .contains { $0.name == "day" && $0.value == "8 Sep 2025" }
        )
    }

    func testARefusedEditSaysWhyAndOffersNothingToTakeBack() {
        let refused = made(state: .refused, day: nil, code: .badUnit)
        XCTAssertTrue(
            EditWords.fields(refused, in: Self.utc)
                .contains { $0.name == "refused" && $0.value == "the unit does not fit the metric" }
        )
        XCTAssertTrue(EditWords.note(refused, in: Self.utc).hasPrefix("Nothing was written"))
    }

    func testEveryRefusalHasASentenceAndNoneOfThemIsTheWireWord() {
        // Every one of them, from the closed set itself: a code added to the wire
        // without a sentence would reach a person as the wire word.
        for code in OutcomeCode.allCases {
            let said = EditWords.reason(code)
            XCTAssertFalse(said.isEmpty, "\(code) has nothing to say")
            XCTAssertNotEqual(said, code.rawValue, "\(code) shows the wire word")
            XCTAssertTrue(said.contains(" "), "\(code) is a word rather than a sentence")
        }
    }

    // MARK: - Rows an older build left behind

    /// Nothing waits for an answer now, so such a row is history: it says that
    /// Health was never touched, that no answer was ever given, and it offers
    /// nothing to press.
    func testAnItemLeftWaitingSaysNothingEverHappenedToIt() {
        let waiting = made(state: .waiting, code: .awaitingApproval)
        XCTAssertEqual(EditWords.title(waiting), "Energy · 520 kcal")
        XCTAssertEqual(EditWords.detail(waiting, in: Self.utc), "13:16 · for 8 Sep 2025, 13:00 – 13:15")
        XCTAssertTrue(EditWords.note(waiting, in: Self.utc).hasPrefix("An older version of this app"))
        // Not the word "refused": nothing was turned away, and nothing written.
        XCTAssertTrue(
            EditWords.fields(waiting, in: Self.utc)
                .contains { $0.name == "your answer" && $0.value == "never given" }
        )
        XCTAssertFalse(EditWords.fields(waiting, in: Self.utc).contains { $0.name == "refused" })
        XCTAssertFalse(waiting.canBeUndone, "its own page offers nothing to press")
    }

    func testARemovalLeftWaitingReadsInThePastTense() {
        let waiting = made(
            state: .waiting, metric: nil, start: nil, end: nil, value: nil, unit: nil,
            day: nil, code: .awaitingApproval
        )
        XCTAssertEqual(EditWords.title(waiting), "A record your agent wanted to remove")
        XCTAssertEqual(
            EditWords.detail(
                made(
                    state: .waiting, metric: nil, start: nil, end: nil, value: nil, unit: nil,
                    day: "2025-09-08", code: .awaitingApproval
                ),
                in: Self.utc
            ),
            "13:16 · a record from 8 Sep 2025"
        )
        XCTAssertEqual(EditWords.detail(waiting, in: Self.utc), "13:16 · never written")
    }

    func testOneTurnedDownSaysHealthWasNeverTouched() {
        let no = made(state: .declined, code: .declined)
        XCTAssertEqual(EditWords.detail(no, in: Self.utc), "13:16 · you turned this down")
        XCTAssertTrue(EditWords.note(no, in: Self.utc).hasPrefix("You turned this down"))
        XCTAssertTrue(
            EditWords.fields(no, in: Self.utc)
                .contains { $0.name == "your answer" && $0.value == "no" }
        )
        XCTAssertFalse(no.canBeUndone)
    }

    func testARowThatWasNeverAnsweredIsCountedApartFromTheRest() {
        XCTAssertEqual(
            EditWords.counted(EditTally(applied: 2, waiting: 1)), "1 never answered, 2 applied"
        )
    }

    // MARK: - Taking one back

    /// An addition pushed nothing out, so taking it back is a removal, and both
    /// the key and the alert say so.
    func testTakingBackAnAdditionIsARemovalAndSaysSo() {
        let added = made()
        XCTAssertFalse(EditWords.restores(added))
        XCTAssertEqual(EditWords.undoWord(added), "Undo")
        XCTAssertEqual(EditWords.undoAction(added), "Remove from Health")
        XCTAssertEqual(EditWords.undoQuestion(added), "Remove this record?")
        XCTAssertEqual(
            EditWords.consequence(added),
            "The energy record leaves Health, and 8 Sep 2025 goes to the archive again."
        )
        XCTAssertTrue(EditWords.note(added, in: Self.utc).hasPrefix("Removing it takes the record"))
    }

    /// A change pushed a record out, so taking it back puts that record where
    /// it was — which is a different thing, and must not be called removing.
    func testTakingBackAChangePutsTheOldRecordBackAndSaysSo() {
        let changed = made(displaced: [pushedOut()])
        XCTAssertTrue(EditWords.restores(changed))
        XCTAssertEqual(EditWords.undoWord(changed), "Put back")
        XCTAssertEqual(EditWords.undoAction(changed), "Put back what was there")
        XCTAssertEqual(EditWords.undoQuestion(changed), "Put the record back?")
        XCTAssertEqual(
            EditWords.consequence(changed),
            "Health goes back to the energy record that was there before, and 8 Sep 2025 goes to "
                + "the archive again."
        )
        XCTAssertTrue(EditWords.note(changed, in: Self.utc).hasPrefix("Putting it back writes"))
    }

    /// A removal that kept what it took out can be put back; one an older build
    /// wrote down cannot, and the page says so instead of offering a key.
    func testARemovalCanBePutBackOnlyIfSomethingWasKept() {
        let kept = made(state: .deleted, displaced: [pushedOut()])
        XCTAssertTrue(kept.canBeUndone)
        XCTAssertTrue(EditWords.note(kept, in: Self.utc).hasPrefix("Putting it back writes the record"))

        let nothingKept = made(state: .deleted)
        XCTAssertFalse(nothingKept.canBeUndone)
        XCTAssertTrue(
            EditWords.note(nothingKept, in: Self.utc).hasPrefix("This was removed by a version")
        )
    }

    // MARK: - Figures

    func testAWholeValueLosesItsDecimalPointAndALargeOneIsGrouped() {
        XCTAssertEqual(EditWords.figure(520), "520")
        XCTAssertEqual(EditWords.figure(78.42), "78.4")
        XCTAssertEqual(EditWords.figure(2600), "2\u{2009}600")
    }
}
