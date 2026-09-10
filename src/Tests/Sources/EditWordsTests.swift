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
        undoneAt: Double? = nil
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
            undoneAt: undoneAt.map { Date(timeIntervalSince1970: $0) }
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
        for code in [
            OutcomeCode.unknownMetric, .badUnit, .badRange, .unauthorized, .notFound,
            .healthRefused, .badSignature, .cannotOpen, .malformed,
        ] {
            let said = EditWords.reason(code)
            XCTAssertFalse(said.isEmpty, "\(code) has nothing to say")
            XCTAssertNotEqual(said, code.rawValue, "\(code) shows the wire word")
            XCTAssertTrue(said.contains(" "), "\(code) is a word rather than a sentence")
        }
    }

    func testTheAlertSaysBothThingsRemovingItDoes() {
        XCTAssertEqual(
            EditWords.consequence(made()),
            "The energy record leaves Health, and 8 Sep 2025 goes to the archive again."
        )
    }

    // MARK: - Figures

    func testAWholeValueLosesItsDecimalPointAndALargeOneIsGrouped() {
        XCTAssertEqual(EditWords.figure(520), "520")
        XCTAssertEqual(EditWords.figure(78.42), "78.4")
        XCTAssertEqual(EditWords.figure(2600), "2\u{2009}600")
    }
}
