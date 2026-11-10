// Streaming zstd decompression for Codex `rollout-*.jsonl.zst` files.
// Part of the contract; the index uses it and does not change it.

import CZstd
import Foundation

public enum Zstd {
    public enum Failure: Error, Equatable { case decoder(String) }

    /// Decompresses `data` and stops once `limit` output bytes exist (head reads of large files).
    public static func decompress(_ data: Data, limit: Int = .max) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw Failure.decoder("create") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)
        var out = Data()
        let chunk = ZSTD_DStreamOutSize()
        var buffer = [UInt8](repeating: 0, count: chunk)
        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
            while input.pos < input.size && out.count < limit {
                let produced: Int = try buffer.withUnsafeMutableBytes { dst in
                    var output = ZSTD_outBuffer(dst: dst.baseAddress, size: chunk, pos: 0)
                    let rc = ZSTD_decompressStream(stream, &output, &input)
                    if ZSTD_isError(rc) != 0 { throw Failure.decoder(String(cString: ZSTD_getErrorName(rc))) }
                    return output.pos
                }
                if produced == 0 && input.pos >= input.size { break }
                out.append(contentsOf: buffer[0..<produced])
            }
        }
        return out.count > limit ? out.prefix(limit) : out
    }

    /// Reads a .zst file and returns at most `limit` decompressed bytes.
    public static func decompressFile(at url: URL, limit: Int = .max) throws -> Data {
        try decompress(Data(contentsOf: url, options: .mappedIfSafe), limit: limit)
    }
}
