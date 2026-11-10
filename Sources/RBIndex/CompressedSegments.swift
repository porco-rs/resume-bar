import CZstd
import Foundation

/// Stream compressed transcripts while retaining only the head and tail needed by the index.
func compressedSegments(at url: URL) throws -> (Data, Data) {
    guard let stream = ZSTD_createDStream() else { throw Zstd.Failure.decoder("create") }
    defer { ZSTD_freeDStream(stream) }
    ZSTD_initDStream(stream)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var head = Data(), tail = Data()
    var total = 0, remaining = 1
    var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
    while let data = try handle.read(upToCount: ZSTD_DStreamInSize()), !data.isEmpty {
        try data.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var produced = 0
            repeat {
                produced = try buffer.withUnsafeMutableBytes { destination -> Int in
                    var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    remaining = ZSTD_decompressStream(stream, &output, &input)
                    if ZSTD_isError(remaining) != 0 { throw Zstd.Failure.decoder(String(cString: ZSTD_getErrorName(remaining))) }
                    return output.pos
                }
                let chunk = Data(buffer.prefix(produced))
                if head.count < 128 * 1024 { head.append(chunk.prefix(128 * 1024 - head.count)) }
                tail.append(chunk)
                if tail.count > 64 * 1024 { tail = Data(tail.suffix(64 * 1024)) }
                total += produced
            } while input.pos < input.size || (produced == buffer.count && remaining != 0)
        }
    }
    guard remaining == 0 else { throw Zstd.Failure.decoder("truncated") }
    if total > tail.count, let newline = tail.firstIndex(of: 10) { tail = Data(tail[tail.index(after: newline)...]) }
    return (head, tail)
}
