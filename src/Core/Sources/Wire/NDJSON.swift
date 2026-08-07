import Foundation

/// Assembles the NDJSON body the device POSTs: one self-contained JSON object
/// per line, newline-terminated.
///
/// Each line carries its own `id`, `seq`, `v` and `type` at the top level and
/// then the payload's own fields, flattened alongside them. Flat rather than
/// nested because the receiver's first act is to read those four keys, and a
/// wrapper object would make every consumer reach one level deeper for nothing.
///
/// The envelope is spliced in as bytes rather than re-encoded: the payload was
/// already canonical JSON when it entered the outbox, and decoding it back into
/// a dictionary only to re-encode it would risk changing it on the way through.
public enum NDJSON {
    public static func line(id: String, seq: Int64, kind: Event.Kind, payload: Data) throws -> Data {
        guard payload.first == UInt8(ascii: "{"), payload.last == UInt8(ascii: "}") else {
            throw EventError.payloadIsNotAnObject(id: id)
        }

        var line = Data([UInt8(ascii: "{")])
        line.append(jsonString: "id")
        line.append(UInt8(ascii: ":"))
        line.append(jsonString: id)
        line.append(contentsOf: ",\"seq\":\(seq),\"v\":\(eventSchemaVersion),\"type\":".utf8)
        line.append(jsonString: kind.rawValue)

        // `{}` means the payload adds nothing; splicing it would leave a
        // trailing comma and produce a line no parser accepts.
        if payload.count > 2 {
            line.append(UInt8(ascii: ","))
            line.append(payload.dropFirst())     // drops the payload's own `{`
        } else {
            line.append(UInt8(ascii: "}"))
        }

        line.append(UInt8(ascii: "\n"))
        return line
    }

    public static func body(_ events: [PendingEvent]) throws -> Data {
        var body = Data()
        for event in events {
            body.append(try line(id: event.id, seq: event.seq, kind: event.kind, payload: event.payload))
        }
        return body
    }
}

private extension Data {
    /// Append `value` as a complete JSON string literal, quotes included.
    ///
    /// Written out by hand rather than handed to `JSONEncoder`: encoding a bare
    /// `String` is a top-level fragment, which the standard encoder has refused
    /// in some Foundation versions. Escaping is a dozen lines and always works.
    mutating func append(jsonString value: String) {
        append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": append(contentsOf: "\\\"".utf8)
            case "\\": append(contentsOf: "\\\\".utf8)
            case "\n": append(contentsOf: "\\n".utf8)
            case "\r": append(contentsOf: "\\r".utf8)
            case "\t": append(contentsOf: "\\t".utf8)
            case "\u{08}": append(contentsOf: "\\b".utf8)
            case "\u{0C}": append(contentsOf: "\\f".utf8)
            case let other where other.value < 0x20:
                append(contentsOf: String(format: "\\u%04x", other.value).utf8)
            case let other:
                append(contentsOf: String(other).utf8)
            }
        }
        append(UInt8(ascii: "\""))
    }
}
