import CryptoKit
import Foundation

/// What an agent asked the phone to write into Health, in the shape it travels.
///
/// The Swift half of `protocol/edits.ts`. An edit is a list of items: a `put`
/// adds a sample or replaces the one this app wrote earlier under the same id,
/// a `delete` removes that sample. The id is the agent's handle and becomes a
/// HealthKit sync identifier; the version HealthKit wants beside it lives on
/// the phone, so applying the same edit twice ends with one sample.
///
/// The format checks shape only. Whether a metric can be written is decided by
/// `HealthWriter`, which answers with a code rather than a thrown error, so an
/// edit carrying one unknown item still gets every other item applied.
public enum EditItem: Equatable, Sendable {
    public struct Put: Equatable, Sendable {
        public let id: String
        public let metric: String
        /// Whole seconds since 1970, both ends.
        public let start: Int64
        public let end: Int64
        public let value: Double?
        public let unit: String?
        public let stage: String?

        public init(
            id: String, metric: String, start: Int64, end: Int64,
            value: Double?, unit: String?, stage: String?
        ) {
            self.id = id
            self.metric = metric
            self.start = start
            self.end = end
            self.value = value
            self.unit = unit
            self.stage = stage
        }
    }

    case put(Put)
    case delete(id: String)

    public var id: String {
        switch self {
        case let .put(put): return put.id
        case let .delete(id): return id
        }
    }
}

public enum EditError: Error, Equatable {
    case malformed(String)
}

/// The raw-deflate-compressed `{"v":1,"items":[…]}` an edit is made of.
public enum EditBatch {
    public static let formatVersion = 1
    public static let maxItems = 500
    /// What plaintext an edit may inflate to. 500 items are well under 100 KB.
    public static let maxPlaintextBytes = 1024 * 1024

    private static let putKeys: Set<String> = ["op", "id", "metric", "start", "end", "value", "unit", "stage"]
    private static let deleteKeys: Set<String> = ["op", "id"]
    private static let idAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))

    public static func unpack(_ bytes: Data) throws -> [EditItem] {
        let plaintext: Data
        do {
            plaintext = try Deflate.decompress(bytes, limit: maxPlaintextBytes)
        } catch {
            throw EditError.malformed("not deflate: \(error)")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: plaintext, options: [.fragmentsAllowed])
        } catch {
            throw EditError.malformed("not JSON")
        }
        guard let record = parsed as? [String: Any] else { throw EditError.malformed("an edit must be one object") }
        for key in record.keys where key != "v" && key != "items" {
            throw EditError.malformed("\(key) is not a field of an edit")
        }
        guard let version = record["v"] as? Int, version == formatVersion else {
            throw EditError.malformed("edit format version is not one this reader speaks")
        }
        guard let items = record["items"] as? [Any] else { throw EditError.malformed("items must be a list") }
        guard !items.isEmpty else { throw EditError.malformed("an edit with no items in it") }
        guard items.count <= maxItems else {
            throw EditError.malformed("an edit may carry \(maxItems) items, not \(items.count)")
        }
        return try items.enumerated().map { index, item in
            do {
                return try parse(item)
            } catch let EditError.malformed(why) {
                throw EditError.malformed("item \(index): \(why)")
            }
        }
    }

    private static func parse(_ raw: Any) throws -> EditItem {
        guard let item = raw as? [String: Any] else { throw EditError.malformed("an item must be an object") }
        guard let op = item["op"] as? String, op == "put" || op == "delete" else {
            throw EditError.malformed("op must be put or delete")
        }
        guard let id = item["id"] as? String, (1 ... 120).contains(id.count),
              id.unicodeScalars.allSatisfy({ idAllowed.contains($0) && $0.isASCII })
        else {
            throw EditError.malformed("id must be 1 to 120 characters of letters, digits, . _ : -")
        }
        let allowed = op == "put" ? putKeys : deleteKeys
        for key in item.keys where !allowed.contains(key) {
            throw EditError.malformed("\(key) is not a field of a \(op) item")
        }
        if op == "delete" {
            return .delete(id: id)
        }
        guard let metric = item["metric"] as? String, !metric.isEmpty else {
            throw EditError.malformed("metric must be a name")
        }
        guard let start = instant(item["start"]), let end = instant(item["end"]) else {
            throw EditError.malformed("start and end must be whole seconds since 1970")
        }
        guard end >= start else { throw EditError.malformed("end must not be before start") }
        var value: Double?
        if let raw = item["value"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw EditError.malformed("value must be a number")
            }
            value = number.doubleValue
        }
        if let unit = item["unit"], !(unit is String) {
            throw EditError.malformed("unit must be a string")
        }
        if let stage = item["stage"], !(stage is String) {
            throw EditError.malformed("stage must be a string")
        }
        return .put(EditItem.Put(
            id: id,
            metric: metric,
            start: start,
            end: end,
            value: value,
            unit: item["unit"] as? String,
            stage: item["stage"] as? String
        ))
    }

    /// A whole, non-negative second. JSON `1.5` arrives as a fractional
    /// `NSNumber` and is refused; `1` arrives as an integral one and is taken.
    private static func instant(_ raw: Any?) -> Int64? {
        // `NSNumber(1) is Bool` is true in Swift, so the bridge cannot tell a
        // one from a `true`; the Core Foundation type can.
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double <= 9_007_199_254_740_991, double.rounded() == double else { return nil }
        return Int64(double)
    }
}

/// The words the phone may answer with. The same set as `OUTCOME_CODES`.
public enum OutcomeCode: String, Codable, Sendable {
    case unknownMetric
    case badUnit
    case badRange
    case unauthorized
    case notFound
    case healthRefused
    case badSignature
    case cannotOpen
    case malformed
}

/// What the phone tells the service about one edit: how many items landed and
/// which did not, by index and word. Never a metric, never a value.
public struct Outcome: Equatable, Sendable, Encodable {
    public struct Refusal: Equatable, Sendable, Encodable {
        public let item: Int
        public let code: OutcomeCode

        public init(item: Int, code: OutcomeCode) {
            self.item = item
            self.code = code
        }
    }

    public let applied: Int
    public let refused: [Refusal]

    public init(applied: Int, refused: [Refusal]) {
        self.applied = applied
        self.refused = refused
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// `1757228400000-abcdefgh`: thirteen digits of milliseconds and eight
/// characters of base32, given by the service. Checked before it is put into a
/// path, so a listing that came back wrong cannot send the phone somewhere else.
public enum EditName {
    public static func isValid(_ name: String) -> Bool {
        guard name.count == 22 else { return false }
        let scalars = Array(name.unicodeScalars)
        for scalar in scalars[0 ..< 13] where !("0" ... "9").contains(scalar) {
            return false
        }
        guard scalars[13] == "-" else { return false }
        for scalar in scalars[14...] where !(("a" ... "z").contains(scalar) || ("2" ... "7").contains(scalar)) {
            return false
        }
        return true
    }
}

/// The editor's Ed25519 signature, checked by the phone itself before an edit
/// is opened. The service checks the same thing to keep strangers out of the
/// queue; the phone checks it because a service that decided on its own what
/// goes into Health would be able to write into Health.
public enum EditorSignature {
    /// The seven points of small order libsodium refuses, with the sign bit
    /// cleared — the same list `protocol/signing.ts` carries.
    private static let smallOrder: Set<Data> = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224edddd09f157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ].map { hex in Data(stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start ... hex.index(after: start)], radix: 16)!
    }) }.reduce(into: Set<Data>()) { $0.insert($1) }

    public static func hasSmallOrder(_ publicKey: Data) -> Bool {
        guard publicKey.count == 32 else { return false }
        var canonical = publicKey
        canonical[canonical.index(canonical.startIndex, offsetBy: 31)] &= 0x7F
        return smallOrder.contains(canonical)
    }

    public static func verify(publicKey: Data, signature: Data, message: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64, !hasSmallOrder(publicKey) else { return false }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
