import XCTest

@testable import Efferent

final class NDJSONTests: XCTestCase {
    private func decode(_ line: Data) throws -> [String: Any] {
        XCTAssertEqual(line.last, UInt8(ascii: "\n"), "every line must be newline-terminated")
        let object = try JSONSerialization.jsonObject(with: line.dropLast())
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTheEnvelopeSitsAlongsideThePayloadFields() throws {
        let payload = try Event.payload(["metric": "steps", "value": "842"])
        let line = try NDJSON.line(id: "agg:steps:2026-08-07T09:00Z:h", seq: 41207, kind: .aggregate, payload: payload)

        let object = try decode(line)
        XCTAssertEqual(object["id"] as? String, "agg:steps:2026-08-07T09:00Z:h")
        XCTAssertEqual(object["seq"] as? Int, 41207)
        XCTAssertEqual(object["v"] as? Int, eventSchemaVersion)
        XCTAssertEqual(object["type"] as? String, "health.agg")
        XCTAssertEqual(object["metric"] as? String, "steps")
        XCTAssertEqual(object["value"] as? String, "842")
    }

    /// A deletion carries nothing but its id, so the payload is `{}` and the
    /// splice must not leave a trailing comma behind.
    func testAnEmptyPayloadStillProducesValidJSON() throws {
        let line = try NDJSON.line(id: "hk:sleep:9A2C", seq: 3, kind: .deletion, payload: Data("{}".utf8))

        let object = try decode(line)
        XCTAssertEqual(object.count, 4)
        XCTAssertEqual(object["type"] as? String, "health.delete")
    }

    func testQuotesAndNewlinesInAnIdAreEscaped() throws {
        let line = try NDJSON.line(id: "odd\"id\nhere", seq: 1, kind: .sample, payload: Data("{}".utf8))

        let object = try decode(line)
        XCTAssertEqual(object["id"] as? String, "odd\"id\nhere")
    }

    func testPayloadThatIsNotAnObjectIsRefused() {
        XCTAssertThrowsError(
            try NDJSON.line(id: "a", seq: 1, kind: .sample, payload: Data("[1,2]".utf8))
        )
    }

    func testBodyIsOneLinePerEvent() throws {
        let store = try Store.inMemory()
        try store.commit(events: [
            Event(id: "a", kind: .sample, payload: try Event.payload(["v": "1"])),
            Event(id: "b", kind: .sample, payload: try Event.payload(["v": "2"])),
        ])

        let body = try NDJSON.body(store.pending(limit: 10))

        let lines = body.split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(lines.count, 2)
    }

    /// Change detection in the outbox compares payload bytes, so the encoder has
    /// to be stable: the same values must always produce the same bytes.
    func testPayloadEncodingIsStableAcrossCalls() throws {
        let first = try Event.payload(["b": "2", "a": "1"])
        let second = try Event.payload(["a": "1", "b": "2"])

        XCTAssertEqual(first, second)
    }
}
