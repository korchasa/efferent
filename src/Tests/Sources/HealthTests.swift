@testable import Efferent
import HealthKit
import XCTest

final class HealthTests: XCTestCase {
    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return calendar
    }

    /// The id is what makes recomputing a bucket free, so its shape is a
    /// contract with the receiver, not an implementation detail.
    func testAggregateIdentityIsDerivedFromTheBucket() {
        let start = Date(timeIntervalSince1970: 1_754_557_200) // 2025-08-07T09:00:00Z

        XCTAssertEqual(
            HealthReader.aggregateID(metric: "steps", start: start, bucket: .hour),
            "agg:steps:2025-08-07T09:00:00Z:h"
        )
        XCTAssertEqual(
            HealthReader.aggregateID(metric: "steps", start: start, bucket: .day),
            "agg:steps:2025-08-07T09:00:00Z:d"
        )
    }

    /// A deletion reuses the id of the sample it removes: same id, different
    /// kind. That is what lets the receiver drop the record without a lookup.
    func testADeletionCarriesTheIdentityOfTheSampleItRemoves() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))

        XCTAssertEqual(
            HealthReader.sampleID(metric: "sleep", uuid: uuid),
            "hk:sleep:3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        )
    }

    func testDayBucketsAlignToTheStartOfTheLocalDay() throws {
        let calendar = try utcCalendar()
        let afternoon = Date(timeIntervalSince1970: 1_754_580_000) // 15:20 UTC

        let anchor = Bucket.day.anchor(before: afternoon, calendar: calendar)

        XCTAssertEqual(iso.string(from: anchor), "2025-08-07T00:00:00Z")
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

    func testAggregatePayloadCarriesTheBucketAndUnit() throws {
        let payload = try Event.payload(AggregatePayload(
            metric: "steps",
            bucket: "hour",
            start: Date(timeIntervalSince1970: 1_754_557_200),
            end: Date(timeIntervalSince1970: 1_754_560_800),
            value: 842,
            unit: "count"
        ))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(object["metric"] as? String, "steps")
        XCTAssertEqual(object["bucket"] as? String, "hour")
        XCTAssertEqual(object["value"] as? Double, 842)
        XCTAssertEqual(object["unit"] as? String, "count")
        XCTAssertEqual(object["start"] as? String, "2025-08-07T09:00:00Z")
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
