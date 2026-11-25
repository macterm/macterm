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
        var palette: PaletteContext { PaletteContext(appState: state, projectStore: store) }
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
    private func action(_ input: PaletteInput, _ text: String, _ fixture: Fixture) -> PaletteInputAction? {
        if case let .action(row) = input.check(text, fixture.palette) { return row }
        return nil
    }

    /// The notice that `text` gives, nil for an action row or nothing.
    private func notice(_ input: PaletteInput, _ text: String, _ fixture: Fixture) -> String? {
        if case let .notice(line) = input.check(text, fixture.palette) { return line }
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
        let input = made
        #expect(action(input, "", fixture) == nil, "the pane is in the project folder")
        paneDirectory = sub + "/"
        let row = try #require(action(input, "", fixture))
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
        let input = made
        #expect(input.initialValue.isEmpty)
        #expect(action(input, "", fixture) == nil, "no pane folder: only the typed field")
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let rows = input.choices(root + "/", context)
        let rootName = (root as NSString).lastPathComponent
        #expect(rows.map(\.item.title) == [rootName, "sub"], "the typed folder, then its folders, as in the root palette")
        #expect(rows[1].item.subtitle?.hasPrefix("Change to: ") == true, "a folder row says what it does")
        #expect(rows[1].item.subtitleIsPath)
        #expect(rows[1].value == root + "/sub/", "Tab goes into the folder")
        #expect(action(input, root + "/", fixture) == nil, "no Change to row: a folder row is the action")
        #expect(notice(input, root + "/", fixture) == nil)
        rows[1].item.action()
        #expect(path(of: fixture) == root + "/sub")

        let home = ProjectPath.normalizedForStorage(NSHomeDirectory())
        let homeRow = try #require(input.choices("~", context).first, "a typed ~ is its own folder row")
        #expect(homeRow.item.subtitle == "Change to: \(home)", "the row shows the full path")
        #expect(homeRow.value == "~/", "Tab keeps the ~ that the user typed")
        homeRow.item.action()
        #expect(path(of: fixture) == home)
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
        let input = made
        #expect(notice(input, root + "/missing", fixture) == "Path \(root)/missing doesn't exist")
        #expect(action(input, root + "/missing", fixture) == nil, "no action row for a bad path")
        #expect(notice(input, root + "/su", fixture) == nil, "no notice while a folder row matches the typed text")
        #expect(notice(input, "relative/path", fixture) == "Path relative/path doesn't exist")
        let missingUnderHome = "~/macterm-no-such-folder-\(UUID().uuidString)"
        #expect(notice(input, missingUnderHome, fixture) == "Path \(missingUnderHome) doesn't exist", "the notice keeps ~")
        #expect(notice(input, "  ", fixture) == nil)
        #expect(action(input, "  ", fixture) == nil)
        let file = root + "/file.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(notice(input, file, fixture) == "\(file) is not a directory", "a file has its own notice")
        try FileManager.default.createDirectory(atPath: root + "/file.txt-old", withIntermediateDirectories: true)
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        #expect(input.choices(file, context).map(\.item.title) == ["file.txt-old"])
        #expect(notice(input, file, fixture) == "\(file) is not a directory", "a file keeps its notice beside the folder rows")
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
        let scope = InputPaletteScope(input: made)
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
        let remote = Project(name: "remote", path: "devbox:~/proj", sortOrder: 0)
        #expect(AppState.paneDirectoryOffer("~/proj/", for: remote) == nil, "a remote pane in the project's folder")
        #expect(AppState.paneDirectoryOffer("/srv/app", for: remote) == "/srv/app")
        #expect(AppState.paneDirectoryOffer("/home/me/proj/", for: remote) == "/home/me/proj", "an absolute path from the host's shell")
        #expect(AppState.paneDirectoryOffer("file://devbox/srv", for: remote) == nil, "a URL is not a folder on the host")
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
        let input = fixture.state.changeProjectDirectoryInput(for: fixture.project, projectStore: fixture.store)
        #expect(action(input, "", fixture) == nil)
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let first = try #require(input.choices(root, context).first, "the typed folder is the first folder row")
        #expect(first.item.title == (root as NSString).lastPathComponent)
        first.item.action()
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
    func a_remote_project_with_no_folder_list_changes_its_folder_after_the_host_checks_it() async throws {
        let fixture = makeFixture(path: "me@devbox:~/proj")
        let ctx = fixture.ctx
        #expect(AppCommand.changeProjectDirectory.action(in: ctx) != nil, "a remote project has the command too")
        #expect(AppCommand.changeProjectDirectory.unavailableNotice(in: ctx) == nil)
        #expect(AppCommand.changeProjectDirectory.paletteDisabledHint(in: ctx) == nil)

        var asked: [(String, String)] = []
        var answer = RemoteHosts.FolderCheck.missing
        let input = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { "~/other/" },
            listFolders: { _, _ in nil },
            folderCheck: { folder, destination in
                asked.append((folder, destination))
                return answer
            }
        )
        let empty = try #require(action(input, "", fixture))
        #expect(empty.title == "Current Pane's Directory")
        #expect(empty.subtitle == "~/other", "the remote pane's folder")
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        let items = try await settledItems(scope, "~/api", context)
        #expect(items.map(\.title) == ["Change to \"~/api\""], "no list from the host: the typed folder is the action")
        #expect(scope.press(items[0]) == .checking)
        #expect(scope.loading?.message == "Checking the folder on me@devbox")
        #expect(scope.press(items[0]) == .nothing, "a second Return waits for the check")
        try await waitUntil { scope.loading == nil }
        #expect(asked.count == 1)
        #expect(asked.first?.0 == "~/api")
        #expect(asked.first?.1 == "me@devbox")
        #expect(scope.failure?.title == "Path ~/api doesn't exist", "the host's answer is the local notice")
        let again = scope.sections(for: PaletteQuery(raw: "~/api"), context: context).flatMap(\.items)
        #expect(again.map(\.title) == ["Change to \"~/api\""], "the row stays under the reason, for every path")
        #expect(!scope.takeCloseRequest())
        #expect(path(of: fixture) == "me@devbox:~/proj")

        answer = .exists
        #expect(scope.press(items[0]) == .checking)
        #expect(scope.failure == nil, "a new check hides the old reason")
        try await waitUntil { scope.loading == nil }
        #expect(scope.takeCloseRequest(), "a yes runs the action and closes the palette")
        #expect(path(of: fixture) == "me@devbox:~/api")

        let slashed = try await settledItems(scope, "/srv/web/", context)
        #expect(slashed.map(\.title) == ["Change to \"/srv/web\""], "a path with a slash gets the same row")
        #expect(scope.press(slashed[0]) == .checking)
        try await waitUntil { scope.loading == nil }
        #expect(path(of: fixture) == "me@devbox:/srv/web", "a slash at the end goes")
        #expect(notice(input, "api", fixture) == "Path api doesn't exist", "a session starts only in a folder from / or ~")

        #expect(empty.run() == .done, "the pane row needs no check")
        #expect(path(of: fixture) == "me@devbox:~/other")
    }

    @Test
    func leaving_the_screen_cancels_the_host_check() async throws {
        let fixture = makeFixture(path: "devbox:~/proj")
        let input = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { nil },
            listFolders: { _, _ in nil },
            folderCheck: { _, _ in
                try? await Task.sleep(for: .milliseconds(200))
                return .exists
            }
        )
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        let items = try await settledItems(scope, "/srv", context)
        #expect(scope.press(items[0]) == .checking)
        scope.deactivate()
        try await Task.sleep(for: .milliseconds(400))
        #expect(path(of: fixture) == "devbox:~/proj", "a cancelled check changes nothing")
        #expect(!scope.takeCloseRequest())
    }

    @Test
    func new_text_stops_the_host_check_of_the_old_text() async throws {
        let fixture = makeFixture(path: "devbox:~/proj")
        let input = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { nil },
            listFolders: { _, _ in nil },
            folderCheck: { _, _ in
                try? await Task.sleep(for: .milliseconds(200))
                return .exists
            }
        )
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        let old = try await settledItems(scope, "~/apj", context)
        #expect(scope.press(old[0]) == .checking)
        _ = scope.sections(for: PaletteQuery(raw: "~/api"), context: context)
        #expect(scope.loading == nil, "new text stops the check")
        try await Task.sleep(for: .milliseconds(400))
        #expect(path(of: fixture) == "devbox:~/proj", "the old text's answer runs nothing")
        #expect(!scope.takeCloseRequest())
    }

    @Test
    func a_remote_project_lists_the_hosts_folders_as_a_local_project_does() async throws {
        let fixture = makeFixture(path: "me@devbox:~/proj")
        var asked: [(String, String)] = []
        var checked = 0
        let listings = [
            "~/": FolderListing(path: "/home/me", names: ["proj", "projects", ".config"]),
            "~/proj/": FolderListing(path: "/home/me/proj", names: ["api"]),
        ]
        let input = fixture.state.changeProjectDirectoryInput(
            for: fixture.project,
            projectStore: fixture.store,
            paneDirectory: { nil },
            listFolders: { folder, destination in
                asked.append((folder, destination))
                return listings[folder]
            },
            folderCheck: { _, _ in
                checked += 1
                return .exists
            }
        )
        let context = PaletteContext(appState: fixture.state, projectStore: fixture.store)
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}

        let rows = try await settledItems(scope, "~/pro", context)
        #expect(rows.map(\.title) == ["proj", "projects"], "the rows of a local path: folder names")
        #expect(rows.first?.subtitle == "Change to: /home/me/proj", "the full path on the host")
        #expect(rows.first?.subtitleIsPath == true)
        #expect(scope.failure == nil)
        #expect(asked.first?.1 == "me@devbox")
        #expect(scope.restingItemID == rows.first?.id, "the selection rests on the first folder row")
        #expect(scope.tabText(selected: rows.first, rows: rows) == "~/proj/", "Tab keeps the ~ that the user typed")

        let inside = try await settledItems(scope, "~/proj", context)
        #expect(inside.map(\.title) == ["proj", "api"], "a typed folder, then the folders in it")

        let none = try await settledItems(scope, "~/zzz", context)
        #expect(none.isEmpty, "no Change to row: nothing matches")
        #expect(scope.failure?.title == "Path ~/zzz doesn't exist", "the notice only when nothing matches")

        let picked = try await settledItems(scope, "~/pro", context)
        #expect(scope.press(picked[0]) == .closed, "a folder row is the action")
        #expect(path(of: fixture) == "me@devbox:~/proj", "the folder as the user typed it")
        #expect(checked == 0, "the host listed the folder, so it needs no check")
    }

    /// The rows of `text` once the host's listing in flight has ended.
    private func settledItems(_ scope: InputPaletteScope, _ text: String, _ context: PaletteContext) async throws -> [PaletteItem] {
        _ = scope.sections(for: PaletteQuery(raw: text), context: context)
        try await waitUntil { scope.loading == nil }
        return scope.sections(for: PaletteQuery(raw: text), context: context).flatMap(\.items)
    }

    /// Poll until `condition` holds, with a sleep, or fail after 2 s.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
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
