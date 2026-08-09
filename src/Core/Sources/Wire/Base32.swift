import Foundation

/// RFC 4648 base32 in lowercase, without padding.
///
/// Bucket names end up in URLs and in object keys, so the alphabet has to avoid
/// anything that needs escaping and anything that changes under a case-insensitive
/// filesystem. Base64 fails both tests; base32 passes.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func encode(_ bytes: Data) -> String {
        var bits = 0
        var value = 0
        var out = ""
        out.reserveCapacity((bytes.count * 8 + 4) / 5)

        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(value << (5 - bits)) & 31])
        }
        return out
    }
}

/// base64url, the spelling used for keys and signatures on the wire.
public enum Base64URL {
    public static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) -> Data {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        return Data(base64Encoded: padded) ?? Data()
    }
}
