@testable import Efferent
import XCTest

/// Every case here is one the emulation of this format actually broke on, or one
/// the whole design rests on. Nothing is here for symmetry.
final class ColumnarTests: XCTestCase {
    private func day(_ events: [Event]) throws -> [String: Any] {
        let body = try Columnar.body(events)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func series(_ events: [Event]) throws -> [[String: Any]] {
        try XCTUnwrap(day(events)["series"] as? [[String: Any]])
    }

    private func beat(
        at second: TimeInterval, _ value: Double, source: String = "Watch"
    ) throws -> Event {
        try Event(
            kind: .record,
            metric: "heartRate",
            start: Date(timeIntervalSince1970: second),
            end: Date(timeIntervalSince1970: second),
            source: source,
            unit: "count/min",
            value: value
        )
    }

    func testADayStampsTheLayoutItIsWrittenIn() throws {
        XCTAssertEqual(try day([])["v"] as? Int, dayFormatVersion)
    }

    func testAnEmptyDayIsStillADay() throws {
        XCTAssertEqual(try series([]).count, 0)
    }

    /// The whole reason for the format: what a thousand readings have in common
    /// is written once, and the instants are counted from the first of them.
    func testRowsThatAgreeShareOneSeriesAndSayItOnce() throws {
        let rows = try series([
            beat(at: 1000, 60), beat(at: 1060, 61), beat(at: 1180, 62),
        ])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["metric"] as? String, "heartRate")
        XCTAssertEqual(rows[0]["source"] as? String, "Watch")
        XCTAssertEqual(rows[0]["t0"] as? Int, 1000)
        XCTAssertEqual(rows[0]["t"] as? [Int], [0, 60, 120])
        XCTAssertEqual(rows[0]["d"] as? [Int], [0, 0, 0])
        XCTAssertEqual(rows[0]["value"] as? [Double], [60, 61, 62])
    }

    func testTwoSourcesAreTwoSeries() throws {
        let rows = try series([
            beat(at: 1000, 60, source: "Watch"),
            beat(at: 1000, 71, source: "Mi Fit"),
        ])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["source"] as? String }, ["Mi Fit", "Watch"])
    }

    /// HealthKit does not promise to hand records back in the same order twice,
    /// and the body is what decides whether a day has changed. Sorting by id did
    /// this before; with no id left it is the content that has to.
    func testTheOrderTheyArriveInDoesNotChangeTheBytes() throws {
        var events: [Event] = []
        for index in 0 ..< 40 {
            try events.append(beat(at: 1000 + Double(index) * 37, Double(50 + index % 20)))
        }
        try events.append(Event(
            kind: .record, metric: "sleep",
            start: Date(timeIntervalSince1970: 900),
            end: Date(timeIntervalSince1970: 4500),
            source: "Watch", stage: "asleepCore"
        ))
        let expected = try Columnar.body(events)

        for _ in 0 ..< 20 {
            XCTAssertEqual(try Columnar.body(events.shuffled()), expected)
        }
    }

    /// Two stages of one night begin in the same second and differ only in where
    /// they end and what they are called. An order that stopped at the instant
    /// would put them in either sequence, and the day would hash differently on
    /// every read.
    func testTwoRecordsStartingInTheSameSecondStillHaveAnOrder() throws {
        let core = try Event(
            kind: .record, metric: "sleep",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 5000),
            source: "Watch", stage: "asleepCore"
        )
        let deep = try Event(
            kind: .record, metric: "sleep",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 3000),
            source: "Watch", stage: "asleepDeep"
        )

        XCTAssertEqual(try Columnar.body([core, deep]), try Columnar.body([deep, core]))
        let rows = try series([core, deep])
        XCTAssertEqual(rows[0]["d"] as? [Int], [2000, 4000])
        XCTAssertEqual(rows[0]["stage"] as? [String], ["asleepDeep", "asleepCore"])
    }

    /// A column nobody in the series filled in is not written at all. A workout
    /// has no reading; a total has no source.
    func testAColumnNoRowNeedsIsNotWritten() throws {
        let workout = try Event(
            kind: .record, metric: "workout",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 4600),
            source: "Watch", activity: "37", duration: 3600
        )
        let rows = try series([workout])

        XCTAssertNil(rows[0]["value"])
        XCTAssertNil(rows[0]["stage"])
        XCTAssertNil(rows[0]["unit"])
        XCTAssertEqual(rows[0]["activity"] as? [String], ["37"])
        XCTAssertEqual(rows[0]["duration"] as? [Double], [3600])
    }

    /// One row of a series has a reading and its neighbour does not. The column
    /// has to keep the gap in place or every value after it shifts one row up.
    func testAGapInAColumnIsKeptRatherThanClosed() throws {
        let withValue = try Event(
            kind: .record, metric: "respiratoryRate",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 1000),
            source: "Watch", value: 14
        )
        let without = try Event(
            kind: .record, metric: "respiratoryRate",
            start: Date(timeIntervalSince1970: 2000),
            end: Date(timeIntervalSince1970: 2000),
            source: "Watch"
        )
        let rows = try series([withValue, without])

        XCTAssertEqual(rows[0]["value"] as? [Double?], [14, nil])
    }

    /// Instants are whole seconds and always have been — the line format said so
    /// in ISO-8601 and truncated just as quietly. Here it is the shape of the
    /// field, so it is worth a test that says which way it goes.
    func testAnInstantIsCutDownToItsSecond() throws {
        let rows = try series([beat(at: 1000.75, 60)])

        XCTAssertEqual(rows[0]["t0"] as? Int, 1000)
    }

    func testADayWithNothingInItIsNotAnError() throws {
        XCTAssertEqual(try Columnar.body([]), Data(#"{"series":[],"v":2}"#.utf8))
    }
}
