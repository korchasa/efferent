@testable import Efferent
import HealthKit
import XCTest

final class HealthTests: XCTestCase {
    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return calendar
    }

    /// A day no longer carries an identity per event — a reader rebuilds one
    /// from the metric and the instant. What is left on the wire is the kind,
    /// and it is the whole of the difference between a total and a record.
    func testAKindIsWhatSeparatesATotalFromARecord() {
        XCTAssertEqual(Event.Kind.total.rawValue, "agg")
        XCTAssertEqual(Event.Kind.record.rawValue, "hk")
    }

    // MARK: - What a wake-up asks for

    /// One observer covers every type, so a wake-up now has to work out what
    /// moved instead of being told by which observer fired.
    func testOnlyTheMetricsThatMovedAreRead() {
        let steps = try? XCTUnwrap(AggregateMetric.all.first { $0.name == "steps" })
        let sleep = try? XCTUnwrap(SampleMetric.all.first { $0.name == "sleep" })
        guard let steps, let sleep else { return XCTFail("the catalogue lost a metric") }

        let plan = HealthCoordinator.plan(for: [steps.type, sleep.type])

        XCTAssertTrue(plan.totals, "a total moved, so the recent past needs marking")
        XCTAssertEqual(plan.metrics.map(\.name), ["sleep"])
        XCTAssertEqual(plan.names, ["steps", "sleep"])
        XCTAssertFalse(plan.unnamed)
    }

    /// Totals share one piece of work. Seven of them moving is still one week
    /// to mark, not seven.
    func testEveryTotalThatMovedAsksForTheSameOneThing() {
        let plan = HealthCoordinator.plan(for: Set(AggregateMetric.all.map(\.type)))

        XCTAssertTrue(plan.totals)
        XCTAssertTrue(plan.metrics.isEmpty, "a total has no anchor to read")
        XCTAssertEqual(plan.names.count, AggregateMetric.all.count)
    }

    /// An unknown change is not the same as no change: Health said something
    /// moved, so everything is read.
    func testAWakeUpThatNamesNothingReadsEverything() {
        let plan = HealthCoordinator.plan(for: nil)

        XCTAssertTrue(plan.totals)
        XCTAssertEqual(plan.metrics.map(\.name), SampleMetric.all.map(\.name))
        XCTAssertTrue(plan.unnamed)
    }

    func testDayBucketsAlignToTheStartOfTheLocalDay() throws {
        let calendar = try utcCalendar()
        let afternoon = Date(timeIntervalSince1970: 1_754_580_000) // 15:20 UTC

        let anchor = Bucket.day.anchor(before: afternoon, calendar: calendar)

        XCTAssertEqual(anchor, Date(timeIntervalSince1970: 1_754_524_800))
    }

    func testEveryMetricHasADistinctWireName() {
        let names = AggregateMetric.all.map(\.name) + SampleMetric.all.map(\.name)

        XCTAssertEqual(names.count, Set(names).count, "wire names must be unique: \(names)")
    }

    /// Aggregates exist precisely because raw cumulative samples cannot be
    /// summed. A metric appearing in both catalogues would mean both a total and
    /// the samples behind it go out, which is the double count in another shape.
    func testNoMetricIsCollectedBothWays() {
        let aggregated = Set(AggregateMetric.all.map(\.type.identifier))
        let sampled = Set(SampleMetric.all.map(\.type.identifier))

        XCTAssertTrue(aggregated.isDisjoint(with: sampled))
    }

    /// A total is the one thing that names its bucket, and that is what tells a
    /// reader it is looking at a total rather than a record.
    func testATotalCarriesItsBucketAndUnit() throws {
        let event = try Event(
            kind: .total,
            metric: "steps",
            bucket: "hour",
            start: Date(timeIntervalSince1970: 1_754_557_200),
            end: Date(timeIntervalSince1970: 1_754_560_800),
            unit: "count",
            value: 842
        )

        let series = try XCTUnwrap(day(Columnar.body([event])).first)
        XCTAssertEqual(series["k"] as? String, "agg")
        XCTAssertEqual(series["metric"] as? String, "steps")
        XCTAssertEqual(series["bucket"] as? String, "hour")
        XCTAssertEqual(series["unit"] as? String, "count")
        XCTAssertEqual(series["t0"] as? Int, 1_754_557_200)
        XCTAssertEqual(series["value"] as? [Double], [842])
    }

    private func day(_ body: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["series"] as? [[String: Any]])
    }

    func testTheAppAsksToReadEveryMetricItCollects() {
        let requested = HealthReader.readTypes

        for metric in AggregateMetric.all {
            XCTAssertTrue(requested.contains(metric.type), "missing \(metric.name)")
        }
        for metric in SampleMetric.all {
            XCTAssertTrue(requested.contains(metric.type), "missing \(metric.name)")
        }
    }
}
