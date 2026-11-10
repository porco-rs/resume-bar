import Foundation
import Testing
@testable import RBContract

// The 36 design fixtures are the shared contract: every one must decode into Snapshot
// without loss of the fields DATA.md defines.

let designRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/design")

struct FixtureEntry: Decodable { let key: String; let screen: String; let state: String; let file: String }

func fixtureEntries() throws -> [FixtureEntry] {
    try JSONDecoder().decode([FixtureEntry].self,
                             from: Data(contentsOf: designRoot.appendingPathComponent("fixtures/index.json")))
}

@Test func fixtureDatesKeepTheirInstant() throws {
    let data = try Data(contentsOf: designRoot.appendingPathComponent("fixtures/m01.kontext.json"))
    let snapshot = try RBJSON.decoder().decode(Snapshot.self, from: data)
    #expect(snapshot.now == RBJSON.parseDate("2026-11-04T11:00:00Z"))
    #expect(snapshot.settings.commands[.codex] == "codex resume {id}")
}

@Test func statusCycleFollowsFlows() {
    #expect(EntryStatus.offen.next == .wartet)
    #expect(EntryStatus.wartet.next == .erledigt)
    #expect(EntryStatus.erledigt.next == .offen)
}

@Test func v1SettingsFillNewDefaultsAndPreserveExistingValues() throws {
    let original = Settings.defaults
    let data = try JSONEncoder().encode(original)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var hotkeys = try #require(json["hotkeys"] as? [String: Any])
    hotkeys.removeValue(forKey: "task")
    hotkeys["popover"] = "⌥⌘Space"
    json["hotkeys"] = hotkeys
    json.removeValue(forKey: "ai")
    let v1Data = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(Settings.self, from: v1Data)
    #expect(decoded.hotkeys.popover == "⌥⌘Space")
    #expect(decoded.hotkeys.task == Settings.defaults.hotkeys.task)
    #expect(decoded.ai == Settings.defaults.ai)
    #expect(decoded.commands == original.commands)
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(decoded)) == decoded)
}

// Design fixtures decode into Snapshot; unsupported MCP keys in settings.ai are ignored.
@Test func allDesignFixturesDecodeIntoSnapshot() throws {
    let root = designRoot
    let index = try JSONDecoder().decode([FixtureEntry].self, from: Data(contentsOf: root.appendingPathComponent("fixtures/index.json")))
    #expect(index.count == 36)
    for entry in index {
        let snap = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/" + entry.file)))
        #expect(snap.schemaVersion == 2, "\(entry.key)")
        for session in snap.sessions {
            #expect(session.id == session.tool.idPrefix + session.nativeId, "\(entry.file) \(session.id)")
            if let project = session.projectId { #expect(snap.project(project) != nil, "\(entry.file) project of \(session.id)") }
            #expect(snap.entry(session.entryId) != nil, "\(entry.key): \(session.id) without entry")
        }
    }
}
