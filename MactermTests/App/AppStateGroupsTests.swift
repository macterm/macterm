import Foundation
@testable import Macterm
import Testing

/// The group commands (New Group, Move to Group, Move Out of Group, Ungroup,
/// Remove Group): when each applies to the active project, and what it does.
@MainActor
struct AppStateGroupsTests {
    @MainActor
    private struct Fixture {
        let state: AppState
        let store: ProjectStore
        let project: Project
        var ctx: AppCommandContext { AppCommandContext(appState: state, projectStore: store) }
        var palette: PaletteContext { PaletteContext(appState: state, projectStore: store) }
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
        let project = Project(name: "proj", path: "/tmp", sortOrder: 0)
        store.add(project)
        state.selectProject(project)
        return Fixture(state: state, store: store, project: project)
    }

    @Test
    func a_top_level_project_has_no_group_commands_but_new_group() {
        let f = makeFixture()
        #expect(AppCommand.newGroup.action(in: f.ctx) != nil)
        #expect(AppCommand.moveToGroup.action(in: f.ctx) == nil, "no group to move into")
        #expect(AppCommand.moveOutOfGroup.action(in: f.ctx) == nil)
        #expect(AppCommand.ungroup.action(in: f.ctx) == nil)
        #expect(AppCommand.removeGroup.action(in: f.ctx) == nil)
    }

    @Test
    func new_group_goes_beside_the_active_project() throws {
        let f = makeFixture()
        let run = try #require(AppCommand.newGroup.action(in: f.ctx))
        run()
        #expect(f.store.groups.count == 1)
        #expect(f.store.children(of: nil).map(\.id) == [f.project.id, f.store.groups[0].id])
    }

    @Test
    func move_to_group_lists_the_groups_and_moves_the_project() {
        let f = makeFixture()
        let group = f.store.createGroup(name: "work")
        #expect(AppCommand.moveToGroup.action(in: f.ctx) != nil)

        let rows = MoveToGroupPaletteScope().sections(for: PaletteQuery(raw: ""), context: f.palette).flatMap(\.items)
        #expect(rows.map(\.title) == ["work"])
        #expect(MoveToGroupPaletteScope().sections(for: PaletteQuery(raw: "zzz"), context: f.palette).isEmpty)

        rows[0].action()
        #expect(f.store.row(f.project.id)?.parent == group.id)
        // Its own group is no target, so with one group there is none left.
        #expect(AppCommand.moveToGroup.action(in: f.ctx) == nil)
    }

    @Test
    func move_out_takes_the_project_out_of_its_group() throws {
        let f = makeFixture()
        let group = f.store.createGroup(name: "work")
        f.store.move(f.project.id, into: group.id)
        let run = try #require(AppCommand.moveOutOfGroup.action(in: f.ctx))
        run()
        #expect(f.store.row(f.project.id)?.parent == nil)
        #expect(f.store.row(group.id) != nil)
    }

    @Test
    func ungroup_removes_the_group_of_the_active_project_and_keeps_the_project() throws {
        let f = makeFixture()
        let group = f.store.createGroup(name: "work")
        f.store.move(f.project.id, into: group.id)
        let run = try #require(AppCommand.ungroup.action(in: f.ctx))
        run()
        #expect(f.store.row(group.id) == nil)
        #expect(f.store.row(f.project.id)?.parent == nil)
    }

    @Test
    func remove_group_asks_before_it_removes_the_projects_inside() throws {
        let f = makeFixture()
        let group = f.store.createGroup(name: "work")
        f.store.move(f.project.id, into: group.id)
        let run = try #require(AppCommand.removeGroup.action(in: f.ctx))
        run()
        #expect(f.store.row(group.id) != nil, "nothing goes before the confirm")
        f.state.confirmPendingDialog()
        #expect(f.store.row(group.id) == nil)
        #expect(f.store.row(f.project.id) == nil)
    }

    @Test
    func the_palette_hides_a_group_command_that_does_not_apply() {
        let f = makeFixture()
        let titles = CommandSource().emptyItems(context: f.palette)?.map(\.title) ?? []
        #expect(titles.contains(AppCommand.newGroup.title))
        #expect(!titles.contains(AppCommand.moveOutOfGroup.title))
        #expect(!titles.contains(AppCommand.ungroup.title))
        #expect(!titles.contains(AppCommand.removeGroup.title))
    }

    @Test
    func move_to_group_opens_the_group_in_the_window() {
        let f = makeFixture()
        let group = f.store.createGroup(name: "work")
        let window = WindowState()
        f.state.moveToGroup(f.project.id, group: group.id, store: f.store, in: window)
        #expect(window.expandedRows.contains(group.id))
    }
}
