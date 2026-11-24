import Foundation
@testable import Macterm
import Testing

/// The Move Into Project screen (`MoveIntoProjectInput`) and the three
/// project tree commands that act on the active project.
@MainActor
struct MoveIntoProjectInputTests {
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

        func input() -> PaletteInput {
            MoveIntoProjectInput.make(projectID: moving.id, appState: state, store: store)
        }
    }

    private func makeFixture() -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json")),
            projectFiles: ProjectFileStore(
                directoryURL: tmp.appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let store = ProjectStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json"))
        let work = store.create(name: "Work", path: "/tmp")
        let api = store.create(name: "api", path: "/tmp", parent: work.id)
        let moving = store.create(name: "Home", path: "/tmp")
        state.selectProject(moving)
        return Fixture(state: state, store: store, work: work, api: api, moving: moving)
    }

    private func titles(_ completions: [PaletteCompletion]) -> [String] {
        completions.map(\.title)
    }

    // MARK: - The screen

    @Test
    func an_empty_field_lists_every_target_by_its_path() {
        let f = makeFixture()
        #expect(titles(f.input().completions("")) == ["Work", "Work/api"])
        if case .nothing = f.input().check("") {} else { Issue.record("an empty field gives nothing") }
    }

    @Test
    func typed_text_filters_the_targets() {
        let f = makeFixture()
        #expect(titles(f.input().completions("ap")) == ["Work/api"])
    }

    @Test
    func a_full_path_gives_the_action_row_and_moves_the_project() {
        let f = makeFixture()
        guard case let .action(row) = f.input().check("Work/api/") else {
            Issue.record("a path of one target gives the action row")
            return
        }
        #expect(row.title == "Move into “Work/api”")
        #expect(row.run() == .done)
        #expect(f.store.row(f.moving.id)?.parent == f.api.id)
    }

    @Test
    func a_path_that_names_no_project_gives_a_notice() {
        let f = makeFixture()
        guard case let .notice(text) = f.input().check("Nowhere") else {
            Issue.record("a path of no project gives a notice")
            return
        }
        #expect(text == "No project has this path.")
    }

    @Test
    func a_project_cannot_move_into_itself_or_its_parent() {
        let f = makeFixture()
        let inside = MoveIntoProjectInput.make(projectID: f.api.id, appState: f.state, store: f.store)
        guard case let .notice(parent) = inside.check("Work") else {
            Issue.record("the parent is no target")
            return
        }
        #expect(parent == "The project is already inside “Work”.")
        let outer = MoveIntoProjectInput.make(projectID: f.work.id, appState: f.state, store: f.store)
        guard case let .notice(own) = outer.check("Work/api") else {
            Issue.record("a project inside it is no target")
            return
        }
        #expect(own == "A project cannot move into itself or into a project inside it.")
    }

    @Test
    func the_path_matches_in_any_letter_case() {
        let f = makeFixture()
        guard case let .action(row) = f.input().check("work/API") else {
            Issue.record("a path in other letter case gives the action row")
            return
        }
        #expect(row.title == "Move into “Work/api”")
    }

    @Test
    func a_project_of_the_same_path_that_is_no_target_does_not_block_the_target() {
        let f = makeFixture()
        // Two top-level projects named "Twin": the moving one is no target
        // of its own move, so "Twin" names one target.
        let moving = f.store.create(name: "Twin", path: "/tmp")
        let other = f.store.create(name: "Twin", path: "/tmp")
        let input = MoveIntoProjectInput.make(projectID: moving.id, appState: f.state, store: f.store)
        guard case let .action(row) = input.check("Twin") else {
            Issue.record("the one target gives the action row")
            return
        }
        #expect(row.run() == .done)
        #expect(f.store.row(moving.id)?.parent == other.id)
    }

    @Test
    func two_projects_with_one_path_give_a_notice() {
        let f = makeFixture()
        _ = f.store.create(name: "api", path: "/tmp", parent: f.work.id)
        guard case let .notice(text) = f.input().check("Work/api") else {
            Issue.record("an ambiguous path gives a notice")
            return
        }
        #expect(text == "More than one project has this path. Rename one of them.")
    }

    // MARK: - The commands

    @Test
    func a_top_level_project_has_no_move_out() {
        let f = makeFixture()
        #expect(AppCommand.newProjectInside.action(in: f.ctx) != nil)
        #expect(AppCommand.moveIntoProject.action(in: f.ctx) != nil)
        #expect(AppCommand.moveOutOfProject.action(in: f.ctx) == nil)
        let titles = CommandSource().emptyItems(context: f.palette)?.map(\.title) ?? []
        #expect(!titles.contains(AppCommand.moveOutOfProject.title))
    }

    @Test
    func move_into_project_opens_its_screen_from_the_palette() throws {
        let f = makeFixture()
        let row = try #require(CommandSource().emptyItems(context: f.palette)?.first { $0.title == AppCommand.moveIntoProject.title })
        guard case let .input(input)? = row.opensScope else {
            Issue.record("the row opens the input screen")
            return
        }
        #expect(input.id == f.input().id)
    }

    @Test
    func move_into_project_is_off_with_no_target() {
        let f = makeFixture()
        let tmp = FileManager.default.temporaryDirectory
        let lone = ProjectStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json"))
        let only = lone.create(name: "only", path: "/tmp")
        f.state.selectProject(only)
        #expect(AppCommand.moveIntoProject.action(in: AppCommandContext(appState: f.state, projectStore: lone)) == nil)
    }

    @Test
    func move_out_of_project_puts_the_project_beside_its_parent() throws {
        let f = makeFixture()
        f.state.selectProject(f.api)
        let run = try #require(AppCommand.moveOutOfProject.action(in: f.ctx))
        run()
        #expect(f.store.row(f.api.id)?.parent == nil)
    }

    @Test
    func a_move_opens_the_target_and_its_parents_in_the_window() {
        let f = makeFixture()
        let window = WindowState()
        #expect(f.state.moveProject(f.moving.id, into: f.api.id, store: f.store, in: window))
        #expect(window.expandedRows.isSuperset(of: [f.api.id, f.work.id]))
        #expect(!f.state.moveProject(f.work.id, into: f.api.id, store: f.store, in: window), "not into a project inside it")
    }
}
