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
        state: EditEntry.State = .written,
        askedBy: EditEntry.Asker = .agent,
        recordID: String = "agent:meal:1",
        metric: String? = "dietaryEnergy",
        start: Double? = 1_757_336_400,
        end: Double? = 1_757_337_300,
        value: Double? = 520,
        unit: String? = "kcal",
        stage: String? = nil,
        day: String? = "2025-09-08",
        code: OutcomeCode? = nil,
        personActedAt: Double? = nil,
        displaced: [DisplacedRecord] = []
    ) -> EditEntry {
        EditEntry(
            id: 1,
            editName: "1757336400000-abcdefgh",
            item: 0,
            recordID: recordID,
            state: state,
            askedBy: askedBy,
            metric: metric,
            start: start.map { Date(timeIntervalSince1970: $0) },
            end: end.map { Date(timeIntervalSince1970: $0) },
            value: value,
            unit: unit,
            stage: stage,
            day: day,
            code: code,
            at: Date(timeIntervalSince1970: 1_757_337_360),
            personActedAt: personActedAt.map { Date(timeIntervalSince1970: $0) },
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
            EditWords.title(made(state: .removed, metric: nil, start: nil, end: nil, value: nil, unit: nil)),
            "A record your agent removed"
        )
        XCTAssertEqual(
            EditWords.title(made(
                state: .failed, recordID: "", metric: nil, start: nil, end: nil, value: nil,
                unit: nil, day: nil, code: .badSignature
            )),
            "An edit this phone could not read"
        )
    }

    func testTheDetailSaysWhenItArrivedAndWhatItDid() {
        XCTAssertEqual(
            EditWords.detail(made(), in: Self.utc),
            "Agent wrote at 13:16 · for 8 Sep 2025, 13:00 – 13:15"
        )
        XCTAssertEqual(
            EditWords.detail(made(state: .failed, code: .unauthorized), in: Self.utc),
            "13:16 · writing this is switched off in Health"
        )
        // The person's own row says the operation and who performed it, in the
        // same two verbs the agent's rows use.
        XCTAssertEqual(
            EditWords.detail(
                made(state: .removed, askedBy: .person, personActedAt: 1_757_340_000),
                in: Self.utc
            ),
            "You removed it at 14:00"
        )
        XCTAssertEqual(
            EditWords.detail(
                made(state: .written, askedBy: .person, personActedAt: 1_757_340_000),
                in: Self.utc
            ),
            "You wrote it back at 14:00"
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
        tally.written = 1
        XCTAssertEqual(EditWords.summary(tally), "Your agent wrote 1 record in Health.")
        tally.removed = 2
        tally.failed = 1
        XCTAssertEqual(
            EditWords.summary(tally),
            "Your agent wrote 1 record, removed 2 records and could not write 1 record in Health."
        )
        XCTAssertEqual(EditWords.summary(EditTally()), "Your agent changed nothing.")
    }

    func testTheLegendCountsEveryStateAndSaysSoWhenThereAreNone() {
        var tally = EditTally()
        tally.written = 3
        tally.personRemoved = 1
        XCTAssertEqual(EditWords.counted(tally), "3 written, 1 removed by you")
        XCTAssertEqual(EditWords.counted(EditTally()), "no edits")
    }

    // MARK: - One edit, in full

    func testTheFieldsSayEverythingTheJournalHoldsAndNoWireName() {
        let fields = EditWords.fields(made(), in: Self.utc)
        let names = fields.map(\.name)
        // No "day" line: the record landed on the day it began on, and the
        // instants above have already said which day that is.
        XCTAssertEqual(names, ["metric", "value", "from", "to", "agent acted", "agent's id"])
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
            state: .removed, metric: nil, start: nil, end: nil, value: nil, unit: nil,
            day: "2025-09-08"
        )
        XCTAssertTrue(
            EditWords.fields(removed, in: Self.utc)
                .contains { $0.name == "day" && $0.value == "8 Sep 2025" }
        )
    }

    func testAFailedEditSaysWhyAndOffersNothingToTakeBack() {
        let failed = made(state: .failed, day: nil, code: .badUnit)
        XCTAssertTrue(
            EditWords.fields(failed, in: Self.utc)
                .contains { $0.name == "did not happen" && $0.value == "the unit does not fit the metric" }
        )
        XCTAssertTrue(EditWords.note(failed, in: Self.utc).hasPrefix("Nothing was written"))
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
        // Not the word "did not happen": nothing went wrong, and nothing written.
        XCTAssertTrue(
            EditWords.fields(waiting, in: Self.utc)
                .contains { $0.name == "your answer" && $0.value == "never given" }
        )
        XCTAssertFalse(EditWords.fields(waiting, in: Self.utc).contains { $0.name == "did not happen" })
        XCTAssertFalse(waiting.personCanAct, "its own page offers nothing to press")
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
        XCTAssertFalse(no.personCanAct)
    }

    func testARowThatWasNeverAnsweredIsCountedApartFromTheRest() {
        XCTAssertEqual(
            EditWords.counted(EditTally(written: 2, waiting: 1)), "1 never answered, 2 written"
        )
    }

    // MARK: - Taking one back

    /// An addition pushed nothing out, so taking it back is a removal, and both
    /// the key and the alert say so.
    func testTakingBackAnAdditionIsARemovalAndSaysSo() {
        let added = made()
        XCTAssertFalse(EditWords.restores(added))
        XCTAssertEqual(EditWords.actionWord(added), "Remove")
        XCTAssertEqual(EditWords.actionKey(added), "Remove the record")
        XCTAssertEqual(EditWords.actionQuestion(added), "Remove this record?")
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
        XCTAssertEqual(EditWords.actionWord(changed), "Write back")
        XCTAssertEqual(EditWords.actionKey(changed), "Write the record back")
        XCTAssertEqual(EditWords.actionQuestion(changed), "Write the record back?")
        XCTAssertEqual(
            EditWords.consequence(changed),
            "Health goes back to the energy record that was there before, and 8 Sep 2025 goes to "
                + "the archive again."
        )
        XCTAssertTrue(
            EditWords.note(changed, in: Self.utc).hasPrefix("Writing the old record back")
        )
    }

    /// A removal that kept what it took out can be put back; one an older build
    /// wrote down cannot, and the page says so instead of offering a key.
    func testARemovalCanBePutBackOnlyIfSomethingWasKept() {
        let kept = made(state: .removed, displaced: [pushedOut()])
        XCTAssertTrue(kept.personCanAct)
        XCTAssertTrue(EditWords.note(kept, in: Self.utc).hasPrefix("Writing it back puts the record"))

        let nothingKept = made(state: .removed)
        XCTAssertFalse(nothingKept.personCanAct)
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

    // MARK: - What has not landed yet

    func testWhatIsOnTheWaySaysWhatHappensNextRatherThanWhatWentWrong() {
        XCTAssertEqual(
            EditWords.onTheWay(1),
            "Your agent sent 1 record. They land in Health the next time you unlock this phone."
        )
        XCTAssertTrue(EditWords.onTheWay(4).hasPrefix("Your agent sent 4 records."))
    }

    func testHowLongAgoIsSaidInTheCoarsestWordsThatAreStillTrue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            EditWords.ago(now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(ago(5), "just now")
        XCTAssertEqual(ago(89), "just now", "a minute and a half is still just now")
        XCTAssertEqual(ago(90), "1 min ago")
        XCTAssertEqual(ago(59 * 60), "59 min ago")
        XCTAssertEqual(ago(60 * 60), "1 hour ago")
        XCTAssertEqual(ago(5 * 60 * 60), "5 hours ago")
        XCTAssertEqual(ago(24 * 60 * 60), "yesterday")
        XCTAssertEqual(ago(9 * 24 * 60 * 60), "9 days ago", "the line that shows a phone gone quiet")
    }

    /// The one line under the dial about the queue (NOTICE-7, STATE-1).
    ///
    /// The order matters as much as the words: each reason sits above the ones
    /// it explains, so a person is never told "not checked yet" about a queue
    /// nothing was allowed to read.
    func testDeliveryLineNamesWhatStoppedTheLook() {
        let now = Date(timeIntervalSince1970: 1_757_336_400)
        func line(
            paused: Bool = false,
            undecided: Bool = false,
            stopped: EditWords.DeliveryStop? = nil,
            reach: EditWords.Reach = .whole,
            checked: Date? = nil
        ) -> EditWords.DeliveryLine {
            EditWords.delivery(
                paused: paused, healthUndecided: undecided,
                stopped: stopped, reach: reach, checked: checked, now: now
            )
        }

        XCTAssertEqual(
            line(checked: now.addingTimeInterval(-300)),
            .init(text: "agent edits checked 5 min ago", isFault: false)
        )
        XCTAssertEqual(
            line(),
            .init(text: "agent edits not checked yet", isFault: false),
            "an agent that has sent nothing yet is not a fault"
        )

        XCTAssertEqual(
            line(stopped: .sealedByLock(waiting: 1)),
            .init(text: "1 edit waits until this phone is unlocked", isFault: false)
        )
        XCTAssertEqual(
            line(stopped: .sealedByLock(waiting: 3)),
            .init(text: "3 edits wait until this phone is unlocked", isFault: false)
        )
        XCTAssertEqual(
            line(stopped: .sealedByLock(waiting: 0)),
            .init(text: "health is sealed until this phone is unlocked", isFault: false),
            "a run that failed before counting says the condition, never a figure"
        )
        XCTAssertEqual(
            line(stopped: .failed),
            .init(text: "the last look at the archive did not finish", isFault: true)
        )

        XCTAssertEqual(
            line(undecided: true, stopped: .failed, checked: now),
            .init(text: "health access not answered yet", isFault: true),
            "the unanswered question is why there was nothing to fail at"
        )
        XCTAssertEqual(
            line(paused: true, undecided: true, stopped: .failed, checked: now),
            .init(text: "agent edits held back with sending", isFault: false),
            "a pause is the person's own doing and outranks everything under it"
        )

        XCTAssertEqual(
            line(stopped: .sealedByLock(waiting: 2), checked: now.addingTimeInterval(-300)).text,
            "2 edits wait until this phone is unlocked",
            "what stopped the look beats when it happened"
        )
    }

    /// STATE-2 again, for the two conditions that live outside this app: a wake
    /// nothing can deliver, and a system that runs nothing in the background.
    /// Neither stops an edit arriving, so neither is raised as a fault — but
    /// both are why the time under the dial is about to stop moving, and
    /// without them the person has a still clock and no cause.
    func testDeliveryLineNamesWhatTheSystemTookAway() {
        let now = Date(timeIntervalSince1970: 1_757_336_400)
        func line(
            paused: Bool = false,
            undecided: Bool = false,
            stopped: EditWords.DeliveryStop? = nil,
            reach: EditWords.Reach = .whole,
            checked: Date? = nil
        ) -> EditWords.DeliveryLine {
            EditWords.delivery(
                paused: paused, healthUndecided: undecided,
                stopped: stopped, reach: reach, checked: checked, now: now
            )
        }

        XCTAssertEqual(
            line(reach: .noWake, checked: now),
            .init(text: "nothing can wake this phone, so edits are late", isFault: false),
            "a refused wake is slower, not broken, and the catch-up task still runs"
        )
        XCTAssertEqual(
            line(reach: .nothingInTheBackground, checked: now),
            .init(text: "background app refresh is off, so edits are late", isFault: false),
            "it names the setting, because the screen is where the person meets it"
        )
        XCTAssertEqual(
            line(reach: .nothingInTheBackground, checked: nil).text,
            "background app refresh is off, so edits are late",
            "the cause beats a bare \"not checked yet\", which reads as the agent's fault"
        )

        XCTAssertEqual(
            line(stopped: .failed, reach: .nothingInTheBackground).text,
            "the last look at the archive did not finish",
            "what just happened beats what has been true all along"
        )
        XCTAssertEqual(
            line(paused: true, reach: .nothingInTheBackground).text,
            "agent edits held back with sending",
            "a pause is why nothing is being delivered at all"
        )
        XCTAssertEqual(
            line(undecided: true, reach: .noWake).text,
            "health access not answered yet",
            "an unanswered question stops every layer, not just the fast one"
        )

        XCTAssertEqual(
            line(reach: .whole, checked: now.addingTimeInterval(-300)).text,
            "agent edits checked 5 min ago",
            "with both layers in place the line goes back to saying when"
        )
    }
}
