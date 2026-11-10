import Testing
import RBContract
@testable import RBUI

@Test func hostileTitleProjectAndToastAreEscapedInHTML() throws {
    for text in ["<img src=x onerror=alert(1)>", "\"><script>"] {
        var (state, snapshot) = try FixtureHarness.load("M01.kontext")
        let projectID = try #require(snapshot.context?.projectId)
        let project = try #require(snapshot.projects.firstIndex { $0.id == projectID })
        snapshot.projects[project].name = text
        for index in snapshot.entries.indices where snapshot.entries[index].projectId == projectID {
            snapshot.entries[index].title = text
        }
        state.openProjects = [projectID]
        state.toast = Note(kind: .ok, text: text)
        let html = Renderer.render(state, snapshot).fullHTML
        let escaped = h(text)
        #expect(!html.contains(text))
        #expect(html.components(separatedBy: escaped).count >= 4)
    }
}
