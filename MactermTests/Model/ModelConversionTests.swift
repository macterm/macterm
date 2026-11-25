import Foundation
@testable import Macterm
import Testing

/// The v1 import (design/010 §8): the model that the app makes of v1's
/// files, and what the server and the mirror make of it.
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

        let local = ModelConversion.pane(PaneSnapshot(id: sessionID, projectPath: "/tmp", sessionName: name))
        #expect(local.id == sessionID.uuidString)
        #expect(local.host == nil)
    }

    @Test
    func each_project_holds_the_tabs_of_its_workspace_and_a_project_with_none_has_no_tabs() {
        let group = Project(name: "G", path: "")
        let a = Project(name: "a", path: "/a", parent: group.id)
        let b = Project(name: "b", path: "/b")
        let tab = TabSnapshot(
            id: UUID(),
            customTitle: nil,
            focusedPaneID: nil,
            splitRoot: .pane(PaneSnapshot(id: UUID(), projectPath: "/a"))
        )
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
        let tab = TabSnapshot(
            id: UUID(),
            customTitle: nil,
            focusedPaneID: nil,
            splitRoot: .pane(PaneSnapshot(id: UUID(), projectPath: "/p"))
        )
        let model = ModelConversion.model(
            projects: [p],
            workspaces: [
                .init(id: ModelConversion.V1.pinnedID, kind: .pinned, tabs: [tab], activeTabID: tab.id),
                .init(id: ModelConversion.V1.scratchID, kind: .scratch, tabs: [], activeTabID: nil),
            ],
            activeProjectID: ModelConversion.V1.pinnedID
        )
        let pinned = model.projects.first { $0.alias == "pinned" }
        #expect(pinned?.id == ModelConversion.V1.pinnedID.uuidString)
        #expect(pinned?.sidebar == .top)
        #expect(pinned?.removable == false)
        #expect(pinned?.path.isEmpty == true)
        #expect(pinned?.tabs.map(\.id) == [tab.id.uuidString])
        let scratch = model.projects.first { $0.alias == "scratch" }
        #expect(scratch?.id == ModelConversion.V1.scratchID.uuidString)
        #expect(scratch?.sidebar == .bottom)
        #expect(scratch?.removable == false)
        #expect(model.selection.activeProject == ModelConversion.V1.pinnedID.uuidString)
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

    // MARK: - Panes and tabs of a v1 file

    @Test
    func an_old_pane_with_no_session_gets_a_fresh_session() {
        let id = UUID()
        let pane = ModelConversion.pane(PaneSnapshot(id: id, projectPath: "/tmp/old"))
        #expect(pane.session.hasPrefix(ZmxSessionName.prefix))
        #expect(pane.id != id.uuidString, "a new session is a new pane id")
        #expect(pane.originPath == "/tmp/old")
    }

    @Test
    func a_pane_keeps_its_saved_session_name_and_its_folder() {
        // The saved name's slug is the project's at creation: a rename must
        // not make it again, or the pane attaches to a session that is gone.
        let sessionID = UUID()
        let pane = ModelConversion.pane(PaneSnapshot(
            id: UUID(),
            projectPath: "/tmp/renamed-project",
            sessionID: sessionID,
            sessionName: "macterm-oldname-aaaaaaaabbbb",
            workingDirectory: "/tmp/renamed-project/src"
        ))
        #expect(pane.id == sessionID.uuidString)
        #expect(pane.session == "macterm-oldname-aaaaaaaabbbb")
        #expect(pane.slug == "oldname")
        #expect(pane.cwd == "/tmp/renamed-project/src")
    }

    @Test
    func a_remote_pane_keeps_its_spec_and_no_local_folder() {
        let pane = ModelConversion.pane(PaneSnapshot(
            id: UUID(),
            projectPath: "user@host:/srv/app",
            sessionName: "macterm-app-aaaaaaaabbbb",
            workingDirectory: "/srv/app/src"
        ))
        #expect(pane.originPath == "user@host:/srv/app")
        #expect(pane.host == "user@host")
        #expect(pane.cwd == nil)
    }

    @Test
    func a_tab_keeps_its_branch_ids_and_its_focus_under_the_session_id() {
        // An older build saved a runtime `id` apart from `sessionID`, and
        // the tab's focus named the runtime id.
        let runtimeID = UUID()
        let sessionID = UUID()
        let branchID = UUID()
        let tab = ModelConversion.tab(TabSnapshot(
            id: UUID(),
            customTitle: "dev",
            focusedPaneID: runtimeID,
            splitRoot: .split(SplitBranchSnapshot(
                id: branchID,
                direction: .vertical,
                ratio: 0.3,
                first: .pane(PaneSnapshot(id: UUID(), projectPath: "/tmp/a", sessionID: UUID(), sessionName: "macterm-a-1")),
                second: .pane(PaneSnapshot(id: runtimeID, projectPath: "/tmp/b", sessionID: sessionID, sessionName: "macterm-b-2"))
            ))
        ))
        #expect(tab.customTitle == "dev")
        #expect(tab.focused == sessionID.uuidString)
        guard case let .split(split) = tab.root else {
            Issue.record("expected a split")
            return
        }
        #expect(split.id == branchID.uuidString)
        #expect(split.dir == .vertical)
        #expect(split.ratio == 0.3)
    }

    @Test
    func a_tab_with_no_saved_focus_focuses_its_first_pane() {
        let first = UUID()
        let tab = ModelConversion.tab(TabSnapshot(
            id: UUID(),
            customTitle: nil,
            focusedPaneID: nil,
            splitRoot: .split(SplitBranchSnapshot(
                direction: .horizontal,
                ratio: 0.5,
                first: .pane(PaneSnapshot(id: first, projectPath: "/a", sessionID: first, sessionName: "macterm-a-1")),
                second: .pane(PaneSnapshot(id: UUID(), projectPath: "/b", sessionName: "macterm-b-2"))
            ))
        ))
        #expect(tab.focused == first.uuidString)
    }

    // MARK: - v1's projects.json

    @Test
    func names_with_a_slash_get_a_hyphen_and_a_taken_name_gets_2() {
        let rows = [
            Project(name: "work-api", path: "/a"),
            Project(name: "work/api", path: "/b"),
            Project(name: "a/b", path: "/c"),
            Project(name: "plain", path: "/d"),
        ]
        let named = ModelConversion.namesWithoutSlash(rows)
        #expect(named.map(\.name) == ["work-api", "work-api 2", "a-b", "plain"])
        #expect(named.map(\.id) == rows.map(\.id))
    }

    @Test
    func readV1_normalizes_paths_and_reads_a_bad_parent_as_the_top_level() throws {
        let url = TestModel.folder("v1").appending(path: "projects.json")
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let json = """
        [
          {"id": "\(a.uuidString)", "name": "a", "path": "/tmp/a/", "sortOrder": 0, "createdAt": 0},
          {"id": "\(b.uuidString)", "name": "b", "path": "/tmp/b", "sortOrder": 1, "createdAt": 0, "parent": "\(c.uuidString)"},
          {"id": "\(c.uuidString)", "name": "c", "path": "/tmp/c", "sortOrder": 2, "createdAt": 0, "parent": "\(b.uuidString)"},
          {"id": "\(UUID().uuidString)", "name": "d", "path": "/tmp/d", "sortOrder": 3, "createdAt": 0, "parent": "\(UUID().uuidString)"}
        ]
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let (rows, failed) = ProjectStore.readV1(fileURL: url)

        #expect(!failed)
        #expect(rows.map(\.name) == ["a", "b", "c", "d"])
        #expect(rows[0].path == ProjectPath.normalizedForStorage("/tmp/a/"))
        #expect(rows[3].parent == nil, "a parent that is not a row")
        // b and c name each other: a loop reads as the top level.
        #expect(rows[1].parent == nil || rows[2].parent == nil)
    }

    @Test
    func readV1_of_a_file_that_does_not_read_fails_and_of_no_file_gives_nothing() throws {
        let folder = TestModel.folder("v1")
        let missing = ProjectStore.readV1(fileURL: folder.appending(path: "projects.json"))
        #expect(missing.rows.isEmpty && !missing.failed)
        let bad = folder.appending(path: "bad.json")
        try Data("{ not json".utf8).write(to: bad)
        #expect(ProjectStore.readV1(fileURL: bad).failed)
    }

    // MARK: - The import, through the server

    /// A v1 `workspaces_v3.json` with a project tab, a pinned live tab, a
    /// pinned record with no live tab, the quick terminal's tab and a widget.
    private struct V1Files {
        let project = Project(id: UUID(), name: "work/api", path: "/tmp/api")
        let other = Project(id: UUID(), name: "work-api", path: "/tmp/other")
        let projectTab: TabSnapshot
        let pinnedTab: TabSnapshot
        let quickTab: TabSnapshot
        let widgetTab: TabSnapshot
        let widgetID = UUID()
        let url: URL

        @MainActor
        init() throws {
            func tab(_ path: String) -> TabSnapshot {
                let id = UUID()
                return TabSnapshot(
                    id: UUID(),
                    customTitle: nil,
                    focusedPaneID: id,
                    splitRoot: .pane(PaneSnapshot(
                        id: id,
                        projectPath: path,
                        sessionID: id,
                        sessionName: ZmxSessionName.make(projectName: "x", paneSessionID: id)
                    ))
                )
            }
            projectTab = tab("/tmp/api")
            pinnedTab = tab("/tmp")
            quickTab = tab(NSHomeDirectory())
            widgetTab = tab(NSHomeDirectory())
            let declaration = LayoutTab(layout: .pane(LayoutPane()))
            let file = WorkspacesFile(
                version: 7,
                workspaces: [WorkspaceSnapshot(projectID: project.id, activeTabID: projectTab.id, tabs: [projectTab])],
                pinned: [
                    PinnedTabSnapshot(id: pinnedTab.id, declaration: declaration, originProjectID: project.id, live: pinnedTab),
                    PinnedTabSnapshot(id: UUID(), declaration: declaration, originProjectID: nil, live: nil),
                ],
                pinnedActiveTabID: pinnedTab.id,
                quickTerminal: quickTab,
                desktopWidgets: [DesktopWidgetSnapshot(
                    id: widgetID, name: "btop", tab: widgetTab, columns: 2, rows: 2, topLeftX: 0, topLeftY: 0
                )]
            )
            url = TestModel.folder("v1").appending(path: "workspaces_v3.json")
            try JSONEncoder().encode(file).write(to: url)
        }
    }

    /// The model that `AppState.importV1Files` sends for `files`. It reads
    /// v1's `projects.json` from the user's folder, so the test gives the
    /// rows itself and makes the inputs as the import does.
    private func importModel(_ files: V1Files) -> MactermProtocol.ModelData {
        let projects = ModelConversion.namesWithoutSlash([files.project, files.other])
        let loaded = WorkspaceStore(fileURL: files.url).load()
        let clean = WorkspaceSerializer.withoutRepeatedSessions(loaded, validIDs: Set(projects.map(\.id)))
        var inputs: [ModelConversion.WorkspaceInput] = clean.workspaces.map {
            .init(id: $0.projectID, kind: .project, tabs: $0.tabs, activeTabID: $0.activeTabID)
        }
        inputs.append(.init(
            id: ModelConversion.V1.pinnedID,
            kind: .pinned,
            tabs: clean.pinned.compactMap(\.live),
            activeTabID: clean.pinnedActiveTabID
        ))
        if let quick = clean.quickTerminal {
            inputs.append(.init(id: UUID(), kind: .quick, tabs: [quick], activeTabID: quick.id))
        }
        for widget in clean.desktopWidgets {
            inputs.append(.init(id: widget.id, kind: .widget, tabs: widget.tab.map { [$0] } ?? [], activeTabID: widget.tab?.id))
        }
        return ModelConversion.model(projects: projects, workspaces: inputs, activeProjectID: files.project.id)
    }

    @Test
    func an_old_workspaces_file_imports_its_projects_tabs_and_hidden_projects() throws {
        let files = try V1Files()
        let state = TestModel.appState()
        #expect(state.writer.modelImport(importModel(files), source: "test"))
        let model = state.model

        // The projects of the tree, with v1's names made allowed.
        #expect(model.treeProjects.map(\.id) == [files.project.id, files.other.id])
        #expect(model.project(files.project.id)?.name == "work-api 2")
        #expect(model.project(files.other.id)?.name == "work-api")
        #expect(model.tabs(of: files.project.id).map(\.id) == [files.projectTab.id])
        #expect(model.activeTabID(of: files.project.id) == files.projectTab.id)
        #expect(model.data?.selection.activeProject == files.project.id.uuidString)

        // Pinned: the live tab only; the record with no tab is GUI state.
        let pinned = try #require(state.pinnedProjectID)
        #expect(pinned == ModelConversion.V1.pinnedID)
        #expect(model.tabs(of: pinned).map(\.id) == [files.pinnedTab.id])
        #expect(model.project(pinned)?.sidebar == .top)

        // The quick terminal and the widget: single-tab projects that no
        // window draws.
        let quick = try #require(model.project(alias: QuickTerminalService.alias))
        #expect(quick.sidebar == MactermProtocol.ProjectSidebar.none)
        #expect(quick.singleTab)
        #expect(model.tabs(of: quick.id).map(\.id) == [files.quickTab.id])
        let widget = try #require(model.project(files.widgetID))
        #expect(widget.sidebar == MactermProtocol.ProjectSidebar.none)
        #expect(widget.singleTab)
        #expect(model.tabs(of: widget.id).map(\.id) == [files.widgetTab.id])

        // Each pane keeps its session.
        guard case let .pane(saved) = files.projectTab.splitRoot else {
            Issue.record("expected a leaf")
            return
        }
        let pane = try #require(model.tabs(of: files.project.id).first?.splitRoot.allPanes().first)
        #expect(pane.id == saved.sessionID)
        #expect(pane.sessionName == saved.sessionName)
        #expect(pane.projectID == files.project.id)

        // The hidden projects are not projects of the sidebar.
        let store = TestModel.projectStore(state)
        #expect(store.projects.map(\.id) == [files.project.id, files.other.id])
    }

    @Test
    func the_import_is_once_and_a_relaunch_installs_the_imported_model() throws {
        let files = try V1Files()
        let state = TestModel.appState()
        let data = importModel(files)
        #expect(state.writer.modelImport(data, source: "test"))
        #expect(!state.writer.modelImport(data, source: "test"), "the server refuses a second import")

        let again = TestModel.relaunch(state, guiStateStore: GUIStateStore(fileURL: TestModel.folder().appending(path: "gui-state.json")))
        #expect(again.model.data?.importedV1 == true)
        #expect(again.model.treeProjects.map(\.id) == [files.project.id, files.other.id])
        #expect(again.pinnedProjectID == ModelConversion.V1.pinnedID)
        #expect(again.model.project(alias: QuickTerminalService.alias) != nil)
        #expect(again.model.project(files.widgetID) != nil)
        #expect(again.model.tabs(of: files.project.id).map(\.id) == [files.projectTab.id])
    }
}
