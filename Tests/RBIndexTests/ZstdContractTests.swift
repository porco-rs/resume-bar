// Contract test for the vendored zstd decoder.
import Foundation
import Testing
@testable import RBIndex

let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Samples")

@Test func zstdRoundTripMatchesPlainSample() throws {
    let plain = try Data(contentsOf: samples.appendingPathComponent("codex-cli.jsonl"))
    let decoded = try Zstd.decompressFile(at: samples.appendingPathComponent("codex-cli.jsonl.zst"))
    #expect(decoded == plain)
}

@Test func zstdHeadReadStopsAtLimit() throws {
    let head = try Zstd.decompressFile(at: samples.appendingPathComponent("codex-cli.jsonl.zst"), limit: 64)
    #expect(head.count == 64)
    #expect(String(decoding: head, as: UTF8.self).hasPrefix("{\"timestamp\""))
}

@Test func zstdRejectsGarbage() {
    #expect(throws: Zstd.Failure.self) { try Zstd.decompress(Data("not zstd".utf8)) }
}
