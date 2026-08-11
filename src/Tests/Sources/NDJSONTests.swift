@testable import Efferent
import XCTest

final class NDJSONTests: XCTestCase {
    private func decode(_ line: Data) throws -> [String: Any] {
        XCTAssertEqual(line.last, UInt8(ascii: "\n"), "every line must be newline-terminated")
        let object = try JSONSerialization.jsonObject(with: line.dropLast())
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTheEnvelopeSitsAlongsideThePayloadFields() throws {
        let payload = try Event.payload(["metric": "steps", "value": "842"])
        let line = try NDJSON.line(id: "agg:steps:2026-08-07T09:00Z:h", payload: payload)

        let object = try decode(line)
        XCTAssertEqual(object["id"] as? String, "agg:steps:2026-08-07T09:00Z:h")
        XCTAssertEqual(object["v"] as? Int, eventSchemaVersion)
        XCTAssertEqual(object["metric"] as? String, "steps")
        XCTAssertEqual(object["value"] as? String, "842")
    }

    /// An event with nothing but its identity leaves `{}` behind, and the splice
    /// must not leave a trailing comma with it.
    func testAnEmptyPayloadStillProducesValidJSON() throws {
        let line = try NDJSON.line(id: "hk:sleep:9A2C", payload: Data("{}".utf8))

        let object = try decode(line)
        XCTAssertEqual(object.count, 2)
        XCTAssertEqual(object["id"] as? String, "hk:sleep:9A2C")
    }

    func testQuotesAndNewlinesInAnIdAreEscaped() throws {
        let line = try NDJSON.line(id: "odd\"id\nhere", payload: Data("{}".utf8))

        let object = try decode(line)
        XCTAssertEqual(object["id"] as? String, "odd\"id\nhere")
    }

    func testPayloadThatIsNotAnObjectIsRefused() {
        XCTAssertThrowsError(try NDJSON.line(id: "a", payload: Data("[1,2]".utf8)))
    }

    func testBodyIsOneLinePerEvent() throws {
        let body = try NDJSON.body([
            Event(id: "a", payload: Event.payload(["v": "1"])),
            Event(id: "b", payload: Event.payload(["v": "2"])),
        ])

        XCTAssertEqual(body.split(separator: UInt8(ascii: "\n")).count, 2)
    }

    /// Whether a day has changed is decided by comparing the bytes of its body
    /// against the bytes last sent. HealthKit makes no promise about the order
    /// it hands samples back in, so without sorting an unchanged day would look
    /// different every time and re-upload itself forever.
    func testTheBodyIsTheSameWhicheverOrderTheEventsArriveIn() throws {
        let first = try Event(id: "a", payload: Event.payload(["v": "1"]))
        let second = try Event(id: "b", payload: Event.payload(["v": "2"]))

        XCTAssertEqual(try NDJSON.body([first, second]), try NDJSON.body([second, first]))
    }

    /// Change detection compares payload bytes, so the encoder has to be stable:
    /// the same values must always produce the same bytes.
    func testPayloadEncodingIsStableAcrossCalls() throws {
        let first = try Event.payload(["b": "2", "a": "1"])
        let second = try Event.payload(["a": "1", "b": "2"])

        XCTAssertEqual(first, second)
    }
}
