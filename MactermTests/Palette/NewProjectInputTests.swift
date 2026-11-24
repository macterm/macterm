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
    func the_screen_has_the_finder_row_over_the_rows_of_path_mode() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        #expect(PaletteInput.newProject.pill == PalettePill(title: "New Project"), "a pill with no icon")

        let empty = scope.sections(for: PaletteQuery(raw: ""), context: context)
        #expect(empty.map { $0.items.map(\.title) } == [["Select in Finder"]])

        // The rows are the root's rows for the same text: the typed folder,
        // then its children, each with its full path.
        let parentPath = folder.deletingLastPathComponent().path
        let typed = parentPath + "/"
        let sections = scope.sections(for: PaletteQuery(raw: typed), context: context)
        let rootRows = DirectorySource().items(query: typed, context: context)
        #expect(sections.count == 2)
        #expect(try scope.isAction(#require(sections.first?.items.first)))
        #expect(sections.last?.items.map(\.id) == rootRows.map(\.id))
        #expect(sections.last?.items.map(\.subtitle) == rootRows.map(\.subtitle))
        #expect(sections.last?.header == nil, "no header, as in the root")
        let child = try #require(sections.last?.items.last)
        #expect(child.title == "api")
        #expect(scope.isResult(child))
        #expect(
            try scope.completion(for: child) == #require(DirectorySource.path(of: child)) + "/",
            "Tab fills the folder, ready to go into it"
        )
    }

    @Test
    func a_row_adds_its_folder_as_the_root_row_does() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()

        let rows = scope.sections(for: PaletteQuery(raw: folder.path), context: context).last?.items ?? []
        let top = try #require(rows.first)
        #expect(scope.isResult(top))
        top.action()
        let project = try #require(context.projectStore.projects.first)
        #expect(project.name == "api")
        #expect(context.appState.activeProjectID == project.id)

        // The folder has a project now: the top row switches to it, and the
        // row below adds another.
        let again = scope.sections(for: PaletteQuery(raw: folder.path), context: context).last?.items ?? []
        #expect(again.map(\.id).first == "dir-switch:\(DirectorySource.path(of: top) ?? "")")
        #expect(again.count == 2)
    }

    @Test
    func a_typed_folder_adds_a_project_and_selects_it() throws {
        let folder = try makeFolder("api")
        let (context, _) = makeContext()

        // The field's completions end in a slash; the project's path does not.
        #expect(NewProjectInput.commit(folder.path + "/", context: context) == .done)
        let project = try #require(context.projectStore.projects.first)
        #expect(context.projectStore.projects.count == 1)
        #expect(project.name == "api")
        #expect(project.path == ProjectPath.normalizedForStorage(folder.path))
        #expect(context.appState.activeProjectID == project.id)
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
    func text_with_spaces_around_it_lists_the_same_rows() throws {
        let folder = try makeFolder("api")
        let scope = InputPaletteScope(input: .newProject)
        let (context, _) = makeContext()
        let plain = scope.sections(for: PaletteQuery(raw: folder.path), context: context).last?.items.map(\.id)
        let padded = scope.sections(for: PaletteQuery(raw: " \(folder.path) "), context: context).last?.items.map(\.id)
        #expect(plain != nil)
        #expect(padded == plain)
    }

    @Test
    func remote_rows_complete_nothing() throws {
        let (context, _) = makeContext()
        _ = context.projectStore.create(name: "api", path: "devbox:~/dev/api")
        let scope = InputPaletteScope(input: .newProject)
        let rows = try #require(scope.sections(for: PaletteQuery(raw: "devbox:~/dev/api"), context: context).last?.items)
        #expect(rows.count == 2, "switch, then add another")
        #expect(rows.allSatisfy { scope.isResult($0) && scope.completion(for: $0) == nil })
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
