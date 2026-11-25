import Foundation
@testable import Macterm
import Testing

/// The New Project screen (`PaletteInput.newProject`): Select in Finder on
/// an empty field, and for a typed path the folder rows of the root
/// palette's path mode, each of which is the action.
@MainActor
struct NewProjectInputTests {
    private func makeContext() -> (PaletteContext, WindowState) {
        let tmp = FileManager.default.temporaryDirectory
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json")),
            projectFiles: ProjectFileStore(
                directoryURL: tmp.appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        let store = ProjectStore(fileURL: tmp.appendingPathComponent("macterm-tests-\(UUID().uuidString).json"))
        return (PaletteContext(appState: state, projectStore: store), window)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-new-project-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func rows(_ scope: InputPaletteScope, _ text: String, _ context: PaletteContext) -> [PaletteItem] {
        scope.sections(for: PaletteQuery(raw: text), context: context).flatMap(\.items)
    }

    @Test
    func an_empty_field_shows_select_in_finder_and_cancel_and_the_pill_has_no_icon() throws {
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        #expect(PaletteInput.newProject.pill == PalettePill(title: "New Project"))

        let empty = rows(scope, "", context)
        #expect(empty.map(\.title) == ["Select in Finder", "Cancel"], "main's Cancel row comes last")
        let finder = try #require(empty.first)
        #expect(scope.isAction(finder))
        #expect(finder.icon == nil, "no glyph, so that its title lines up with the rows below")
    }

    @Test
    func select_in_finder_shows_the_panel_after_the_palette_closes() throws {
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        let finder = try #require(rows(scope, "", context).first)
        #expect(context.appState.postPaletteAction == nil)
        #expect(scope.press(finder) == .closed)
        #expect(context.appState.postPaletteAction != nil, "the panel waits for the palette to close")
    }

    @Test
    func a_typed_character_takes_select_in_finder_away() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        for text in [" ", "~", "/", folder.path, folder.deletingLastPathComponent().path + "/a", "devbox:~/api"] {
            #expect(!rows(scope, text, context).contains { $0.title == "Select in Finder" }, "\(text)")
        }
    }

    @Test
    func a_typed_folder_is_a_row_that_adds_it_and_there_is_no_new_project_row() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let listed = rows(scope, folder.path + "/", context)
        let row = try #require(listed.first)
        #expect(row.title == "api")
        #expect(row.subtitle == "Open as new project: \(folder.path)")
        #expect(!listed.contains { $0.title.hasPrefix("New Project") }, "the folder rows are the actions")
        #expect(!listed.contains { scope.isAction($0) })
        #expect(scope.isChoice(row))
        #expect(scope.restingItemID == row.id, "the selection rests on the first folder")
        #expect(scope.press(row) == .closed)
        let project = try #require(context.projectStore.projects.first)
        #expect(project.name == "api")
        #expect(project.path == ProjectPath.normalizedForStorage(folder.path), "the path loses its trailing slash")
        #expect(context.appState.activeProjectID == project.id)
    }

    @Test
    func spaces_around_a_path_change_nothing() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        let parent = folder.deletingLastPathComponent()
        #expect(rows(scope, " \(parent.path)/ ", context).map(\.title) == [parent.lastPathComponent, "api"])
    }

    @Test
    func a_folder_that_a_project_has_switches_to_it_and_can_add_another() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        let existing = context.projectStore.create(name: "API", path: folder.path)

        let listed = rows(scope, folder.path, context)
        let switchRow = try #require(listed.first)
        #expect(switchRow.title == "API")
        #expect(switchRow.subtitle == "Switch to project: \(folder.path)")
        #expect(listed.dropFirst().first?.subtitle == "Add another project: \(folder.path)", "as in the root palette")
        #expect(scope.press(switchRow) == .closed)
        #expect(context.projectStore.projects.map(\.id) == [existing.id])
        #expect(context.appState.activeProjectID == existing.id)
    }

    @Test
    func the_folders_that_complete_the_path_are_rows_and_tab_fills_one() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let parent = folder.deletingLastPathComponent().path
        let half = rows(scope, parent + "/a", context)
        #expect(half.map(\.title) == ["api"])
        #expect(scope.failure == nil, "a path that completes to a folder has no notice")
        let child = try #require(half.first)
        #expect(scope.completion(for: child) == folder.path + "/", "Tab puts the folder in the field")
        #expect(scope.press(child) == .closed, "Return or a click adds the selected folder")
        #expect(context.projectStore.projects.map(\.name) == ["api"])
    }

    @Test
    func a_second_tab_on_a_folder_goes_into_it() throws {
        let folder = try makeFolder("api")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        var listed = rows(scope, folder.path, context)
        var tab = try #require(scope.tabText(selected: listed.first, rows: listed))
        #expect(tab == folder.path + "/", "the first Tab gives the folder its slash")
        listed = rows(scope, tab, context)
        #expect(listed.map(\.title) == ["api", "src"], "the typed folder stays the first row")
        tab = try #require(scope.tabText(selected: listed.first, rows: listed))
        #expect(tab == folder.path + "/src/", "the second Tab goes into the folder")
    }

    @Test
    func a_remote_spec_gets_the_remote_rows() throws {
        let (context, _) = makeContext()
        let scope = InputPaletteScope(input: .newProject)

        let new = try #require(rows(scope, "devbox:~/dev/api", context).first)
        #expect(new.subtitle == "Add remote project: devbox:~/dev/api")
        #expect(scope.failure == nil)
        guard case let .opens(.input(folderStep)) = scope.press(new) else {
            Issue.record("the remote row opens the folder step of New Remote Project")
            return
        }
        #expect(folderStep.id == "remote-folder:devbox")
        #expect(folderStep.initialValue == "~/dev/api")
        #expect(context.projectStore.projects.isEmpty)

        let existing = context.projectStore.create(name: "api", path: "devbox:~/dev/api")
        let known = try #require(rows(scope, "devbox:~/dev/api", context).first)
        #expect(known.subtitle == "Switch to remote project: devbox:~/dev/api")
        let listed = rows(scope, "devbox:~/dev/api", context)
        #expect(listed.allSatisfy { scope.completion(for: $0) == nil }, "Tab does not fill a remote row")
        #expect(scope.press(known) == .closed)
        #expect(context.appState.activeProjectID == existing.id)
    }

    @Test
    func a_path_that_is_not_a_folder_shows_its_notice_and_no_action_row() throws {
        let folder = try makeFolder("api")
        let file = folder.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        #expect(rows(scope, file.path, context).isEmpty, "a file is no folder row")
        #expect(scope.failure?.title == "\(file.path) is not a directory")
        #expect(scope.press(nil) == .nothing, "with no row, Return does nothing")

        let missing = folder.path + "/zzz"
        #expect(rows(scope, missing, context).isEmpty)
        #expect(scope.failure?.title == "Path \(missing) doesn't exist")
        #expect(context.projectStore.projects.isEmpty)
    }

    @Test
    func the_command_and_the_sidebar_button_open_the_screen() {
        let (context, window) = makeContext()
        #expect(AppCommand.newProject.title == "New Project")
        #expect(AppCommand.newProject.paletteScope == .input(.newProject))
        #expect(PaletteScopeID.input(.newProject).summary == "Add a project from a folder")

        // The menu item, the Dock and a keybind run the command's action.
        let action = AppCommand.newProject.action(
            in: AppCommandContext(appState: context.appState, projectStore: context.projectStore)
        )
        action?()
        #expect(window.paletteScope == .input(.newProject))
        #expect(window.isCommandPaletteVisible)

        // The sidebar's button opens it in the window's palette.
        window.isCommandPaletteVisible = false
        window.resetPaletteStack()
        context.appState.openCommandPalette(scope: .input(.newProject))
        #expect(window.paletteScope == .input(.newProject))
    }

    @Test
    func a_search_for_the_old_names_finds_the_command() {
        #expect(AppCommand.newProject.searchAliases.contains("Open Project"))
        #expect(AppCommand.newProject.searchAliases.contains("Add Project"))
    }
}
