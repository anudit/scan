import Foundation
import Compression

/// Streams the start of a gzip file through Apple's raw DEFLATE decoder.
/// Only the first member is read, which is all a head sample needs.
final class GzipHead {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var header = Data()
    private var headerDone = false
    private(set) var ended = false
    init() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw EngineError("Could not start gzip decoding.") }
    }
    deinit { compression_stream_destroy(&stream) }
    func inflate(_ chunk: Data) throws -> Data {
        var input = chunk
        if !headerDone {
            header.append(input)
            guard let length = try Self.headerLength(header) else { return Data() }
            input = header.dropFirst(length); header = Data(); headerDone = true
        }
        guard !ended, !input.isEmpty else { return Data() }
        var output = Data()
        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity); defer { buffer.deallocate() }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!; stream.src_size = raw.count
            repeat {
                stream.dst_ptr = buffer; stream.dst_size = capacity
                let status = compression_stream_process(&stream, 0)
                output.append(buffer, count: capacity - stream.dst_size)
                if status == COMPRESSION_STATUS_END { ended = true; break }
                guard status == COMPRESSION_STATUS_OK else { throw EngineError("The gzip data is damaged.") }
            } while stream.src_size > 0 || stream.dst_size == 0
        }
        return output
    }
    /// The gzip member header length (RFC 1952), or nil if more bytes are needed.
    private static func headerLength(_ data: Data) throws -> Int? {
        let bytes = [UInt8](data.prefix(64 << 10))
        guard bytes.count >= 10 else { return nil }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw EngineError("Not a gzip file.") }
        let flags = bytes[3]; var index = 10
        if flags & 4 != 0 { guard bytes.count >= index + 2 else { return nil }; index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        for flag in [UInt8(8), 16] where flags & flag != 0 {
            guard let end = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        if flags & 2 != 0 { index += 2 }
        return bytes.count >= index ? index : nil
    }
}
