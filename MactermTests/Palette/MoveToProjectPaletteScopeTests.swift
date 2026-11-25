import Foundation
@testable import Macterm
import Testing

/// The Move to Project screen (`MoveToProjectPaletteScope`), for a project
/// and for a tab, and the three commands of the tree.
@MainActor
struct MoveToProjectPaletteScopeTests {
    /// A tree: Work, Work/api, Home; the active project is `moving`, at the
    /// top level.
    @MainActor
    private struct Fixture {
        let state: AppState
        let store: ProjectStore
        let work: Project
        let api: Project
        let moving: Project
        var ctx: AppCommandContext { AppCommandContext(appState: state, projectStore: store) }
        var palette: PaletteContext { PaletteContext(appState: state, projectStore: store) }

        /// The rows of the screen that moves `project` (default `moving`)
        /// for `query`.
        func rows(_ query: String, moving project: Project? = nil) -> [PaletteItem] {
            screen(.project((project ?? moving).id), query)
        }

        /// The rows of the screen that moves `node` for `query`.
        func screen(_ node: SidebarItem, _ query: String) -> [PaletteItem] {
            MoveToProjectPaletteScope(node: node)
                .sections(for: PaletteQuery(raw: query), context: palette)
                .flatMap(\.items)
        }
    }

    private func makeFixture() throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
        let state = TestModel.appState(
            projectFiles: ProjectFileStore(
                directoryURL: tmp.appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let store = TestModel.projectStore(state)
        store.onAdd = { state.projectAdded($0) }
        let work = try #require(store.create(name: "Work", path: "/tmp/work"))
        let api = try #require(store.create(name: "api", path: "/tmp/api", parent: work.id))
        let moving = try #require(store.create(name: "Home", path: "/tmp"))
        state.incubatePane = { _ in }
        state.selectProject(moving)
        return Fixture(state: state, store: store, work: work, api: api, moving: moving)
    }

    // MARK: - The screen

    @Test
    func an_empty_query_lists_every_target_by_its_path_and_nothing_else() throws {
        let f = try makeFixture()
        let rows = f.rows("")
        #expect(rows.map(\.title) == ["Work", "Work/api"])
        #expect(rows.map(\.subtitle) == ["/tmp/work", "/tmp/api"])
    }

    @Test
    func an_empty_query_keeps_the_order_of_the_projects() throws {
        let f = try makeFixture()
        _ = f.store.create(name: "lib", path: "/tmp/lib", parent: f.api.id)
        _ = f.store.create(name: "Z", path: "/tmp/z")
        #expect(f.rows("").map(\.title) == ["Work", "Work/api", "Work/api/lib", "Z"])
    }

    @Test
    func a_query_matches_the_folder_and_any_letter_case() throws {
        let f = try makeFixture()
        #expect(f.rows("/tmp/api").map(\.title) == ["Work/api"])
        #expect(f.rows("work/API").map(\.title) == ["Work/api"])
    }

    @Test
    func a_query_filters_by_name_or_path() throws {
        let f = try makeFixture()
        #expect(f.rows("ap").map(\.title) == ["Work/api"])
        #expect(f.rows("Work/api").map(\.title) == ["Work/api"])
    }

    @Test
    func a_query_that_names_no_project_gives_no_row() throws {
        let f = try makeFixture()
        #expect(f.rows("Nowhere").isEmpty)
    }

    @Test
    func a_query_shows_only_projects_never_a_row_for_the_text() throws {
        let f = try makeFixture()
        // Ethan, ui-review 0592: "Work" shows once, as the project.
        #expect(f.rows("Work").map(\.title) == ["Work", "Work/api"])
    }

    @Test
    func a_row_moves_the_project_into_it() throws {
        let f = try makeFixture()
        let row = try #require(f.rows("api").first)
        row.action()
        #expect(f.store.row(f.moving.id)?.parent == f.api.id)
    }

    @Test
    func the_project_its_parent_and_the_projects_inside_it_are_not_listed() throws {
        let f = try makeFixture()
        #expect(f.rows("", moving: f.api).map(\.title) == ["Home"])
        #expect(f.rows("", moving: f.work).map(\.title) == ["Home"])
    }

    @Test
    func two_projects_with_one_path_are_two_rows() throws {
        let f = try makeFixture()
        _ = f.store.create(name: "api", path: "/tmp/other", parent: f.work.id)
        #expect(f.rows("Work/api").map(\.subtitle) == ["/tmp/api", "/tmp/other"])
    }

    // MARK: - The commands

    @Test
    func a_top_level_project_has_no_move_out() throws {
        let f = try makeFixture()
        #expect(AppCommand.newProjectInside.action(in: f.ctx) != nil)
        #expect(AppCommand.moveToProject.action(in: f.ctx) != nil)
        #expect(AppCommand.moveOutOfProject.action(in: f.ctx) == nil)
        let titles = CommandSource().emptyItems(context: f.palette)?.map(\.title) ?? []
        #expect(!titles.contains(AppCommand.moveOutOfProject.title))
    }

    @Test
    func move_to_project_opens_its_screen_from_the_palette() throws {
        let f = try makeFixture()
        let row = try #require(CommandSource().emptyItems(context: f.palette)?.first { $0.title == AppCommand.moveToProject.title })
        let node = try #require(f.state.moveToProjectNode(store: f.store))
        #expect(row.opensScope == .moveToProject(node))
    }

    // MARK: - A tab

    /// A tab of `project`, which becomes the active project with this tab
    /// active.
    private func makeTab(_ f: Fixture, in project: Project) throws -> UUID {
        f.state.selectProject(project)
        return try #require(f.state.createTab(projectID: project.id, projects: f.store.projects))
    }

    @Test
    func a_pinned_tab_moves_to_the_project_as_an_unpin() throws {
        let f = try makeFixture()
        let tab = try makeTab(f, in: f.moving)
        f.state.pinTab(tab, fromProject: f.moving.id)
        let pinnedID = try #require(f.state.pinnedProjectID)
        #expect(f.state.moveNode(.tab(projectID: pinnedID, tabID: tab), to: f.api, store: f.store, in: nil))
        #expect(f.state.liveTabs[f.api.id]?.tabs.contains { $0.id == tab } == true)
        #expect(f.state.pinnedRecord(tab) == nil)
    }

    @Test
    func a_tab_lists_every_project_but_its_own() throws {
        let f = try makeFixture()
        let tab = try makeTab(f, in: f.api)
        #expect(f.screen(.tab(projectID: f.api.id, tabID: tab), "").map(\.title) == ["Work", "Home"])
    }

    @Test
    func a_row_moves_the_tab_to_the_project_and_opens_it() throws {
        let f = try makeFixture()
        let tab = try makeTab(f, in: f.moving)
        let window = WindowState()
        #expect(f.state.moveNode(.tab(projectID: f.moving.id, tabID: tab), to: f.api, store: f.store, in: window))
        #expect(f.state.liveTabs[f.api.id]?.tabs.contains { $0.id == tab } == true)
        #expect(f.state.liveTabs[f.moving.id]?.tabs.contains { $0.id == tab } != true)
        #expect(window.expandedRows.isSuperset(of: [f.api.id, f.work.id]))
        #expect(!f.state.moveNode(.tab(projectID: f.api.id, tabID: tab), to: f.api, store: f.store, in: window), "not into its own project")
    }

    @Test
    func the_node_is_the_shown_tab_and_on_the_project_screen_the_project() throws {
        let f = try makeFixture()
        let window = WindowState(activeProjectID: f.moving.id)
        f.state.registerWindow(window)
        f.state.noteKeyWindow(window)
        let tab = try makeTab(f, in: f.moving)
        f.state.selectTab(tab, projectID: f.moving.id, in: window)
        #expect(f.state.moveToProjectNode(store: f.store) == .tab(projectID: f.moving.id, tabID: tab))
        f.state.showProjectScreen(f.moving, in: window)
        #expect(f.state.moveToProjectNode(store: f.store) == .project(f.moving.id))
        let row = try #require(CommandSource().emptyItems(context: f.palette)?.first { $0.title == AppCommand.moveToProject.title })
        #expect(row.opensScope == .moveToProject(.project(f.moving.id)))
    }

    // MARK: - When the commands apply

    @Test
    func move_to_project_is_off_with_no_target() throws {
        let f = try makeFixture()
        // A model of its own, with one project: no other project to move to.
        let state = TestModel.appState()
        let lone = TestModel.projectStore(state)
        let only = try #require(lone.create(name: "only", path: "/tmp"))
        state.selectProject(only)
        #expect(AppCommand.moveToProject.action(in: AppCommandContext(appState: state, projectStore: lone)) == nil)
    }

    @Test
    func move_out_of_project_puts_the_project_beside_its_parent() throws {
        let f = try makeFixture()
        f.state.selectProject(f.api)
        let run = try #require(AppCommand.moveOutOfProject.action(in: f.ctx))
        run()
        #expect(f.store.row(f.api.id)?.parent == nil)
    }

    @Test
    func a_move_opens_the_target_and_its_parents_in_the_window() throws {
        let f = try makeFixture()
        let window = WindowState()
        #expect(f.state.moveProject(f.moving.id, into: f.api.id, store: f.store, in: window))
        #expect(window.expandedRows.isSuperset(of: [f.api.id, f.work.id]))
        #expect(!f.state.moveProject(f.work.id, into: f.api.id, store: f.store, in: window), "not into a project inside it")
    }
}
