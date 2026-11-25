import AppKit
import Foundation
@testable import Macterm
import Testing

/// Per-window selection (#345).
///
/// `AppState.activeProjectID` is a MIRROR of whichever window is key, so the
/// far larger number of "the frontmost project" call sites keep working
/// unchanged while each window renders its own. These pin both directions of
/// that mirror, which is where the bugs were.
@MainActor
struct WindowStateTests {
    /// Tempdir-backed, like every other AppState test — never the developer's
    /// real Application Support.
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projects)
        )
    }

    @Test
    func a_new_window_opens_on_the_project_the_user_was_looking_at() {
        let state = makeAppState()
        let project = UUID()
        state.activeProjectID = project

        let window = WindowState()
        state.registerWindow(window)

        #expect(window.activeProjectID == project)
    }

    @Test
    func becoming_key_points_the_app_at_that_windows_project() {
        // The mirror's outward direction: polling cadence, remote probes and
        // shell warming all read activeProjectID and mean "the window the user
        // is in".
        let state = makeAppState()
        let a = WindowState(activeProjectID: UUID())
        let b = WindowState(activeProjectID: UUID())
        state.registerWindow(a)
        state.registerWindow(b)

        state.noteKeyWindow(a)
        #expect(state.activeProjectID == a.activeProjectID)

        state.noteKeyWindow(b)
        #expect(state.activeProjectID == b.activeProjectID)
    }

    @Test
    func becoming_key_without_a_project_adopts_rather_than_wiping() {
        // A window registers from the view's window-attach, which happens
        // before the launch task restores the selection — so it can become key
        // with no project. Pushing that nil outward would erase the restored
        // project for the whole app.
        let state = makeAppState()
        let restored = UUID()
        state.activeProjectID = restored
        let window = WindowState()
        window.activeProjectID = nil

        state.noteKeyWindow(window)

        #expect(state.activeProjectID == restored)
        #expect(window.activeProjectID == restored)
    }

    @Test
    func setting_the_app_project_follows_into_the_key_window() {
        // The mirror's inward direction. Most callers still set
        // activeProjectID directly — CLI `project select`, notification
        // navigation, a cross-project tab move — and the window the user is
        // looking at has to follow, or it keeps rendering the old project.
        let state = makeAppState()
        let window = WindowState(activeProjectID: UUID())
        state.registerWindow(window)
        state.noteKeyWindow(window)

        let moved = UUID()
        state.activeProjectID = moved

        #expect(window.activeProjectID == moved)
    }

    @Test
    func selecting_in_a_background_window_leaves_the_app_project_alone() {
        // Otherwise a selection made in a window the user is NOT in would
        // repoint polling and shell warming at it.
        let state = makeAppState()
        let key = WindowState(activeProjectID: UUID())
        let background = WindowState(activeProjectID: UUID())
        state.registerWindow(key)
        state.registerWindow(background)
        state.noteKeyWindow(key)
        let appProject = state.activeProjectID

        let other = UUID()
        state.selectProject(other, in: background)

        #expect(background.activeProjectID == other)
        #expect(state.activeProjectID == appProject)
    }

    @Test
    func a_dialog_belongs_to_the_focused_window() {
        // Every window's scene carries its own copy of the confirmation
        // alerts, so an ungated binding presents in ALL of them — the same
        // failure the DialogHost.settings gate already prevents for Settings.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)

        state.noteKeyWindow(b)
        #expect(state.dialogWindowID == b.id)

        state.noteKeyWindow(a)
        #expect(state.dialogWindowID == a.id)
    }

    @Test
    func a_dialog_still_has_somewhere_to_go_with_no_key_window() {
        // Never nil while a window exists: a staged confirmation with nowhere
        // to appear leaves the action unfinished and unexplained.
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)

        #expect(state.keyWindowID == nil)
        #expect(state.dialogWindowID == window.id)
    }

    @Test
    func a_new_window_opens_at_the_app_wide_sidebar_width() {
        let previous = Preferences.shared.sidebarWidth
        defer { Preferences.shared.sidebarWidth = previous }
        Preferences.shared.sidebarWidth = 275

        #expect(WindowState().sidebarWidth == 275)
    }

    @Test
    func windows_keep_independent_sidebar_widths() {
        // Dragging one window's sidebar must not resize another's.
        let state = makeAppState()
        let a = WindowState(sidebarWidth: 200)
        let b = WindowState(sidebarWidth: 320)
        state.registerWindow(a)
        state.registerWindow(b)

        #expect(a.sidebarWidth == 200)
        #expect(b.sidebarWidth == 320)
    }

    // MARK: - Per-window presentation state

    @Test
    func presentation_flags_belong_to_the_key_window() {
        // The palette, the sidebar and the remote-project sheet used to be
        // app-wide, so every window rendered them. The AppState properties are
        // now mirrors of the key window's copy.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        state.isCommandPaletteVisible = true
        #expect(a.isCommandPaletteVisible)
        #expect(!b.isCommandPaletteVisible)

        state.sidebarVisible = false
        #expect(!a.sidebarVisible)
        #expect(b.sidebarVisible)

        state.noteKeyWindow(b)
        #expect(!state.isCommandPaletteVisible, "the mirror reads the new key window")
        #expect(state.sidebarVisible)
    }

    // MARK: - Windows and termination

    @Test
    func windows_are_not_unregistered_while_terminating() {
        // Quit closes every window; each teardown used to unregister and save,
        // so the termination snapshot was rewritten with one window fewer per
        // close and a relaunch brought back only one.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)

        AppTerminationState.isTerminating = true
        defer { AppTerminationState.isTerminating = false }
        state.unregisterWindow(b)

        #expect(state.windows.count == 2)
    }

    @Test
    func the_key_window_is_recorded_in_the_snapshot() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceStore(fileURL: tmp)
        let state = AppState(workspaceStore: store, projectFiles: ProjectFileStore(directoryURL: projects))
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(b)

        state.saveWorkspaces()

        let saved = store.load().windows
        #expect(saved.map(\.isKey) == [false, true])
    }

    @Test
    func vacating_a_project_clears_every_window_showing_it() {
        // Removal tears the shells down; a window still showing the project
        // would render a workspace that no longer exists.
        let state = makeAppState()
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        state.removeProject(project.id)

        #expect(a.activeProjectID == nil)
        #expect(b.activeProjectID == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test
    func revealing_a_project_prefers_the_window_already_showing_it() {
        // A notification click or CLI focus for project Q while the user is in
        // a window on P must front Q's window, not repoint P's.
        let state = makeAppState()
        let p = UUID()
        let q = UUID()
        let onP = WindowState(activeProjectID: p)
        let onQ = WindowState(activeProjectID: q)
        state.registerWindow(onP)
        state.registerWindow(onQ)
        state.noteKeyWindow(onP)

        state.revealProject(q)

        #expect(onP.activeProjectID == p, "the window the user was in keeps its project")
        #expect(state.keyWindowID == onQ.id)
        #expect(state.activeProjectID == q)
    }

    @Test
    func revealing_an_unshown_project_takes_the_key_window() {
        let state = makeAppState()
        let p = UUID()
        let q = UUID()
        let window = WindowState(activeProjectID: p)
        state.registerWindow(window)
        state.noteKeyWindow(window)

        state.revealProject(q)

        #expect(window.activeProjectID == q)
    }

    // MARK: - Per-window tab selection

    /// A project with `count` tabs, selected in `state`.
    private func seedProject(_ state: AppState, tabs count: Int, path: String = "/tmp") throws -> (Project, Workspace) {
        let project = Project(name: "p", path: path, sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let ws = try #require(state.workspaces[project.id])
        for _ in 1 ..< count {
            _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        }
        return (project, ws)
    }

    @Test
    func two_windows_on_one_tab_draw_the_same_panes_with_a_surface_each() throws {
        // A surface is one window's view of a pane. Two windows that select
        // one tab draw the same pane ids, and each has its own surface, which
        // is its own client of the session.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        #expect(state.selectedTab(for: project.id, in: a) === tab)
        #expect(state.selectedTab(for: project.id, in: b) === tab)
        for pane in tab.splitRoot.allPanes() {
            let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
            let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
            #expect(forA !== forB)
            #expect(forA.pane === pane)
            #expect(forB.pane === pane)
            #expect(SurfaceRegistry.shared.surface(for: pane, in: .window(a.id)) === forA, "the same surface for the same window")
            #expect(SurfaceRegistry.shared.surface(for: pane, in: .window(b.id)) === forB)
            #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 2)
        }
        #expect(!state.showsTabOfEarlierWindow(a))
        #expect(state.showsTabOfEarlierWindow(b))
    }

    @Test
    func surfaces_are_stable_across_key_window_changes() throws {
        // Cmd-tabbing between the two windows must not rebuild a surface: each
        // surface is a client of the session, with a screen of its own.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))

        state.noteKeyWindow(b)
        state.noteKeyWindow(a)

        #expect(SurfaceRegistry.shared.surface(for: pane, in: .window(a.id)) === forA)
        #expect(SurfaceRegistry.shared.surface(for: pane, in: .window(b.id)) === forB)
        #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 2)
    }

    @Test
    func selecting_a_tab_another_window_shows_puts_both_windows_on_it() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let first = ws.tabs[0], second = ws.tabs[1]
        state.selectTab(first.id, projectID: project.id)
        state.selectTab(second.id, projectID: project.id, in: b)
        #expect(!state.showsTabOfEarlierWindow(b), "a shows the first tab")

        state.selectTab(second.id, projectID: project.id)

        #expect(ws.activeTabID == second.id)
        #expect(state.selectedTab(for: project.id, in: a) === second)
        #expect(state.selectedTab(for: project.id, in: b) === second)
        #expect(state.showsTabOfEarlierWindow(b))
    }

    @Test
    func a_split_gives_the_new_pane_to_every_window_on_the_tab() throws {
        // One tab, one tree: the panes that a split makes or a close leaves
        // are the panes of every window. Nothing is rebuilt per window.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let source = try #require(tab.splitRoot.allPanes().first)
        let added = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))

        let panes = try #require(state.selectedTab(for: project.id, in: b)).splitRoot.allPanes()
        #expect(panes.map(\.id) == [source.id, added])
        let newPane = try #require(tab.splitRoot.findPane(id: added))
        #expect(SurfaceRegistry.shared.surface(for: newPane, in: .window(a.id)) !== SurfaceRegistry.shared.surface(
            for: newPane,
            in: .window(b.id)
        ))

        state.closePane(source.id, projectID: project.id)
        #expect(state.selectedTab(for: project.id, in: b)?.splitRoot.allPanes().map(\.id) == [added])
    }

    @Test
    func a_surface_is_retired_when_its_window_moves_on() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        // The key window holds the first tab, and b selects it too.
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[0].id, projectID: project.id, in: b)
        let pane = try #require(ws.tabs[0].splitRoot.allPanes().first)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        _ = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 2)

        state.selectTab(ws.tabs[1].id, projectID: project.id, in: b)

        #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 1, "b's client goes with its view of the tab")
        #expect(SurfaceRegistry.shared.surfaces(of: pane).first === forA)
    }

    @Test
    func a_closed_window_gives_its_surfaces_up() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        _ = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        _ = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 2)

        state.unregisterWindow(b)

        #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 1)
        #expect(!state.isMirrored(pane), "one client per session again")
    }

    /// The model makes no surface on its own for a window that never asks. A
    /// surface is a client of the session: a stray one led each new session,
    /// and zmx then dropped ⌃D in the visible pane until a Return (#657).
    @Test
    func a_window_that_does_not_draw_a_pane_gets_no_surface_for_it() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.unregisterWindow(b)

        for _ in 0 ..< 3 {
            let source = try #require(tab.splitRoot.allPanes().last)
            _ = try #require(state.splitPane(
                source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
            ))
        }

        for pane in tab.splitRoot.allPanes() {
            #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 1)
            #expect(!state.isMirrored(pane), "one client per session")
        }
    }

    @Test
    func surfaces_of_two_windows_take_part_in_leadership() throws {
        // A second window's surface is a real client of the session: the
        // window that a click makes key claims the pty and dims the other
        // window's view.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        session.attach([forA, forB])
        #expect(state.isMirrored(pane))
        #expect(forA.isLeader, "a's view leads until b's is used")

        state.noteKeyWindow(b)
        state.focusPane(pane.id, projectID: project.id, windowID: b.id)

        #expect(forB.isLeader)
        #expect(!forA.isLeader)
        #expect(state.nonLeaderPaneIDs(in: tab, window: a.id) == [pane.id])
        #expect(state.nonLeaderPaneIDs(in: tab, window: b.id).isEmpty)
    }

    @Test
    func creating_a_tab_in_the_key_window_records_it_there() throws {
        // Every writer of Workspace.activeTabID — create, close, cycle, the
        // CLI — reaches the key window's record through the workspace hook.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.noteKeyWindow(a)

        let created = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")

        #expect(a.activeTabIDs[project.id] == created.id)
        #expect(state.selectedTab(for: project.id, in: a)?.id == created.id)
    }

    @Test
    func a_background_window_selects_its_own_tab() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 3)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let before = ws.activeTabID
        let third = ws.tabs[2]

        state.selectTab(third.id, projectID: project.id, in: b)

        #expect(ws.activeTabID == before, "a background selection leaves the key window alone")
        #expect(state.selectedTab(for: project.id, in: b)?.id == third.id)
    }

    @Test
    func restored_windows_take_their_entries_in_order() {
        // The FIFO: each restored window pops its own snapshot entry as it
        // registers, so the second window gets the second project and so on.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p, q])
        writer.selectProject(p)
        writer.selectProject(q)
        let w1 = WindowState(activeProjectID: p.id)
        let w2 = WindowState(activeProjectID: q.id, sidebarWidth: 333)
        w2.sidebarVisible = false
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.noteKeyWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p, q])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.activeProjectID == p.id)
        #expect(second.activeProjectID == q.id)
        #expect(second.sidebarWidth == 333)
        #expect(!second.sidebarVisible, "sidebar visibility is the window's own, restored with it")
    }

    @Test
    func each_window_keeps_its_own_insights_panel_across_a_restart() {
        // The panel is open or closed per window. The toggle acts on the key
        // window only, and a restore gives each window its own value back.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files, legacyPanelVisible: { false })
        writer.restoreSelection(projects: [p, q])
        writer.selectProject(p)
        writer.selectProject(q)
        let w1 = WindowState(activeProjectID: p.id)
        let w2 = WindowState(activeProjectID: q.id)
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.noteKeyWindow(w1)
        writer.projectMemoryPanelVisible.toggle()
        #expect(w1.projectMemoryPanelVisible)
        #expect(!w2.projectMemoryPanelVisible, "the toggle acts on the key window only")
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files, legacyPanelVisible: { true })
        reader.restoreSelection(projects: [p, q])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.projectMemoryPanelVisible)
        #expect(!second.projectMemoryPanelVisible, "a saved value wins over the retired app-wide one")
        let third = WindowState()
        reader.registerWindow(third)
        #expect(!third.projectMemoryPanelVisible, "a new window opens with the panel closed")
    }

    @Test
    func the_retired_app_wide_panel_value_opens_the_panel_in_windows_with_no_value_once() throws {
        // A file from a build where the panel was one toggle for the app has
        // no per-window value. With that toggle on, each restored window
        // shows the panel; the reader is asked once.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files, legacyPanelVisible: { false })
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        let w1 = WindowState(activeProjectID: p.id)
        let w2 = WindowState(activeProjectID: p.id)
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.noteKeyWindow(w1)
        writer.saveWorkspaces()
        // The file as the app-wide builds wrote it.
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any] ?? [:]
        var windows = file["windows"] as? [[String: Any]] ?? []
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0["projectMemoryPanelVisible"] as? Bool == false }, "each window writes its own value")
        for index in windows.indices {
            windows[index]["projectMemoryPanelVisible"] = nil
        }
        file["windows"] = windows
        try JSONSerialization.data(withJSONObject: file).write(to: tmp)

        var reads = 0
        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files, legacyPanelVisible: {
            reads += 1
            return true
        })
        reader.restoreSelection(projects: [p])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        let second = WindowState()
        reader.registerWindow(second)
        #expect(first.projectMemoryPanelVisible)
        #expect(second.projectMemoryPanelVisible)
        #expect(reads == 1)
    }

    @Test
    func the_retired_app_wide_panel_value_is_read_once_and_removed() {
        let preferences = Preferences.shared
        Preferences.defaults.set(true, forKey: "macterm.memory.panelVisible")
        #expect(preferences.takeLegacyProjectMemoryPanelVisible())
        #expect(Preferences.defaults.object(forKey: "macterm.memory.panelVisible") == nil)
        #expect(!preferences.takeLegacyProjectMemoryPanelVisible())
    }

    @Test
    func every_window_reopens_at_its_own_saved_frame() {
        // #496: the frame was left to SwiftUI's autosave, whose key changes
        // every launch, so windows always came back at the default size. It
        // is the window's own snapshot entry now — the first window adopts
        // entry 0's frame, and each restored window its own.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let firstFrame = "100 200 1400 900 0 0 3008 1662 "
        let secondFrame = "1508 9 1492 1645 0 0 3008 1662 "

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        let w1 = WindowState(activeProjectID: p.id)
        let w2 = WindowState(activeProjectID: p.id)
        w1.frame = firstFrame
        w2.frame = secondFrame
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.frame == firstFrame)
        #expect(second.frame == secondFrame)

        // A window the user opens afterwards has no saved frame to adopt; it
        // opens wherever the scene puts it.
        let opened = WindowState()
        reader.registerWindow(opened)
        #expect(opened.frame == nil)
    }

    @Test
    func a_window_adopted_before_it_registers_keeps_its_saved_sidebar() {
        // #552: the launch task can run `restoreWindows` before the scene's
        // own window attaches. Its registration then looked like a window the
        // user opened, which reset the restored sidebar to the defaults, and
        // it took the pending entry meant for the second restored window.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p, q])
        let w1 = WindowState(activeProjectID: p.id, sidebarWidth: 320)
        w1.sidebarVisible = false
        let w2 = WindowState(activeProjectID: q.id, sidebarWidth: 280)
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p, q])
        let first = WindowState()
        reader.restoreWindows(adopting: first)
        reader.registerWindow(first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.activeProjectID == p.id)
        #expect(first.sidebarWidth == 320)
        #expect(!first.sidebarVisible)
        #expect(second.activeProjectID == q.id, "the second window still gets its own entry")
        #expect(second.sidebarWidth == 280)

        // A window the user opens afterwards still comes up at the defaults.
        let opened = WindowState(sidebarWidth: 333)
        reader.registerWindow(opened)
        #expect(opened.sidebarWidth == Preferences.defaultSidebarWidth)
    }

    /// A store with one project and one saved window on it, and a fresh
    /// `AppState` that has read it back — the launch, up to `restoreWindows`.
    private func relaunchWithOneSavedWindow() -> (AppState, Project) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        writer.registerWindow(WindowState(activeProjectID: p.id))
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p])
        return (reader, p)
    }

    @Test
    func a_window_adopted_before_it_registers_keeps_the_panes_it_draws() throws {
        // The launch task gives the scene's window its project before the
        // window attaches, and the window draws its tab in that gap.
        // Registration must keep the panes and make no second client.
        let (state, project) = relaunchWithOneSavedWindow()
        let first = WindowState()
        state.restoreWindows(adopting: first)

        let before = try #require(state.selectedTab(for: project.id, in: first))
        let pane = try #require(before.splitRoot.allPanes().first)
        let surface = SurfaceRegistry.shared.surface(for: pane, in: .window(first.id))

        state.registerWindow(first)
        let after = try #require(state.selectedTab(for: project.id, in: first))
        #expect(after === before, "registration keeps the panes the window already draws")
        #expect(SurfaceRegistry.shared.surface(for: pane, in: .window(first.id)) === surface)
        #expect(SurfaceRegistry.shared.surfaces(of: pane).count == 1)
    }

    @Test
    func a_registered_window_and_an_adopted_window_show_the_same_tab() {
        let (state, project) = relaunchWithOneSavedWindow()
        let registered = WindowState(activeProjectID: project.id)
        state.registerWindow(registered)
        let first = WindowState()
        state.restoreWindows(adopting: first)

        let tab = state.selectedTab(for: project.id, in: registered)
        #expect(tab != nil)
        #expect(state.selectedTab(for: project.id, in: first) === tab)
    }

    @Test
    func each_window_keeps_its_open_project_sections_across_a_relaunch() {
        // The sections were view state, rebuilt empty at every launch: every
        // project but the active one came back closed. A closed active
        // project must stay closed too, although activation opens it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)
        let r = Project(name: "r", path: "/tmp/r", sortOrder: 2)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p, q, r])
        let w1 = WindowState(activeProjectID: p.id)
        w1.expandedRows = [q.id, r.id]
        let w2 = WindowState(activeProjectID: q.id)
        w2.expandedRows = [q.id, p.id]
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p, q, r])
        let first = WindowState()
        reader.restoreWindows(adopting: first)
        reader.registerWindow(first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.activeProjectID == p.id)
        #expect(first.expandedRows == [q.id, r.id], "the closed active project stays closed")
        #expect(second.expandedRows == [q.id, p.id])

        // A window the user opens afterwards opens only its active project.
        let opened = WindowState()
        reader.registerWindow(opened)
        #expect(opened.expandedRows == Set([opened.activeProjectID].compactMap(\.self)))
    }

    @Test
    func activating_a_project_opens_its_section_and_removing_it_forgets_it() {
        let state = makeAppState()
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)
        state.restoreSelection(projects: [p, q])
        let window = WindowState(activeProjectID: p.id)
        state.registerWindow(window)
        #expect(window.expandedRows == [p.id])

        window.expandedRows.remove(p.id)
        window.activeProjectID = q.id
        #expect(window.expandedRows == [q.id], "only a change of project opens a section")

        window.activeProjectID = PinnedTabs.workspaceID
        #expect(window.expandedRows == [q.id], "the pinned workspace has no section")

        state.removeProject(q.id)
        #expect(!window.expandedRows.contains(q.id))
    }

    @Test
    func a_snapshot_saved_before_sections_were_persisted_opens_the_active_project() throws {
        let json = #"{"activeProjectID":null,"sidebarWidth":200,"isKey":true}"#
        let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.expandedProjectIDs == nil)
    }

    @Test
    func a_snapshot_saved_before_frames_were_persisted_still_restores() throws {
        // `frame` is optional, so a v6 file written by an older build decodes
        // and its windows open at the default size.
        let json = #"{"activeProjectID":null,"sidebarWidth":200,"isKey":true}"#
        let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.frame == nil)
        #expect(snapshot.sidebarWidth == 200)
    }

    @Test
    func a_window_the_user_opens_comes_up_at_the_default_sidebar_state() {
        // Not at whatever was last dragged in some other (possibly since
        // closed) window, and never collapsed.
        let previous = Preferences.shared.sidebarWidth
        defer { Preferences.shared.sidebarWidth = previous }
        Preferences.shared.sidebarWidth = 333
        let state = makeAppState()
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        let first = WindowState()
        state.registerWindow(first)
        state.noteKeyWindow(first)
        state.restoreWindows(adopting: first)
        #expect(state.hasRestoredWindows)

        let opened = WindowState()
        opened.sidebarVisible = false
        state.registerWindow(opened)

        #expect(opened.sidebarWidth == Preferences.defaultSidebarWidth)
        #expect(opened.sidebarVisible)
    }

    @Test
    func becoming_key_claims_leadership_for_every_pane_of_the_windows_tab() throws {
        // Leadership is per tab, driven by the key window: fronting the other
        // window must hand the pty to all of its panes at once, without a
        // click in each.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let panes = tab.splitRoot.allPanes()
        for pane in panes {
            session.attach([
                SurfaceRegistry.shared.surface(for: pane, in: .window(a.id)),
                SurfaceRegistry.shared.surface(for: pane, in: .window(b.id)),
            ])
        }
        session.claimed = []

        state.noteKeyWindow(b)
        #expect(Set(session.claimed) == Set(panes.map { SurfaceRegistry.shared.surface(for: $0, in: .window(b.id)).id }))
        #expect(state.nonLeaderPaneIDs(in: tab, window: a.id) == Set(panes.map(\.id)))
        #expect(state.nonLeaderPaneIDs(in: tab, window: b.id).isEmpty)

        session.claimed = []
        state.noteKeyWindow(a)
        #expect(Set(session.claimed) == Set(panes.map { SurfaceRegistry.shared.surface(for: $0, in: .window(a.id)).id }))
        #expect(state.nonLeaderPaneIDs(in: tab, window: a.id).isEmpty)
    }

    @Test
    func the_first_remaining_window_becomes_key_when_the_key_window_closes() {
        // AppKit reports the new key window only while the app is active; a
        // headless harness never sees it, and every window read as unfocused.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(b)

        state.unregisterWindow(b)

        #expect(state.keyWindowID == a.id)
    }

    @Test
    func a_window_keeps_its_tab_when_the_key_window_switches_tabs() throws {
        // A window with no record of its own used to fall back to the
        // workspace's active tab — the KEY window's — and so followed every
        // tab switch made in the other window, rebuilding its mirror each time.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let shown = try #require(state.selectedTab(for: project.id, in: b))
        let other = try #require(ws.tabs.first { $0.id != shown.id })

        state.selectTab(other.id, projectID: project.id)

        #expect(state.selectedTab(for: project.id, in: a)?.id == other.id)
        #expect(state.selectedTab(for: project.id, in: b)?.id == shown.id, "b stays where it was")
    }

    @Test
    func a_lead_for_a_client_outside_the_key_window_makes_the_key_window_claim() throws {
        // The session makes the next client lead when the leader leaves, and
        // that client can be in a window that is not key. The key window's
        // surfaces claim again, as on any key change.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        session.attach([forB, forA])
        session.claimed = []

        state.claimLeadershipForKeyWindow()

        #expect(session.claimed == [forA.id])
        #expect(forA.isLeader)
        #expect(!forB.isLeader)
    }

    @Test
    func a_remote_tabs_back_window_claims_when_it_becomes_key() throws {
        // Two windows on one tab of a remote project. The window that comes
        // to the front claims at once: one click, with no click in a pane.
        // The rule has no remote exception (before #830 it had one).
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1, path: "me@devbox:~/dev/api")
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        #expect(pane.isRemote)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        session.attach([forA, forB])
        session.claimed = []

        state.noteKeyWindow(b)

        #expect(session.claimed == [forB.id])
        #expect(forB.isLeader)
        #expect(!forA.isLeader)
        #expect(state.isLedFromAnotherWindow(pane, window: a.id))
    }

    @Test
    func the_first_lead_after_an_attach_makes_the_key_window_claim() async throws {
        // A claim that went out while the channel was down is lost. The first
        // `lead` of the new attach posts `.terminalSessionLead`, and the
        // observer lets the key window claim again.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        forB.receiveLead(true)
        state.noteKeyWindow(a)
        session.claimed = []

        forA.receiveLead(nil)
        forA.receiveLead(false)

        let deadline = Date().addingTimeInterval(5)
        while session.claimed.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.claimed.contains(forA.id))
        #expect(forA.isLeader)
    }

    @Test
    func a_surface_that_gets_its_size_in_the_key_windows_tab_claims_leadership() throws {
        // The claim on key change is refused until the surface has a size;
        // the surface-sized report sends it again.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        session.deliverable = false
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        session.attach([forA, forB])
        state.noteKeyWindow(b)
        #expect(session.claimed.isEmpty)

        session.deliverable = true
        state.claimLeadershipForKeyWindow()

        #expect(session.claimed == [forB.id])
        #expect(forB.isLeader)
    }

    /// A client that the model does not know of (a `zmx connect` from
    /// another terminal) can lead. The session says so, and the key window's
    /// pane claims on its next size or key change.
    @Test
    func the_key_windows_pane_claims_back_from_a_client_outside_the_model() throws {
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        let surface = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        surface.receiveLead(false)
        #expect(!state.isMirrored(pane))

        state.noteKeyWindow(a)

        #expect(session.claimed == [surface.id])
        #expect(state.isLeader(pane))
    }

    /// The back window of two on one tab hides its tab: the key window leads
    /// every pane, so the panes here would show at the other window's size.
    @Test
    func a_pane_that_another_window_leads_is_led_from_another_window() throws {
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        session.attach([
            SurfaceRegistry.shared.surface(for: pane, in: .window(a.id)),
            SurfaceRegistry.shared.surface(for: pane, in: .window(b.id)),
        ])

        state.noteKeyWindow(b)

        #expect(state.isLedFromAnotherWindow(pane, window: a.id))
        #expect(!state.isLedFromAnotherWindow(pane, window: b.id))
    }

    /// One pane of a split that another window leads is enough: that pane
    /// would show at the wrong size.
    @Test
    func one_pane_led_from_another_window_is_enough() throws {
        let state = makeAppState()
        _ = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        let panes = tab.splitRoot.allPanes()
        SurfaceRegistry.shared.surface(for: panes[0], in: .window(a.id)).receiveLead(false)
        SurfaceRegistry.shared.surface(for: panes[0], in: .window(b.id)).receiveLead(true)

        #expect(panes.filter { state.isLedFromAnotherWindow($0, window: a.id) }.map(\.id) == [panes[0].id])
    }

    /// A client outside Macterm is not another window: the pane only blurs.
    @Test
    func a_lead_outside_the_other_windows_is_not_led_from_another_window() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        SurfaceRegistry.shared.surface(for: pane, in: .window(a.id)).receiveLead(false)
        #expect(!state.isLedFromAnotherWindow(pane, window: a.id))
    }

    /// A pane that comes up in a window that is NOT key claims nothing on
    /// its own: leadership follows the key window's tab.
    @Test
    func a_pane_in_a_background_window_does_not_claim() throws {
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[1].id, projectID: project.id, in: b)
        let background = try #require(ws.tabs[1].splitRoot.allPanes().first)
        let surface = SurfaceRegistry.shared.surface(for: background, in: .window(b.id))
        surface.receiveLead(false)
        session.claimed = []

        state.claimLeadershipForKeyWindow()

        #expect(!session.claimed.contains(surface.id))
    }

    @Test
    func one_window_state_per_nswindow() {
        // SwiftUI instantiates a view — and its @State — more than once per
        // real window, so two instances each proposed their own WindowState
        // and the app grew a phantom window on every launch. The NSWindow is
        // the only thing that is genuinely one-per-window.
        let state = makeAppState()
        let nsWindow = NSWindow()
        let first = WindowState()
        let second = WindowState()

        let a = state.canonicalWindowState(for: nsWindow, proposed: first)
        let b = state.canonicalWindowState(for: nsWindow, proposed: second)

        #expect(a === first)
        #expect(b === first)
        #expect(state.windows.count == 1)

        state.forgetWindowState(for: nsWindow)
        #expect(state.windows.isEmpty)
    }

    @Test
    func distinct_nswindows_get_distinct_states() {
        let state = makeAppState()
        let one = NSWindow()
        let two = NSWindow()

        let a = state.canonicalWindowState(for: one, proposed: WindowState())
        let b = state.canonicalWindowState(for: two, proposed: WindowState())

        #expect(a !== b)
        #expect(state.windows.count == 2)
    }

    @Test
    func a_window_on_the_pinned_workspace_follows_its_active_tab() throws {
        // Cmd+T on a pinned tab created the tab and the sidebar selected it,
        // but the window kept rendering the old one: a per-window record for
        // the sentinel (seeded by the restore paths) was read by
        // `selectedTab` while nothing maintained it — the workspace hook,
        // reconcile and align all skip the pinned workspace.
        let state = makeAppState()
        state.sessionClient = .noop
        state.incubatePane = { _ in }
        _ = try seedProject(state, tabs: 1)
        state.ensurePinnedWorkspace()
        // Through AppState so the tabs get pinned records (selection is
        // record-aware), as Cmd+T's `createTab` does.
        let first = try #require(state.createTab(projectID: PinnedTabs.workspaceID, projectPath: "/tmp"))
        let window = WindowState(activeProjectID: PinnedTabs.workspaceID)
        state.registerWindow(window)
        state.noteKeyWindow(window)
        window.activeTabIDs[PinnedTabs.workspaceID] = first

        let created = try #require(state.createTab(projectID: PinnedTabs.workspaceID, projectPath: "/tmp"))

        #expect(state.selectedTab(for: PinnedTabs.workspaceID, in: window)?.id == created)
        state.selectTab(first, projectID: PinnedTabs.workspaceID, in: window)
        #expect(state.selectedTab(for: PinnedTabs.workspaceID, in: window)?.id == first)
    }

    @Test
    func restoring_a_window_on_the_pinned_workspace_records_no_tab_for_it() async throws {
        // The pinned selection is restored through the workspace
        // (`pinnedActiveTabID`); the window snapshot's copy of it must not
        // become a stale per-window record.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.sessionClient = .noop
        writer.incubatePane = { _ in }
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        writer.ensurePinnedWorkspace()
        let firstPinned = try #require(writer.createTab(projectID: PinnedTabs.workspaceID, projectPath: "/tmp"))
        _ = try #require(writer.createTab(projectID: PinnedTabs.workspaceID, projectPath: "/tmp"))
        writer.selectTab(firstPinned, projectID: PinnedTabs.workspaceID)
        let w = WindowState(activeProjectID: PinnedTabs.workspaceID)
        writer.registerWindow(w)
        writer.noteKeyWindow(w)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.sessionClient = .noop
        reader.incubatePane = { _ in }
        reader.restoreSelection(projects: [p])
        await reader.materializeRestoredPinnedTabs()
        let restored = WindowState()
        reader.registerWindow(restored)
        reader.noteKeyWindow(restored)
        reader.restoreWindows(adopting: restored)

        #expect(restored.activeProjectID == PinnedTabs.workspaceID)
        #expect(restored.activeTabIDs[PinnedTabs.workspaceID] == nil)
        let pinned = try #require(reader.pinnedWorkspace)
        #expect(pinned.tabs.count == 2)
        #expect(reader.selectedTab(for: PinnedTabs.workspaceID, in: restored)?.id == pinned.activeTabID)

        let created = ModelWriter.tabCreate(in: pinned, projectPath: "/tmp")
        #expect(reader.selectedTab(for: PinnedTabs.workspaceID, in: restored)?.id == created.id)
    }

    // MARK: - Project screen (0362)

    /// A project with two tabs in a key window, the second tab shown. A
    /// project selection warms the other tab, so no real surface is made in
    /// the test host.
    private func keyWindowOnTwoTabs(_ state: AppState) throws -> (Project, Workspace, WindowState) {
        state.incubatePane = { _ in }
        let (project, ws) = try seedProject(state, tabs: 2)
        let window = WindowState(activeProjectID: project.id)
        state.registerWindow(window)
        state.noteKeyWindow(window)
        state.selectTab(ws.tabs[1].id, projectID: project.id, in: window)
        return (project, ws, window)
    }

    @Test
    func a_project_row_shows_the_project_screen_also_when_the_project_has_tabs() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)

        state.showProjectScreen(project, in: window)

        #expect(window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) == nil, "the window shows no tab")
        #expect(state.keyWindowShowsProjectScreen)
        #expect(ws.activeTabID == ws.tabs[1].id, "the workspace keeps the tab that the screen replaced")
        #expect(ws.tabs.count == 2, "the tabs stay")
    }

    /// The palette row of `project`, run as the palette runs it.
    private func runPaletteRow(of project: Project, in state: AppState) throws {
        let store = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-store-\(UUID().uuidString).json"))
        store.add(project)
        let item = try #require(ProjectSource().items(
            query: project.name,
            context: PaletteContext(appState: state, projectStore: store)
        ).first)
        item.action()
    }

    @Test
    func a_palette_project_row_shows_the_last_tab_of_the_project() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        let other = Project(name: "q", path: "/tmp", sortOrder: 1)
        state.selectProject(other, in: window)
        // The workspace's active tab moves while the window is away, so the
        // window's own record and the workspace disagree.
        ModelWriter.tabSelect(ws.tabs[0].id, in: ws)

        try runPaletteRow(of: project, in: state)

        #expect(window.activeProjectID == project.id)
        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) === ws.tabs[1], "the tab the window last showed")
    }

    @Test
    func a_palette_project_row_ends_the_project_screen_of_the_same_project() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)

        try runPaletteRow(of: project, in: state)

        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) === ws.tabs[1])
    }

    @Test
    func a_palette_project_row_shows_the_project_screen_of_a_project_with_no_tabs() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        for tab in ws.tabs {
            state.closeTab(tab.id, projectID: project.id)
        }
        #expect(ws.tabs.isEmpty)
        let other = Project(name: "q", path: "/tmp", sortOrder: 1)
        state.selectProject(other, in: window)

        try runPaletteRow(of: project, in: state)

        #expect(window.activeProjectID == project.id)
        #expect(state.selectedTab(for: project.id, in: window) == nil, "the window shows EmptyProjectView")
        #expect(ws.tabs.isEmpty, "the palette makes no tab")
    }

    @Test
    func a_sidebar_project_row_still_shows_the_project_screen_after_a_palette_switch() throws {
        let state = makeAppState()
        let (project, _, window) = try keyWindowOnTwoTabs(state)
        try runPaletteRow(of: project, in: state)

        state.showProjectScreen(project, in: window)

        #expect(window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) == nil)
    }

    @Test
    func tab_and_pane_commands_do_nothing_on_the_project_screen() throws {
        let state = makeAppState()
        let (project, _, window) = try keyWindowOnTwoTabs(state)
        let ctx = AppCommandContext(
            appState: state,
            projectStore: ProjectStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-window-tests-store-\(UUID().uuidString).json"))
        )
        _ = ctx.projectStore.add(project)
        #expect(AppCommand.remove.action(in: ctx) != nil)

        state.showProjectScreen(project, in: window)

        // Remove acts on the project there (design 013 §2.1), never on the
        // tab that the screen hides.
        let remove = try #require(AppCommand.remove.action(in: ctx))
        remove()
        #expect(state.pendingDialog?.kind == .removeProject(project.id), "no hidden tab closes")
        #expect(state.workspaces[project.id]?.tabs.count == 2)
        #expect(AppCommand.closePane.action(in: ctx) == nil)
        #expect(AppCommand.splitRight.action(in: ctx) == nil)
        #expect(AppCommand.newTab.action(in: ctx) != nil, "New Tab still works")
        #expect(AppCommand.recentTab.action(in: ctx) != nil)
    }

    @Test
    func selecting_a_tab_ends_the_project_screen() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)

        state.selectTab(ws.tabs[0].id, projectID: project.id)

        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) === ws.tabs[0])
    }

    @Test
    func selecting_the_tab_that_the_screen_replaced_ends_the_project_screen() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)

        state.selectTab(ws.tabs[1].id, projectID: project.id, in: window)

        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) === ws.tabs[1])
    }

    @Test
    func a_new_tab_ends_the_project_screen_and_a_background_new_tab_does_not() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)

        _ = try #require(state.createTab(projectID: project.id, projectPath: "/tmp", focus: false))
        #expect(window.showsProjectScreen, "tab new --no-focus leaves the screen")

        let id = try #require(state.createTab(projectID: project.id, projectPath: "/tmp"))
        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window)?.id == id)
        #expect(ws.activeTabID == id)
    }

    @Test
    func another_project_clears_the_project_screen() throws {
        let state = makeAppState()
        let (project, _, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)
        let other = Project(name: "q", path: "/tmp", sortOrder: 1)

        state.selectProject(other, in: window)

        #expect(window.activeProjectID == other.id)
        #expect(!window.showsProjectScreen, "a window that moves to a project for another reason shows a tab")
    }

    @Test
    func next_project_back_to_a_project_shows_the_tab_the_screen_replaced() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)
        let other = Project(name: "q", path: "/tmp", sortOrder: 1)
        state.selectProject(other, in: window)

        state.selectProject(project, in: window)

        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) === ws.tabs[1])
        #expect(ws.activeTabID == ws.tabs[1].id)
    }

    @Test
    func the_project_screen_of_a_background_window_leaves_the_key_windows_tab() throws {
        let state = makeAppState()
        let (project, ws, key) = try keyWindowOnTwoTabs(state)
        let other = WindowState(activeProjectID: project.id)
        state.registerWindow(other)

        state.showProjectScreen(project, in: other)

        #expect(other.showsProjectScreen)
        #expect(!state.keyWindowShowsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: other) == nil)
        #expect(state.selectedTab(for: project.id, in: key) === ws.tabs[1])

        state.selectTab(ws.tabs[0].id, projectID: project.id, in: other)
        #expect(!other.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: other) === ws.tabs[0])
    }

    @Test
    func recent_tab_from_the_project_screen_shows_the_tab_the_screen_replaced() throws {
        let state = makeAppState()
        let (project, ws, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)

        state.cycleRecentTab(projectID: project.id)

        #expect(!window.showsProjectScreen)
        #expect(state.selectedTab(for: project.id, in: window) === ws.tabs[1])
    }

    @Test
    func a_new_window_opens_on_the_project_screen_the_key_window_shows() throws {
        let state = makeAppState()
        let (project, _, window) = try keyWindowOnTwoTabs(state)
        state.showProjectScreen(project, in: window)

        let other = WindowState()
        state.registerWindow(other)

        #expect(other.activeProjectID == project.id)
        #expect(other.showsProjectScreen)
    }

    @Test
    func the_project_screen_and_the_tab_behind_it_survive_a_relaunch() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        let (project, ws, window) = try keyWindowOnTwoTabs(writer)
        let behind = ws.tabs[1].id
        writer.showProjectScreen(project, in: window)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.incubatePane = { _ in }
        reader.restoreSelection(projects: [project])
        let first = WindowState()
        reader.restoreWindows(adopting: first)
        reader.registerWindow(first)
        reader.noteKeyWindow(first)

        #expect(first.activeProjectID == project.id)
        #expect(first.showsProjectScreen)
        #expect(reader.selectedTab(for: project.id, in: first) == nil)
        #expect(reader.workspaces[project.id]?.activeTabID == behind)

        reader.cycleRecentTab(projectID: project.id)
        #expect(reader.selectedTab(for: project.id, in: first)?.id == behind)
    }
}

/// The palette's screens (`PaletteScope`) on the window the user is in.
@MainActor
struct PaletteScopeWindowTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projects)
        )
    }

    @Test
    func a_screens_chord_opens_it_switches_to_it_and_closes_it() {
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)

        state.toggleCommandPalette(scope: .passwords)
        #expect(window.isCommandPaletteVisible)
        #expect(window.paletteScope == .passwords)

        state.toggleCommandPalette(scope: .passwords)
        #expect(!window.isCommandPaletteVisible, "pressed again on its own screen, it closes")

        // Up on the root with a search typed: the chord switches screens and
        // starts that screen's search empty.
        state.commandPaletteQuery = "split"
        state.openCommandPalette(scope: nil)
        state.toggleCommandPalette(scope: .passwords)
        #expect(window.isCommandPaletteVisible)
        #expect(window.paletteScope == .passwords)
        #expect(state.commandPaletteQuery.isEmpty)
    }

    @Test
    func screens_stack_and_pop_back_through_their_frames() {
        let window = WindowState()
        #expect(window.paletteScope == nil)

        window.pushPaletteFrame(PaletteFrame(.passwords))
        window.pushPaletteFrame(PaletteFrame(.files))
        window.pushPaletteFrame(PaletteFrame(.files, pill: PalettePill(title: "feature", icon: "tag")))
        #expect(window.paletteStack.map(\.scopeID) == [.passwords, .files, .files])
        #expect(
            window.paletteStack.map(\.pill.title) == ["Password Manager", "Files", "feature"],
            "a frame is named by its own pill unless the row that opened it says otherwise"
        )
        #expect(window.paletteScope == .files)
        #expect(window.paletteStack[1] != window.paletteStack[2], "two frames of one scope are two frames")

        window.popPaletteFrame()
        #expect(window.paletteStack.count == 2)

        window.popPaletteFrames(above: 2)
        #expect(window.paletteStack.count == 2, "an index past the top pops nothing")
        window.popPaletteFrames(above: 0)
        #expect(window.paletteStack.map(\.scopeID) == [.passwords], "a pill click keeps its own frame")

        window.popPaletteFrame()
        window.popPaletteFrame()
        #expect(window.paletteStack.isEmpty, "popping the root is nothing")
    }

    @Test
    func a_screens_chord_replaces_a_nested_stack_with_that_screen_alone() {
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)

        window.pushPaletteFrame(PaletteFrame(.files))
        window.pushPaletteFrame(PaletteFrame(.passwords))
        state.commandPaletteQuery = "prod"
        state.openCommandPalette(scope: .passwords)
        #expect(window.paletteStack.map(\.scopeID) == [.passwords], "the screen asked for, from the root")
        #expect(state.commandPaletteQuery.isEmpty, "a different stack is a different search")

        // Already alone on that screen: the chord leaves the search typed.
        state.commandPaletteQuery = "prod"
        state.openCommandPalette(scope: .passwords)
        #expect(state.commandPaletteQuery == "prod")

        window.resetPaletteStack()
        #expect(window.paletteStack.isEmpty)
    }

    @Test
    func password_manager_is_a_bindable_command_that_is_a_palette_screen() {
        #expect(AppCommand.passwordManager.hotkeyAction == .passwordManager)
        #expect(HotkeyAction.passwordManager.appCommand == .passwordManager)
        #expect(HotkeyAction.passwordManager.defaultShortcut == "none")
    }
}
