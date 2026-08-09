import Compression
import Foundation

/// Squeezing a batch before it is sealed.
///
/// The order matters and is not negotiable: ciphertext does not compress, so
/// this has to happen first. NDJSON of health readings shrinks by roughly ten
/// times, which on a phone is battery as much as it is bandwidth.
///
/// `COMPRESSION_ZLIB` here is raw deflate — despite the name, Apple's framework
/// emits no zlib header. That is exactly what the web platform reads back as
/// `deflate-raw`, which is why the reader needs no special case.
public enum Deflate {
    public enum DeflateError: Error, Equatable {
        case didNotCompress(bytes: Int)
    }

    public static func compress(_ input: Data) throws -> Data {
        if input.isEmpty { return Data() }

        // Deflate can expand incompressible input very slightly, so the
        // destination is deliberately larger than the source.
        var destination = Data(count: input.count + 1024)
        let written = destination.withUnsafeMutableBytes { destinationBytes in
            input.withUnsafeBytes { sourceBytes in
                compression_encode_buffer(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    input.count + 1024,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        // Zero means the encoder gave up rather than that the result is empty.
        // Sending the batch uncompressed would be a silent protocol change, so
        // this fails instead.
        guard written > 0 else { throw DeflateError.didNotCompress(bytes: input.count) }

        destination.removeSubrange(written...)
        return destination
    }
}
