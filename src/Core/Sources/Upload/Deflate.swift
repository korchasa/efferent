import Compression
import Foundation

/// Squeezing a batch before it is sealed.
///
/// The order matters and is not negotiable: ciphertext does not compress, so
/// this has to happen first. A day of health readings shrinks by roughly six
/// times, which on a phone is battery as much as it is bandwidth.
///
/// `COMPRESSION_ZLIB` here is raw deflate — despite the name, Apple's framework
/// emits no zlib header. That is exactly what the web platform reads back as
/// `deflate-raw`, which is why the reader needs no special case.
public enum Deflate {
    public enum DeflateError: Error, Equatable {
        case didNotCompress(bytes: Int)
        case didNotInflate
        case tooLarge(limit: Int)
    }

    public static func compress(_ input: Data) throws -> Data {
        if input.isEmpty {
            return Data()
        }

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

    /// The other direction, for an edit the agent squeezed the same way.
    ///
    /// Streamed rather than buffered, because a caller cannot know how big a
    /// deflate stream inflates to before inflating it, and an edit is bytes
    /// somebody else made: `limit` is the size at which it stops being read
    /// and starts being refused.
    public static func decompress(_ input: Data, limit: Int) throws -> Data {
        guard !input.isEmpty else { throw DeflateError.didNotInflate }
        var output = Data()
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }

        var stream = compression_stream(
            dst_ptr: buffer, dst_size: chunk, src_ptr: buffer, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw DeflateError.didNotInflate }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = input.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                output.append(buffer, count: produced)
                guard output.count <= limit else { throw DeflateError.tooLarge(limit: limit) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // Nothing consumed and nothing produced is a stream that
                    // needs more input than it has: a truncated edit.
                    if produced == 0, stream.src_size == 0 {
                        throw DeflateError.didNotInflate
                    }
                default:
                    throw DeflateError.didNotInflate
                }
            }
        }
        return output
    }
}
