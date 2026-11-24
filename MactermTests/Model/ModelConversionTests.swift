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
    func each_project_holds_the_tabs_of_its_workspace_and_a_project_with_none_has_no_tabs() {
        let group = Project(name: "G", path: "")
        let a = Project(name: "a", path: "/a", parent: group.id)
        let b = Project(name: "b", path: "/b")
        let tab = TabSnapshot(id: UUID(), customTitle: nil, focusedPaneID: nil, splitRoot: .pane(PaneSnapshot(id: UUID(), projectPath: "/a")))
        let model = ModelConversion.model(
            projects: [group, a, b],
            workspaces: [.init(id: a.id, kind: .project, tabs: [tab], activeTabID: tab.id)],
            activeProjectID: b.id
        )
        #expect(model.projects.map(\.path) == ["", "/a", "/b"])
        #expect(model.projects[1].parent == group.id.uuidString)
        #expect(model.projects[1].tabs.map(\.id) == [tab.id.uuidString])
        #expect(model.projects[1].activeTab == tab.id.uuidString)
        #expect(model.projects[0].tabs.isEmpty && model.projects[2].tabs.isEmpty)
        #expect(model.projects.allSatisfy { $0.sidebar == .tree && $0.removable && $0.alias == nil })
        #expect(model.selection.activeProject == b.id.uuidString)
    }

    @Test
    func the_pinned_and_the_scratch_workspaces_are_hidden_projects_that_a_window_can_select() {
        let p = Project(name: "p", path: "/p")
        let tab = TabSnapshot(id: UUID(), customTitle: nil, focusedPaneID: nil, splitRoot: .pane(PaneSnapshot(id: UUID(), projectPath: "/p")))
        let model = ModelConversion.model(
            projects: [p],
            workspaces: [
                .init(id: PinnedTabs.workspaceID, kind: .pinned, tabs: [tab], activeTabID: tab.id),
                .init(id: ScratchTabs.workspaceID, kind: .scratch, tabs: [], activeTabID: nil),
            ],
            activeProjectID: PinnedTabs.workspaceID
        )
        let pinned = model.projects.first { $0.alias == "pinned" }
        #expect(pinned?.id == PinnedTabs.workspaceID.uuidString)
        #expect(pinned?.sidebar == .top)
        #expect(pinned?.removable == false)
        #expect(pinned?.path == "")
        #expect(pinned?.tabs.map(\.id) == [tab.id.uuidString])
        let scratch = model.projects.first { $0.alias == "scratch" }
        #expect(scratch?.id == ScratchTabs.workspaceID.uuidString)
        #expect(scratch?.sidebar == .bottom)
        #expect(scratch?.removable == false)
        #expect(model.selection.activeProject == PinnedTabs.workspaceID.uuidString)
    }

    @Test
    func the_quick_and_widget_kinds_are_single_tab_projects_that_no_window_draws() {
        let input = ModelConversion.WorkspaceInput(id: UUID(), kind: .quick, tabs: [], activeTabID: nil)
        let quick = ModelConversion.hiddenProject(input)
        #expect(quick?.sidebar == MactermProtocol.ProjectSidebar.none)
        #expect(quick?.singleTab == true)
        #expect(quick?.removable == false)
        #expect(quick?.alias == "quick")
        let widget = ModelConversion.hiddenProject(.init(id: UUID(), kind: .widget, tabs: [], activeTabID: nil))
        #expect(widget?.singleTab == true)
        #expect(widget?.removable == true)
        #expect(widget?.alias == nil)
        #expect(ModelConversion.hiddenProject(.init(id: UUID(), kind: .project, tabs: [], activeTabID: nil)) == nil)
    }

    @Test
    func a_workspace_with_no_project_and_a_selection_of_no_project_are_not_sent() {
        let stray = UUID()
        let model = ModelConversion.model(
            projects: [],
            workspaces: [.init(id: stray, kind: .project, tabs: [], activeTabID: nil)],
            activeProjectID: stray
        )
        #expect(model.projects.isEmpty)
        #expect(model.selection.activeProject == nil)
    }

    @Test
    func differences_name_what_differs_and_ignore_the_order_of_projects() {
        let tab = MactermProtocol.Tab(id: "t1", root: .pane(.init(id: "a", session: "s")))
        let p1 = MactermProtocol.Project(id: "p1", name: "One", path: "/a", tabs: [tab], activeTab: "t1")
        let p2 = MactermProtocol.Project(id: "p2", name: "Two", path: "/b")
        let sent = MactermProtocol.ModelData(projects: [p1, p2])
        var mirror = sent
        mirror.projects.reverse()
        #expect(ModelConversion.differences(mirror: mirror, sent: sent).isEmpty)

        mirror.projects[1].tabs[0].customTitle = "x"
        mirror.projects[1].activeTab = nil
        mirror.projects[1].name = "Uno"
        mirror.projects.removeFirst()
        #expect(ModelConversion.differences(mirror: mirror, sent: sent) == [
            "projects[p1].active_tab",
            "projects[p1].tabs[t1]",
            "projects[p1]",
            "projects[p2]: missing",
        ])
    }
}
