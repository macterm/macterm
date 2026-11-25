import Foundation
@testable import Macterm
import Testing

/// The node target of commands and the one Remove of tabs and projects
/// (design 013 §2.1, §2.4): `AppState.commandTarget(store:)`,
/// `AppState.requestRemove` and `AppCommand.remove`.
@MainActor
struct CommandTargetTests {
    /// Two top-level projects, `a` and `b`, each with tabs, and a key window
    /// on the last tab of `a`. The sidebar has the focus only when
    /// `sidebarFocused` says so.
    @MainActor
    private final class Fixture {
        let state: AppState
        let store: ProjectStore
        let a: Project
        let b: Project
        let window: WindowState
        var sidebarFocused = false
        var ctx: AppCommandContext { AppCommandContext(appState: state, projectStore: store) }

        init() {
            let tmp = FileManager.default.temporaryDirectory
            state = AppState(
                workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json")),
                projectFiles: ProjectFileStore(
                    directoryURL: tmp.appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
                )
            )
            store = ProjectStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json"))
            a = store.create(name: "a", path: "/tmp/a")
            b = store.create(name: "b", path: "/tmp/b")
            state.incubatePane = { _ in }
            window = WindowState(activeProjectID: nil)
            state.registerWindow(window)
            state.noteKeyWindow(window)
            state.selectProject(b, in: window)
            state.selectProject(a, in: window)
            state.sidebarFocusProbe = { [unowned self] _ in sidebarFocused }
        }

        func tabs(of project: Project) -> [UUID] {
            state.workspaces[project.id]?.tabs.map(\.id) ?? []
        }

        @discardableResult
        func newTab(in project: Project) throws -> UUID {
            try #require(state.createTab(projectID: project.id, projects: store.projects))
        }

        /// The rows of the sidebar, in order, as `SidebarContent` publishes them.
        func publishRows() {
            window.sidebar.orderedItems = [.project(a.id)] + tabs(of: a).map { .tab(projectID: a.id, tabID: $0) }
                + [.project(b.id)] + tabs(of: b).map { .tab(projectID: b.id, tabID: $0) }
        }
    }

    // MARK: - The target

    @Test
    func the_target_is_the_shown_tab_and_on_the_project_screen_the_project() throws {
        let f = Fixture()
        let tab = try #require(f.state.selectedTab(for: f.a.id, in: f.window))
        #expect(f.state.commandTarget(store: f.store) == [.tab(projectID: f.a.id, tabID: tab.id)])

        f.state.showProjectScreen(f.a, in: f.window)
        #expect(f.state.commandTarget(store: f.store) == [.project(f.a.id)])
    }

    @Test
    func a_selection_of_more_rows_is_the_target_only_while_the_sidebar_has_the_focus() throws {
        let f = Fixture()
        let bTab = try #require(f.tabs(of: f.b).first)
        let shown = try #require(f.state.selectedTab(for: f.a.id, in: f.window))
        f.publishRows()
        f.window.sidebar.selection = [.tab(projectID: f.b.id, tabID: bTab), .project(f.a.id)]

        // A click in a terminal pane keeps the selection
        // (`SidebarContent.syncSelection` follows a change of tab or
        // project only), so with the focus in a pane the shown tab is the
        // target.
        #expect(f.state.commandTarget(store: f.store) == [.tab(projectID: f.a.id, tabID: shown.id)])

        f.sidebarFocused = true
        #expect(f.state.commandTarget(store: f.store) == [.project(f.a.id), .tab(projectID: f.b.id, tabID: bTab)],
                "the selection, in the order of the rows")
    }

    @Test
    func the_palette_records_the_target_when_it_opens() throws {
        let f = Fixture()
        let bTab = try #require(f.tabs(of: f.b).first)
        f.publishRows()
        let selection: [SidebarItem] = [.project(f.a.id), .tab(projectID: f.b.id, tabID: bTab)]
        f.window.sidebar.selection = Set(selection)
        f.sidebarFocused = true

        f.state.isCommandPaletteVisible = true
        // The palette takes the focus from the sidebar.
        f.sidebarFocused = false
        #expect(f.state.commandTarget(store: f.store) == selection)
        #expect(AppCommand.remove.title(in: f.ctx) == "Remove 2 Items")

        f.state.isCommandPaletteVisible = false
        #expect(f.window.paletteTarget == nil)
        #expect(f.state.commandTarget(store: f.store).count == 1, "the shown tab again")
    }

    @Test
    func the_rows_of_pinned_and_scratch_tabs_are_not_nodes() {
        let f = Fixture()
        f.window.sidebar.selection = [.project(PinnedTabs.workspaceID), .project(ScratchTabs.workspaceID)]
        f.sidebarFocused = true
        #expect(f.state.commandTarget(store: f.store).isEmpty)
        #expect(AppCommand.remove.action(in: f.ctx) == nil)
    }

    // MARK: - The words

    @Test
    func remove_says_close_tab_for_a_tab_and_remove_project_for_a_project() throws {
        let f = Fixture()
        #expect(AppCommand.remove.title(in: f.ctx) == "Close Tab")
        f.state.showProjectScreen(f.a, in: f.window)
        #expect(AppCommand.remove.title(in: f.ctx) == "Remove Project")
        #expect(AppCommand.remove.paletteSubtitle(in: f.ctx) == "a", "the row names the node")

        let tab = SidebarItem.tab(projectID: f.a.id, tabID: UUID())
        #expect(AppCommand.removeTitle(for: []) == nil)
        #expect(AppCommand.removeTitle(for: [tab, tab]) == "Close 2 Tabs")
        #expect(AppCommand.removeTitle(for: [.project(f.a.id), .project(f.b.id)]) == "Remove 2 Projects")
        #expect(AppCommand.removeTitle(for: [.project(f.a.id), tab]) == "Remove 2 Items")
    }

    // MARK: - Remove

    @Test
    func remove_closes_the_shown_tab() throws {
        let f = Fixture()
        let tab = try f.newTab(in: f.a)
        let remove = try #require(AppCommand.remove.action(in: f.ctx))
        remove()
        #expect(!f.tabs(of: f.a).contains(tab))
        #expect(f.store.row(f.a.id) != nil)
    }

    @Test
    func remove_on_the_project_screen_asks_with_the_counts_of_the_project() throws {
        let f = Fixture()
        f.state.showProjectScreen(f.a, in: f.window)
        let remove = try #require(AppCommand.remove.action(in: f.ctx))
        remove()
        #expect(f.state.pendingDialog?.kind == .removeProject(f.a.id))
        #expect(f.state.pendingDialog?.message == "This project contains 1 tab and 0 nested projects.")
        f.state.confirmPendingDialog()
        #expect(f.store.row(f.a.id) == nil)
    }

    @Test
    func a_mixed_set_asks_one_question_and_removes_every_node() throws {
        let f = Fixture()
        let bTabs = try [#require(f.tabs(of: f.b).first), f.newTab(in: f.b)]
        f.state.requestRemove([.project(f.a.id), .tab(projectID: f.b.id, tabID: bTabs[0])], store: f.store)

        #expect(f.state.pendingDialog?.kind == .removeSelection)
        #expect(f.state.pendingDialog?.title == "Remove the selected items?")
        #expect(f.state.pendingDialog?.message == "The selected items contain 2 tabs and 0 nested projects.",
                "the tab of a and the selected tab of b")
        #expect(f.store.row(f.a.id) != nil, "nothing goes before the answer")

        f.state.confirmPendingDialog()
        #expect(f.store.row(f.a.id) == nil)
        #expect(f.tabs(of: f.b) == [bTabs[1]])
    }

    @Test
    func a_tab_whose_project_goes_is_not_counted_or_closed_twice() throws {
        let f = Fixture()
        let aTab = try #require(f.tabs(of: f.a).first)
        f.state.requestRemove([.project(f.a.id), .tab(projectID: f.a.id, tabID: aTab)], store: f.store)

        // The set is the project alone: its own question and its own count.
        #expect(f.state.pendingDialog?.kind == .removeProject(f.a.id))
        #expect(f.state.pendingDialog?.message == "This project contains 1 tab and 0 nested projects.")
    }

    @Test
    func a_project_inside_a_selected_project_goes_with_it() {
        let f = Fixture()
        let child = f.store.create(name: "child", path: "/tmp/child", parent: f.b.id)
        f.state.requestRemove([.project(f.a.id), .project(f.b.id), .project(child.id)], store: f.store)
        #expect(f.state.pendingDialog?.message == "The selected items contain 2 tabs and 1 nested project.")
        f.state.confirmPendingDialog()
        #expect(f.store.projects.isEmpty)
    }

    @Test
    func tabs_with_no_running_process_go_at_once() throws {
        let f = Fixture()
        let first = try #require(f.tabs(of: f.a).first)
        let second = try f.newTab(in: f.a)
        f.state.requestRemove([.tab(projectID: f.a.id, tabID: first), .tab(projectID: f.a.id, tabID: second)], store: f.store)
        #expect(f.state.pendingDialog == nil)
        #expect(f.tabs(of: f.a).isEmpty)
    }

    @Test
    func a_running_process_asks_first() throws {
        let f = Fixture()
        f.state.paneNeedsConfirmClose = { _ in true }
        let first = try #require(f.tabs(of: f.a).first)
        let second = try f.newTab(in: f.a)

        f.state.requestRemove([.tab(projectID: f.a.id, tabID: first)], store: f.store)
        #expect(f.state.pendingDialog?.kind == .closeTab(tabID: first, projectID: f.a.id), "one tab: the dialog of Close Tab")
        f.state.dismissPendingDialog()

        f.state.requestRemove([.tab(projectID: f.a.id, tabID: first), .tab(projectID: f.a.id, tabID: second)], store: f.store)
        #expect(f.state.pendingDialog?.kind == .removeSelection)
        #expect(f.tabs(of: f.a).count == 2, "nothing goes before the answer")
        f.state.confirmPendingDialog()
        #expect(f.tabs(of: f.a).isEmpty)
    }

    @Test
    func removed_rows_leave_the_selection() throws {
        let f = Fixture()
        let first = try #require(f.tabs(of: f.a).first)
        let second = try f.newTab(in: f.a)
        let nodes: [SidebarItem] = [.tab(projectID: f.a.id, tabID: first), .tab(projectID: f.a.id, tabID: second)]
        f.window.sidebar.selection = Set(nodes)
        f.state.requestRemove(nodes, store: f.store)
        #expect(f.window.sidebar.selection.isDisjoint(with: nodes))
    }
}
