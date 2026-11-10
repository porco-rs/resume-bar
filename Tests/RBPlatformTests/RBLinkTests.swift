import Darwin
import Foundation
import Testing
import RBPlatform

private struct LinkFixture {
    let home = URL(fileURLWithPath: "/private/tmp/resume-bar-test-B2-FIX-" + UUID().uuidString)
    var link: URL { home.appendingPathComponent(".local/bin/rb") }
    var record: URL { home.appendingPathComponent("record/target") }
    var target: URL { home.appendingPathComponent("a/ResumeBar.app/Contents/MacOS/rb") }
    var next: URL { home.appendingPathComponent("b/ResumeBar.app/Contents/MacOS/rb") }
    func setup() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func reconcile(_ enabled: Bool, target: URL? = nil, before: () -> Void = {}) throws -> RBLink.Report {
        try RBLink.reconcile(home: home, record: record, target: target ?? self.target, enabled: enabled, alternatives: [], beforeChange: before)
    }
    func bin() throws { try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true) }
    func destination() throws -> String { try FileManager.default.destinationOfSymbolicLink(atPath: link.path) }
}
@Test func rbLinkFollowsRecordedTarget() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
    #expect(try !f.reconcile(true).taken)
    #expect(try f.destination() == f.target.path)
    #expect(try String(contentsOf: f.record, encoding: .utf8) == f.target.path)
    #expect(try !f.reconcile(true, target: f.next).taken)
    #expect(try f.destination() == f.next.path)
    #expect(try !f.reconcile(false, target: f.next).taken)
    #expect(!FileManager.default.fileExists(atPath: f.record.path))
    #expect((try? f.destination()) == nil)
}
@Test func rbLinkForeignLinkWithOurNameIsTaken() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }; try f.bin()
    let foreign = "/elsewhere/ResumeBar.app/Contents/MacOS/rb"
    try FileManager.default.createSymbolicLink(atPath: f.link.path, withDestinationPath: foreign)
    for enabled in [true, false] { #expect(try f.reconcile(enabled).taken); #expect(try f.destination() == foreign) }
}
@Test func rbLinkParentSymlinkIsTaken() throws {
    for parent in [".local", ".local/bin"] {
        for enabled in [true, false] {
            let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
            let outside = f.home.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
            if parent.contains("/") { try FileManager.default.createDirectory(at: f.home.appendingPathComponent(".local"), withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent(parent), withDestinationURL: outside)
            #expect(try f.reconcile(enabled).taken)
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel"])
            #expect(try String(contentsOf: outside.appendingPathComponent("sentinel"), encoding: .utf8) == "keep")
        }
    }
}
@Test func rbLinkDirectoryAtPathIsTaken() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }; try f.bin()
    try FileManager.default.createDirectory(at: f.link, withIntermediateDirectories: false)
    for enabled in [true, false] { #expect(try f.reconcile(enabled).taken) }
}
private func race(_ operation: String) throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }; try f.bin()
    if operation != "create" { _ = try f.reconcile(true) }
    let result = try f.reconcile(operation != "remove", target: operation == "replace" ? f.next : f.target) {
        if operation != "create" { try! FileManager.default.removeItem(at: f.link) }
        if operation == "replace" {
            try! FileManager.default.createDirectory(at: f.link, withIntermediateDirectories: false)
            try! Data("foreign".utf8).write(to: f.link.appendingPathComponent("inside"))
        } else { try! Data("foreign".utf8).write(to: f.link) }
    }
    #expect(result.taken)
    let file = operation == "replace" ? f.link.appendingPathComponent("inside") : f.link
    #expect(try String(contentsOf: file, encoding: .utf8) == "foreign")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.link.deletingLastPathComponent().path) == ["rb"])
}
@Test func rbLinkRaceOnCreateKeepsForeignObject() throws { try race("create") }
@Test func rbLinkRaceOnReplaceKeepsForeignObject() throws { try race("replace") }
@Test func rbLinkRaceOnRemoveKeepsForeignObject() throws { try race("remove") }

@Test func rbLinkRecordsExistingTargetAndReportsAlternatives() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }; try f.bin()
    try FileManager.default.createSymbolicLink(atPath: f.link.path, withDestinationPath: f.target.path)
    let alternative = f.home.appendingPathComponent("other-rb")
    try Data().write(to: alternative)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: alternative.path)
    let report = try RBLink.reconcile(home: f.home, record: f.record, target: f.target, enabled: true, alternatives: [alternative])
    #expect(!report.taken && report.otherCommands == [alternative.path])
    #expect(try String(contentsOf: f.record, encoding: .utf8) == f.target.path)
}
@Test func rbLinkOffDoesNotCreateFoldersAndForeignFileIsUntouched() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
    #expect(try !f.reconcile(false).taken)
    #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".local").path))
    try f.bin(); try Data("foreign".utf8).write(to: f.link)
    for enabled in [true, false] {
        #expect(try f.reconcile(enabled).taken)
        #expect(try String(contentsOf: f.link, encoding: .utf8) == "foreign")
    }
}

@Test func rbLinkSwapBackNeverDeletesForeignObject() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
    _ = try f.reconcile(true)
    #expect(throws: (any Error).self) {
        try RBLink.reconcile(home: f.home, record: f.record, target: f.next, enabled: true, alternatives: [], beforeChange: {
            try! FileManager.default.removeItem(at: f.link)
            try! Data("F".utf8).write(to: f.link)
        }, afterSwap: {
            try! FileManager.default.removeItem(at: f.link)
            try! Data("G".utf8).write(to: f.link)
        })
    }
    #expect(try String(contentsOf: f.link, encoding: .utf8) == "F")
    let names = try FileManager.default.contentsOfDirectory(atPath: f.link.deletingLastPathComponent().path)
    let temporary = try #require(names.first { $0.hasPrefix(".rb.") })
    #expect(try String(contentsOf: f.link.deletingLastPathComponent().appendingPathComponent(temporary), encoding: .utf8) == "G")
}
@Test func rbLinkSwapBackRestoresWhenPathVanished() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
    _ = try f.reconcile(true)
    let result = try RBLink.reconcile(home: f.home, record: f.record, target: f.next, enabled: true, alternatives: [], beforeChange: {
        try! FileManager.default.removeItem(at: f.link)
        try! Data("F".utf8).write(to: f.link)
    }, afterSwap: { try! FileManager.default.removeItem(at: f.link) })
    #expect(result.taken)
    #expect(try String(contentsOf: f.link, encoding: .utf8) == "F")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.link.deletingLastPathComponent().path) == ["rb"])
}
@Test func rbLinkFailedReplaceKeepsRecord() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
    _ = try f.reconcile(true)
    let bin = f.link.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path) }
    #expect(throws: (any Error).self) { try f.reconcile(true, target: f.next) }
    #expect(try String(contentsOf: f.record, encoding: .utf8) == f.target.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    #expect(try !f.reconcile(true, target: f.next).taken)
    #expect(try String(contentsOf: f.record, encoding: .utf8) == f.next.path)
}
@Test func rbLinkOtherCommandsMustBeExecutable() throws {
    let f = LinkFixture(); try f.setup(); defer { f.cleanup() }
    let plain = f.home.appendingPathComponent("plain"), executable = f.home.appendingPathComponent("executable")
    try Data().write(to: plain); try Data().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let result = try RBLink.reconcile(home: f.home, record: f.record, target: f.target, enabled: true, alternatives: [plain, executable])
    #expect(result.otherCommands == [executable.path])
}
