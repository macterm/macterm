import Foundation
@testable import Macterm
import Testing

/// The New Project screen (`PaletteInput.newProject`): a typed folder path
/// with completion, and a Select in Finder row.
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

    @Test
    func the_screen_has_the_finder_row_over_the_completions() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let empty = scope.sections(for: PaletteQuery(raw: ""), context: context)
        #expect(empty.map { $0.items.map(\.title) } == [["Select in Finder"]])

        let parent = folder.deletingLastPathComponent().path + "/"
        let sections = scope.sections(for: PaletteQuery(raw: parent), context: context)
        #expect(sections.map { $0.items.map(\.title) } == [["Select in Finder"], ["api"]])
        #expect(try scope.isAction(#require(sections.first?.items.first)))
    }

    @Test
    func a_typed_folder_adds_a_project_and_selects_it() throws {
        let folder = try makeFolder("api")
        let (context, window) = makeContext()

        // The field's completions end in a slash; the project's path does not.
        #expect(NewProjectInput.commit(folder.path + "/", context: context) == .done)
        let project = try #require(context.projectStore.projects.first)
        #expect(context.projectStore.projects.count == 1)
        #expect(project.name == "api")
        #expect(project.path == ProjectPath.normalizedForStorage(folder.path))
        #expect(context.appState.activeProjectID == project.id)
        #expect(window.expandedRows.contains(project.id))
    }

    @Test
    func a_folder_that_a_project_has_selects_that_project() throws {
        let folder = try makeFolder("api")
        let (context, _) = makeContext()
        let existing = context.projectStore.create(name: "API", path: folder.path)

        #expect(NewProjectInput.commit(folder.path, context: context) == .done)
        #expect(context.projectStore.projects.map(\.id) == [existing.id])
        #expect(context.appState.activeProjectID == existing.id)
    }

    @Test
    func a_remote_spec_that_a_project_has_selects_that_project() {
        let (context, _) = makeContext()
        let existing = context.projectStore.create(name: "api", path: "devbox:~/dev/api")

        #expect(NewProjectInput.commit("devbox:~/dev/api", context: context) == .done)
        #expect(context.projectStore.projects.map(\.id) == [existing.id])
        #expect(context.appState.activeProjectID == existing.id)
    }

    @Test
    func a_new_remote_spec_opens_the_remote_dialog_filled_in() {
        let (context, window) = makeContext()

        #expect(NewProjectInput.commit("devbox:~/dev/api", context: context) == .done)
        #expect(context.projectStore.projects.isEmpty, "the dialog adds the project")
        #expect(window.isNewRemoteProjectSheetPresented)
        #expect(window.newRemoteProjectDraft != nil)
    }

    @Test
    func a_path_that_is_not_a_folder_is_refused() throws {
        let folder = try makeFolder("api")
        let file = folder.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let (context, _) = makeContext()

        #expect(NewProjectInput.commit("", context: context) == .refused("Type the path of a folder."))
        #expect(NewProjectInput.commit(file.path, context: context) == .refused("There is no folder at \(file.path)."))
        #expect(NewProjectInput.commit(folder.path + "/missing", context: context) != .done)
        #expect(NewProjectInput.commit("api", context: context) != .done, "a relative path names no folder")
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
