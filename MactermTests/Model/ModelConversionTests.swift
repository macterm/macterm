import Foundation
@testable import Macterm
import Testing

/// The model that the shadow stage sends (design/010 §1, §8).
@MainActor
struct ModelConversionTests {
    @Test
    func a_pane_takes_its_session_id_and_its_host() {
        let sessionID = UUID()
        let name = ZmxSessionName.make(projectName: "srv", paneSessionID: sessionID)
        let pane = ModelConversion.pane(PaneSnapshot(
            id: UUID(),
            projectPath: "bob@box:/srv",
            sessionID: sessionID,
            sessionName: name,
            hostSessionDirectory: "/srv/app"
        ))
        #expect(pane.id == sessionID.uuidString)
        #expect(pane.session == name)
        #expect(pane.slug == "srv")
        #expect(pane.host == "bob@box")
        #expect(pane.originPath == "bob@box:/srv")
        #expect(pane.hostSessionDir == "/srv/app")
        #expect(pane.attention == .none)

        let local = ModelConversion.pane(PaneSnapshot(id: sessionID, projectPath: "/tmp"))
        #expect(local.id == sessionID.uuidString)
        #expect(local.host == nil)
    }

    @Test
    func every_project_gets_a_workspace_a_project_with_no_folder_too() {
        let group = Project(name: "G", path: "")
        let a = Project(name: "a", path: "/a", parent: group.id)
        let b = Project(name: "b", path: "/b")
        let model = ModelConversion.model(
            projects: [group, a, b],
            workspaces: [.init(id: a.id, kind: .project, tabs: [], activeTabID: nil)],
            activeProjectID: b.id
        )
        #expect(model.projects.map(\.path) == ["", "/a", "/b"])
        #expect(model.projects[1].parent == group.id.uuidString)
        #expect(Set(model.workspaces.map(\.id)) == Set([group.id, a.id, b.id].map(\.uuidString)))
        #expect(model.selection.activeProject == b.id.uuidString)
    }

    @Test
    func differences_name_what_differs_and_ignore_the_order_of_projects() {
        let p1 = MactermProtocol.Project(id: "p1", name: "One", path: "/a")
        let p2 = MactermProtocol.Project(id: "p2", name: "Two", path: "/b")
        let tab = MactermProtocol.Tab(id: "t1", root: .pane(.init(id: "a", session: "s")))
        let sent = MactermProtocol.ModelData(
            projects: [p1, p2],
            workspaces: [.init(id: "p1", kind: .project, tabs: [tab], activeTab: "t1"), .init(id: "p2", kind: .project)]
        )
        var mirror = sent
        mirror.projects.reverse()
        #expect(ModelConversion.differences(mirror: mirror, sent: sent).isEmpty)

        mirror.workspaces[0].tabs[0].customTitle = "x"
        mirror.workspaces[0].activeTab = nil
        mirror.workspaces.removeLast()
        #expect(ModelConversion.differences(mirror: mirror, sent: sent) == [
            "workspaces[p1].active_tab",
            "workspaces[p1].tabs[t1]",
            "workspaces[p2]: missing",
        ])
    }
}
