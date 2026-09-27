@testable import Efferent
import XCTest

/// How far back the range screens say Health goes: SETUP-1 and SETUP-2.
///
/// The screens cannot ask Apple whether reading was allowed — nothing can — so
/// the only thing that separates a phone with no history from a phone that has
/// not been asked yet is when the question was put. Worth testing on its own
/// because the answer is a promise printed under a button, and the walkthrough
/// printed the wrong one for three steps.
@MainActor
final class EarliestDayTests: XCTestCase {
    /// The walkthrough asks on its first screen, before the Health sheet has
    /// been shown, and gets nothing back. Every later look has to be a fresh
    /// question: the one that remembered the first answer told a phone holding
    /// 90 days of readings that Health had nothing to read.
    func testEveryLookIsAFreshQuestion() async {
        let earliest = EarliestDay()
        var answers: [String?] = [nil, "2026-06-23"]
        var asked = 0
        func ask() async -> String? {
            asked += 1
            return answers.removeFirst()
        }

        await earliest.look(ask)
        XCTAssertNil(earliest.day, "nobody has answered Health yet")
        XCTAssertTrue(earliest.looked, "the row may stop saying it is working it out")

        await earliest.look(ask)
        XCTAssertEqual(asked, 2, "appearing again has to ask Health again")
        XCTAssertEqual(earliest.day, "2026-06-23", "the later answer is the one that counts")
    }

    /// Before anybody has looked, the rows say they are working it out rather
    /// than that Health is empty. The two are the same nil and only this tells
    /// them apart.
    func testNothingIsClaimedAboutHealthUntilItHasBeenLookedAt() async {
        let earliest = EarliestDay()
        XCTAssertFalse(earliest.looked)

        await earliest.look { nil }
        XCTAssertTrue(earliest.looked)
        XCTAssertNil(earliest.day)
    }

    /// Why the sentence is load-bearing: "Everything Health has" is the day
    /// Health first recorded something, so with no answer it resolves to no day
    /// at all and the screen has nothing honest to promise.
    func testEverythingHealthHasIsOnlyADayOnceHealthHasAnswered() throws {
        let utc = Day.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))

        XCTAssertNil(RangePicker.startDay(for: .everything, earliest: nil, calendar: utc))
        XCTAssertEqual(
            RangePicker.startDay(for: .everything, earliest: "2026-06-23", calendar: utc),
            "2026-06-23"
        )
    }

    /// SETUP-3 for the presets, not only for a chosen day. A phone whose Health
    /// began 97 days ago was offered "Last 12 months · 366 days" and told that
    /// everything since a year ago would go up now — history that does not
    /// exist. Once the first day is known, a preset reaching past it stops there.
    func testAPresetNeverReachesPastHealthsFirstRecord() throws {
        let utc = Day.calendar(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        func daysAgo(_ n: Int) throws -> String {
            Day.of(try XCTUnwrap(utc.date(byAdding: .day, value: -n, to: Date())), in: utc)
        }
        let recent = try daysAgo(96)

        XCTAssertEqual(RangePicker.startDay(for: .lastYear, earliest: recent, calendar: utc), recent)
        XCTAssertEqual(
            RangePicker.startDay(for: .lastMonth, earliest: recent, calendar: utc),
            try daysAgo(29),
            "a preset inside Health's history is left alone"
        )

        let old = try daysAgo(1000)
        XCTAssertEqual(RangePicker.startDay(for: .lastYear, earliest: old, calendar: utc), try daysAgo(365))
        XCTAssertEqual(
            RangePicker.startDay(for: .lastYear, earliest: nil, calendar: utc),
            try daysAgo(365),
            "with no first day known there is nothing to stop at"
        )
    }
}
