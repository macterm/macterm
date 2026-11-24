import Foundation
@testable import Macterm
import Testing

/// The New Project screen (`PaletteInput.newProject`): Select in Finder on
/// an empty field, one action row for a typed folder, and the folders under
/// the typed path as completions.
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
    func an_empty_field_shows_select_in_finder_alone_and_the_pill_has_no_icon() throws {
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        #expect(PaletteInput.newProject.pill == PalettePill(title: "New Project"))

        let empty = rows(scope, "", context)
        #expect(empty.map(\.title) == ["Select in Finder"])
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
    func a_typed_folder_has_one_action_row_that_adds_it() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let listed = rows(scope, folder.path + "/", context)
        let action = try #require(listed.first)
        #expect(action.title == "New Project \"\(folder.path)/\"")
        #expect(listed.dropFirst().allSatisfy { !scope.isAction($0) }, "one action row")
        #expect(scope.press(action) == .closed)
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
        let parent = folder.deletingLastPathComponent().path + "/"
        #expect(rows(scope, " \(parent) ", context).map(\.title) == ["New Project \"\(parent)\"", "api"])
    }

    @Test
    func a_folder_that_a_project_has_switches_to_that_project() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        let existing = context.projectStore.create(name: "API", path: folder.path)

        let action = try #require(rows(scope, folder.path, context).first)
        #expect(action.title == "Switch to \"API\"")
        #expect(scope.press(action) == .closed)
        #expect(context.projectStore.projects.map(\.id) == [existing.id])
        #expect(context.appState.activeProjectID == existing.id)
    }

    @Test
    func the_folders_under_the_path_are_completions_with_their_full_path() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let parent = folder.deletingLastPathComponent().path
        let listed = rows(scope, parent + "/", context)
        #expect(listed.map(\.title) == ["New Project \"\(parent)/\"", "api"])
        let child = listed[1]
        #expect(child.subtitle == folder.path)
        #expect(scope.press(child) == .fill(folder.path + "/"), "a completion fills the field and runs nothing")
        #expect(context.projectStore.projects.isEmpty)
    }

    @Test
    func a_remote_spec_has_one_action_row() throws {
        let (context, window) = makeContext()
        let scope = InputPaletteScope(input: .newProject)

        let new = try #require(rows(scope, "devbox:~/dev/api", context).first)
        #expect(new.title == "New Project \"devbox:~/dev/api\"")
        #expect(scope.press(new) == .closed)
        #expect(window.isNewRemoteProjectSheetPresented, "the dialog adds the project")
        #expect(window.newRemoteProjectDraft != nil)
        #expect(context.projectStore.projects.isEmpty)

        let existing = context.projectStore.create(name: "api", path: "devbox:~/dev/api")
        let known = try #require(rows(scope, "devbox:~/dev/api", context).first)
        #expect(known.title == "Switch to \"api\"")
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

        #expect(rows(scope, file.path, context).isEmpty)
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
