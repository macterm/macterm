import Foundation
@testable import Macterm
import Testing

/// Scratch tabs (#665): the sentinel workspace, creation in home, moves in and
/// out of projects, a close that removes, and the snapshot round trip.
@MainActor
struct ScratchTabsTests {
    // MARK: - Setup helpers

    /// An AppState over a test server, with a no-op session client (a test
    /// must never reap the developer's live sessions).
    private func makeState() -> AppState {
        let state = TestModel.appState()
        state.sessionClient = .noop
        state.incubatePane = { _ in }
        return state
    }

    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        TestModel.project(state, name: name, path: path)
    }

    /// The scratch project's tabs, read live.
    private func scratch(_ state: AppState) -> LiveTabs? {
        state.scratchProjectID.flatMap { state.liveTabs[$0] }
    }

    // MARK: - Identity

    @Test
    func the_scratch_project_is_hidden_below_the_tree_and_not_the_pinned_one() {
        let scratch = ScratchTabs.newProject()
        let pinned = PinnedTabs.newProject()
        #expect(ScratchTabs.alias != PinnedTabs.alias)
        #expect(scratch.alias == ScratchTabs.alias)
        #expect(scratch.name == ScratchTabs.displayName)
        #expect(scratch.sidebar == .bottom)
        #expect(!scratch.isTreeProject)
        #expect(scratch.isSelectable)
        #expect(!scratch.hasFolder)
        #expect(pinned.sidebar == .top)
        #expect(scratch.id != pinned.id)
    }

    @Test
    func reserves_both_spellings_in_any_case_and_padding_only() {
        for name in ["Scratch Tabs", "scratch tabs", "SCRATCH TABS", " Scratch Tabs ", "scratch", "Scratch", "\tSCRATCH\n"] {
            #expect(ScratchTabs.reservesName(name), "\(name)")
            #expect(Project.reservesName(name), "\(name)")
        }
        for name in ["", "Scratch Tabs 2", "Scratchy", "tabs", "Pinned Tabs"] {
            #expect(!ScratchTabs.reservesName(name), "\(name)")
        }
        // The pinned name still goes through the shared test.
        #expect(Project.nameRefusal(for: "Pinned") == PinnedTabs.reservedNameMessage)
        #expect(Project.nameRefusal(for: "scratch") == ScratchTabs.reservedNameMessage)
        #expect(Project.nameRefusal(for: "api") == nil)
        #expect(Project.nameRefusal(for: "Work/api") == Project.slashMessage)
    }

    // MARK: - Creation

    @Test
    func createScratchTab_makes_the_workspace_with_one_tab_in_home_and_selects_it() throws {
        let state = makeState()
        #expect(state.scratchProjectID == nil)
        #expect(!state.hasScratchTabs)

        let id = try #require(state.createScratchTab())

        let ws = try #require(scratch(state))
        let scratchID = try #require(state.scratchProjectID)
        #expect(ws.tabs.map(\.id) == [id])
        #expect(ws.activeTabID == id)
        #expect(state.hasScratchTabs)
        #expect(state.activeProjectID == scratchID)
        let pane = try #require(ws.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.projectID == scratchID)
        #expect(pane.projectPath == ProjectPath.currentHome)
    }

    @Test
    func the_command_applies_without_a_project_where_newTab_does_not() throws {
        let state = makeState()
        let store = TestModel.projectStore(state)
        let ctx = AppCommandContext(appState: state, projectStore: store)
        #expect(state.activeProjectID == nil)
        // New Tab keeps its rule: nothing to act on without a project.
        #expect(AppCommand.newTab.action(in: ctx) == nil)

        let action = try #require(AppCommand.newScratchTab.action(in: ctx))
        action()

        #expect(scratch(state)?.tabs.count == 1)
        #expect(state.activeProjectID == state.scratchProjectID)
        #expect(HotkeyAction.newScratchTab.defaultShortcut == "cmd+shift+t")
    }

    @Test
    func createScratchTab_without_focus_keeps_the_active_project() throws {
        let state = makeState()
        let p = seedProject(state)

        let id = try #require(state.createScratchTab(focus: false))

        #expect(state.activeProjectID == p.id)
        #expect(scratch(state)?.tabs.map(\.id) == [id])
    }

    @Test
    func ensureScratchProject_starts_empty() {
        let state = makeState()
        #expect(state.ensureScratchProject() != nil)
        #expect(scratch(state)?.tabs.isEmpty == true)
        #expect(!state.hasScratchTabs)
    }

    @Test
    func selectScratchTabs_selects_the_workspace_and_its_first_tab() throws {
        let state = makeState()
        let id = try #require(state.createScratchTab(focus: false))
        let scratchID = try #require(state.scratchProjectID)
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)

        state.selectScratchTabs()

        #expect(state.activeProjectID == scratchID)
        #expect(scratch(state)?.activeTabID == id)
    }

    // MARK: - Moves

    @Test
    func moveTabToScratchTabs_rebinds_the_panes_and_leaves_the_project() throws {
        let state = makeState()
        let p = seedProject(state)
        let tab = try #require(state.liveTabs[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let cwd = pane.projectPath

        state.moveTabToScratchTabs(tab.id, from: p.id)
        let scratchID = try #require(state.scratchProjectID)

        #expect(state.liveTabs[p.id]?.tabs.isEmpty == true)
        #expect(scratch(state)?.tabs.map(\.id) == [tab.id])
        #expect(pane.projectID == scratchID)
        // The tab keeps its own working directory; only its row moves.
        #expect(pane.projectPath == cwd)
        #expect(state.activeProjectID == scratchID)
        #expect(state.pinnedRecords.isEmpty)
    }

    @Test
    func moveTab_from_scratch_into_a_project_is_a_plain_move() throws {
        let state = makeState()
        let p = seedProject(state)
        let id = try #require(state.createScratchTab())
        let scratchID = try #require(state.scratchProjectID)
        let pane = try #require(scratch(state)?.tabs.first?.splitRoot.allPanes().first)

        state.moveTab(id, from: scratchID, to: p.id, destPath: p.path)

        #expect(scratch(state)?.tabs.isEmpty == true)
        #expect(state.liveTabs[p.id]?.tabs.map(\.id).contains(id) == true)
        #expect(pane.projectID == p.id)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func pinning_a_scratch_tab_records_its_origin_and_unpin_returns_it() throws {
        let state = makeState()
        let id = try #require(state.createScratchTab())
        let scratchID = try #require(state.scratchProjectID)

        state.pinTab(id, fromProject: scratchID)
        #expect(state.pinnedRecords.map(\.id) == [id])
        #expect(state.pinnedRecords.first?.originProjectID == scratchID)
        #expect(scratch(state)?.tabs.isEmpty == true)

        state.unpinTab(id, projects: [])
        #expect(state.pinnedRecords.isEmpty)
        #expect(scratch(state)?.tabs.map(\.id) == [id])
        #expect(state.activeProjectID == scratchID)
    }

    @Test
    func unpin_with_no_project_and_no_scratch_origin_lands_in_the_scratch_workspace() throws {
        let state = makeState()
        let p = seedProject(state)
        let tab = try #require(state.liveTabs[p.id]?.activeTab)
        state.pinTab(tab.id, fromProject: p.id)

        // The origin project is gone, and no other project is left: the
        // scratch project is where every tab can live.
        state.removeProject(p.id)
        #expect(state.model.project(p.id) == nil)
        state.unpinTab(tab.id, projects: [])

        #expect(state.pinnedRecords.isEmpty)
        #expect(scratch(state)?.tabs.map(\.id) == [tab.id])
    }

    // MARK: - Close

    @Test
    func closing_a_scratch_tab_removes_it_and_keeps_the_workspace() throws {
        let state = makeState()
        let first = try #require(state.createScratchTab())
        let second = try #require(state.createScratchTab())
        let scratchID = try #require(state.scratchProjectID)

        state.closeTab(second, projectID: scratchID)
        #expect(scratch(state)?.tabs.map(\.id) == [first])

        state.closeTab(first, projectID: scratchID)
        #expect(scratch(state)?.tabs.isEmpty == true)
        #expect(!state.hasScratchTabs)
        // Still the active workspace: the sidebar keeps the rows' place
        // while the user is there, and Cmd+T makes a new scratch tab.
        #expect(state.activeProjectID == scratchID)
    }

    // MARK: - Guards

    @Test
    func the_scratch_workspace_is_never_removed() throws {
        let state = makeState()
        let id = try #require(state.createScratchTab())
        let scratchID = try #require(state.scratchProjectID)

        state.removeProject(scratchID)
        #expect(scratch(state)?.tabs.map(\.id) == [id])
    }

    @Test
    func configuredProjectDirectory_is_home_for_the_scratch_workspace() throws {
        let state = makeState()
        let scratchID = try #require(state.ensureScratchProject())
        #expect(state.configuredProjectDirectory(projectID: scratchID, projects: []) == ProjectPath.currentHome)
    }

    // MARK: - Persistence

    @Test
    func scratch_tabs_survive_a_relaunch_without_a_project() throws {
        let gui = GUIStateStore(fileURL: TestModel.folder("scratch").appending(path: "gui-state.json"))
        let writer = TestModel.appState(guiStateStore: gui)
        writer.sessionClient = .noop
        writer.incubatePane = { _ in }
        let id = try #require(writer.createScratchTab())
        let scratchID = try #require(writer.scratchProjectID)
        let session = try #require(scratch(writer)?.tabs.first?.splitRoot.allPanes().first?.sessionName)
        writer.persistState()

        let reader = TestModel.relaunch(writer, guiStateStore: gui)
        reader.sessionClient = .noop
        reader.restoreSelection(projects: [])

        #expect(reader.scratchProjectID == scratchID)
        let ws = try #require(scratch(reader))
        #expect(ws.tabs.map(\.id) == [id])
        #expect(ws.activeTabID == id)
        let pane = try #require(ws.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.sessionName == session)
        #expect(pane.projectID == scratchID)
    }

    @Test
    func restore_lands_on_the_scratch_project_only_while_it_has_tabs() throws {
        let priorActive = Preferences.shared.activeProjectID
        defer { Preferences.shared.activeProjectID = priorActive }
        let gui = GUIStateStore(fileURL: TestModel.folder("scratch").appending(path: "gui-state.json"))

        let writer = TestModel.appState(guiStateStore: gui)
        writer.sessionClient = .noop
        writer.incubatePane = { _ in }
        let id = try #require(writer.createScratchTab())
        let scratchID = try #require(writer.scratchProjectID)
        writer.persistState()
        Preferences.shared.activeProjectID = scratchID

        let reader = TestModel.relaunch(writer, guiStateStore: gui)
        reader.sessionClient = .noop
        reader.restoreSelection(projects: [])
        #expect(reader.activeProjectID == scratchID)
        #expect(scratch(reader)?.activeTabID == id)

        // Every scratch tab closed, then quit: the next launch selects nothing.
        writer.closeTab(id, projectID: scratchID)
        writer.persistState()
        Preferences.shared.activeProjectID = scratchID
        let empty = TestModel.relaunch(writer, guiStateStore: gui)
        empty.sessionClient = .noop
        empty.restoreSelection(projects: [])
        #expect(empty.activeProjectID == nil)
        #expect(scratch(empty)?.tabs.isEmpty == true)
    }
}
