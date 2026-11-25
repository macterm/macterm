import Foundation
@testable import Macterm
import Testing

/// Change Project Directory: its palette screen and its one setter.
@MainActor
struct AppStateProjectDirectoryTests {
    private struct Fixture {
        let state: AppState
        let store: ProjectStore
        let project: Project
        var ctx: AppCommandContext { AppCommandContext(appState: state, projectStore: store) }
    }

    private func makeFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        return ProjectPath.normalizedForStorage(url.path(percentEncoded: false))
    }

    private func makeFixture(path: String) -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-dir-ctx-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: base.appendingPathComponent("w.json")),
            projectFiles: ProjectFileStore(directoryURL: base.appendingPathComponent("projects", isDirectory: true))
        )
        let store = ProjectStore(fileURL: base.appendingPathComponent("p.json"))
        let project = Project(name: "proj", path: path, sortOrder: 0)
        store.add(project)
        state.selectProject(project)
        return Fixture(state: state, store: store, project: project)
    }

    private func path(of fixture: Fixture) -> String? {
        fixture.store.projects.first { $0.id == fixture.project.id }?.path
    }

    /// The action row that `text` gives, nil for a notice or nothing.
    private func action(_ input: PaletteInput, _ text: String) -> PaletteInputAction? {
        if case let .action(row) = input.check(text) { return row }
        return nil
    }

    /// The notice that `text` gives, nil for an action row or nothing.
    private func notice(_ input: PaletteInput, _ text: String) -> String? {
        if case let .notice(line) = input.check(text) { return line }
        return nil
    }

    @Test
    func the_pane_row_commits_the_pane_folder() throws {
        let root = try makeFolder()
        let sub = root + "/sub"
        let fixture = makeFixture(path: root)
        var paneDirectory: String? = root
        let made = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { paneDirectory }
        )
        let input = try #require(made)
        #expect(action(input, "") == nil, "the pane is in the project folder")
        paneDirectory = sub + "/"
        let row = try #require(action(input, ""))
        #expect(row.title == "Current Pane's Directory")
        #expect(row.subtitle == sub)
        let scope = InputPaletteScope(input: input)
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let item = scope.sections(for: PaletteQuery(raw: ""), context: context).first?.items.first
        #expect(item?.title == "Current Pane's Directory")
        #expect(item?.subtitle == sub, "the row shows the pane's full path")
        #expect(item?.subtitleIsPath == true, "a long path is cut in the middle")
        #expect(row.run() == .done)
        #expect(path(of: fixture) == sub)
    }

    @Test
    func a_typed_path_sets_the_folder_and_completes_like_add_project() throws {
        let root = try makeFolder()
        let fixture = makeFixture(path: "/tmp")
        let made = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { nil }
        )
        let input = try #require(made)
        #expect(input.initialValue.isEmpty)
        #expect(action(input, "") == nil, "no pane folder: only the typed field")
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let rows = input.choices(root + "/", context)
        let rootName = (root as NSString).lastPathComponent
        #expect(rows.map(\.item.title) == [rootName, "sub"], "the typed folder, then its folders, as in the root palette")
        #expect(rows[1].item.subtitle?.hasPrefix("Change to: ") == true, "a folder row says what it does")
        #expect(rows[1].item.subtitleIsPath)
        #expect(rows[1].value == root + "/sub/", "Tab goes into the folder")
        #expect(action(input, root + "/") == nil, "no Change to row: a folder row is the action")
        #expect(notice(input, root + "/") == nil)
        rows[1].item.action()
        #expect(path(of: fixture) == root + "/sub")
    }

    @Test
    func a_bad_folder_is_refused_and_changes_nothing() throws {
        let root = try makeFolder()
        let fixture = makeFixture(path: root)
        let made = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { nil }
        )
        let input = try #require(made)
        #expect(notice(input, root + "/missing") == "Path \(root)/missing doesn't exist")
        #expect(action(input, root + "/missing") == nil, "no action row for a bad path")
        #expect(notice(input, root + "/su") == nil, "no notice while a folder row matches the typed text")
        #expect(notice(input, "relative/path") == "Path relative/path doesn't exist")
        let missingUnderHome = "~/macterm-no-such-folder-\(UUID().uuidString)"
        #expect(notice(input, missingUnderHome) == "Path \(missingUnderHome) doesn't exist", "the notice keeps ~")
        #expect(notice(input, "  ") == nil)
        #expect(action(input, "  ") == nil)
        let file = root + "/file.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(notice(input, file) == "\(file) is not a directory", "a file has its own notice")
        let store = fixture.store
        #expect(fixture.state
            .setProjectDirectory(fixture.project.id, to: file, projectStore: store) == .refused("\(file) is not a directory"))
        #expect(fixture.state.setProjectDirectory(fixture.project.id, to: "  ", projectStore: store) == .refused("Type a folder path"))
        #expect(path(of: fixture) == root)
    }

    @Test
    func return_runs_a_folder_row_and_tab_fills_it() throws {
        let root = try makeFolder()
        let fixture = makeFixture(path: "/tmp")
        let made = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { nil }
        )
        let scope = try InputPaletteScope(input: #require(made))
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let typed = root + "/s"
        let items = scope.sections(for: PaletteQuery(raw: typed), context: context).flatMap(\.items)
        #expect(items.map(\.title) == ["sub"])
        #expect(scope.restingItemID == items[0].id, "the selection rests on the first folder row")
        #expect(scope.press(nil) == .nothing, "no selected row: Return does nothing")
        #expect(scope.tabText(selected: items[0], rows: items) == root + "/sub/", "Tab puts the folder in the field")
        #expect(path(of: fixture) == "/tmp")
        #expect(scope.press(items[0]) == .closed)
        #expect(path(of: fixture) == root + "/sub")
    }

    @Test
    func the_pane_row_hides_when_the_pane_is_in_the_project_folder() throws {
        let root = try makeFolder()
        let project = Project(name: "proj", path: root, sortOrder: 0)
        #expect(AppState.paneDirectoryOffer(root, for: project) == nil)
        #expect(AppState.paneDirectoryOffer(root + "/", for: project) == nil)
        #expect(AppState.paneDirectoryOffer(nil, for: project) == nil)
        #expect(AppState.paneDirectoryOffer(root + "/sub", for: project) == root + "/sub")
        let noFolder = Project(name: "bare", path: "", sortOrder: 0)
        #expect(AppState.paneDirectoryOffer(root, for: noFolder) == nil, "a project with no folder has only the typed field")
    }

    @Test
    func a_path_with_a_tilde_expands() {
        let fixture = makeFixture(path: "/tmp")
        let home = ProjectPath.normalizedForStorage(NSHomeDirectory())
        #expect(fixture.state.setProjectDirectory(fixture.project.id, to: "~", projectStore: fixture.store) == .done)
        #expect(path(of: fixture) == home)
    }

    @Test
    func a_project_with_no_folder_gets_its_first_folder() throws {
        let root = try makeFolder()
        let fixture = makeFixture(path: "")
        let input = try #require(fixture.state.changeProjectDirectoryInput(for: fixture.project, projectStore: fixture.store))
        #expect(action(input, "") == nil)
        #expect(try #require(action(input, root)).run() == .done)
        #expect(path(of: fixture) == root)
    }

    @Test
    func the_command_opens_its_screen_for_a_local_project_even_in_its_own_folder() throws {
        let root = try makeFolder()
        let fixture = makeFixture(path: root)
        let ctx = fixture.ctx
        #expect(AppCommand.changeProjectDirectory.category == .projects)
        #expect(AppCommand.changeProjectDirectory.title == "Change Project Directory")
        #expect(AppCommand.changeProjectDirectory.hotkeyAction == .changeProjectDirectory)
        #expect(HotkeyAction.changeProjectDirectory.defaultShortcut == "none")
        #expect(AppCommand.changeProjectDirectory.action(in: ctx) != nil)
        #expect(AppCommand.changeProjectDirectory.unavailableNotice(in: ctx) == nil)
        guard case let .input(input)? = AppCommand.changeProjectDirectory.paletteScreen(in: ctx) else {
            Issue.record("the command opens an input screen")
            return
        }
        #expect(input.pill == PalettePill(title: "Change Project Directory"), "an input screen's pill has no glyph")
        #expect(AppCommand.changeProjectDirectory.opensPaletteScreen, "its chord is answered with the palette up")
        #expect(AppCommand.changeProjectDirectory.paletteIcon == nil)
        #expect(PaletteScopeID.files.pill.icon != nil, "a built-in screen keeps its glyph")

        let item = CommandSource().emptyItems(context: PaletteContext(appState: fixture.state, projectStore: fixture.store))?
            .first { $0.title == AppCommand.changeProjectDirectory.title }
        #expect(item?.opensScope == .input(input), "the palette row enters the screen in place")
    }

    @Test
    func a_remote_project_has_no_change_project_directory() {
        let fixture = makeFixture(path: "devbox:~/proj")
        let ctx = fixture.ctx
        let reason = "Change Project Directory is not available for remote projects"
        #expect(AppCommand.changeProjectDirectory.action(in: ctx) == nil)
        #expect(AppCommand.changeProjectDirectory.paletteScreen(in: ctx) == nil)
        #expect(AppCommand.changeProjectDirectory.unavailableNotice(in: ctx) == reason)
        #expect(AppCommand.changeProjectDirectory.paletteDisabledHint(in: ctx) == reason)
        let muted = CommandSource().emptyItems(context: PaletteContext(appState: fixture.state, projectStore: fixture.store))?
            .first { $0.title == AppCommand.changeProjectDirectory.title }
        #expect(muted?.isEnabled == false)
        #expect(muted?.icon == nil, "an input screen has no glyph")
        #expect(fixture.state.setProjectDirectory(fixture.project.id, to: "/tmp", projectStore: fixture.store) == .refused(reason))
        #expect(path(of: fixture) == "devbox:~/proj")
    }

    @Test
    func the_search_finds_it_by_the_old_words() {
        let aliases = AppCommand.changeProjectDirectory.searchAliases
        for word in ["set project folder", "set project path", "replace project path", "cwd"] {
            #expect(aliases.contains(word))
        }
        #expect(!AppCommand.allCases.map(\.rawValue).contains("replaceProjectPathWithCurrentDir"), "the old command is gone")
    }
}
