import Foundation
@testable import Macterm
import Testing

/// The New Project screen (`PaletteInput.newProject`): Select in Finder as
/// its action row, and the rows of path mode of the root for a typed path.
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
    func the_finder_row_is_first_with_no_glyph_and_the_pill_has_no_icon() throws {
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
    func a_typed_path_lists_the_rows_of_path_mode() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let typed = folder.deletingLastPathComponent().path + "/"
        let listed = rows(scope, typed, context)
        let rootRows = DirectorySource().items(query: typed, context: context)
        #expect(listed.first?.title == "Select in Finder")
        let results = Array(listed.dropFirst())
        #expect(results.map(\.id) == rootRows.map(\.id))
        #expect(results.map(\.subtitle) == rootRows.map(\.subtitle))
        #expect(results.allSatisfy { scope.isResult($0) && $0.icon == nil })
        let child = try #require(results.last)
        #expect(child.title == "api")
        #expect(
            try scope.completion(for: child) == #require(DirectorySource.path(of: child)) + "/",
            "Tab fills the folder, ready to go into it"
        )
    }

    @Test
    func a_result_adds_its_folder_or_switches_to_its_project() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let top = try #require(rows(scope, folder.path, context).first(where: scope.isResult))
        #expect(scope.press(top) == .closed)
        let project = try #require(context.projectStore.projects.first)
        #expect(project.name == "api")
        #expect(context.appState.activeProjectID == project.id)

        // The folder has a project now: the top row switches to it, and the
        // row below adds another.
        let path = DirectorySource.path(of: top) ?? ""
        let again = rows(scope, folder.path, context).filter(scope.isResult)
        #expect(again.map(\.id) == ["dir-switch:\(path)", "dir-new:\(path)"])
        #expect(scope.press(again[0]) == .closed)
        #expect(context.projectStore.projects.count == 1)
    }

    @Test
    func text_with_spaces_around_it_lists_the_same_rows() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        let plain = rows(scope, folder.path, context).map(\.id)
        #expect(plain.count > 1)
        #expect(rows(scope, " \(folder.path) ", context).map(\.id) == plain)
    }

    @Test
    func a_remote_spec_lists_the_remote_rows_with_no_completion() {
        let (context, window) = makeContext()
        let scope = InputPaletteScope(input: .newProject)

        let new = rows(scope, "devbox:~/dev/api", context).filter(scope.isResult)
        #expect(new.count == 1)
        #expect(scope.completion(for: new[0]) == nil)
        #expect(scope.press(new[0]) == .closed)
        #expect(window.isNewRemoteProjectSheetPresented, "the dialog adds the project")
        #expect(context.projectStore.projects.isEmpty)

        let existing = context.projectStore.create(name: "api", path: "devbox:~/dev/api")
        let known = rows(scope, "devbox:~/dev/api", context).filter(scope.isResult)
        #expect(known.count == 2, "switch, then add another")
        #expect(known.allSatisfy { scope.completion(for: $0) == nil })
        #expect(scope.press(known[0]) == .closed)
        #expect(context.appState.activeProjectID == existing.id)
    }

    @Test
    func a_path_with_no_row_shows_its_notice_and_no_action_row() throws {
        let folder = try makeFolder("api")
        let file = folder.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        #expect(rows(scope, file.path, context).isEmpty)
        #expect(scope.failure?.title == PathProblem.local(atPath: file.path)?.notice(for: file.path))
        #expect(scope.press(nil) == .nothing, "with no row, Return does nothing")

        let missing = folder.path + "/zzz-missing"
        #expect(rows(scope, missing, context).isEmpty)
        #expect(scope.failure?.title == PathProblem.local(atPath: missing)?.notice(for: missing))
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
