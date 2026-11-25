import Foundation
@testable import Macterm
import Testing

/// New Remote Project in the palette (`RemoteHostsPaletteScope`): step 1
/// lists the hosts of the ssh config, step 2 asks for the folder and adds
/// the project after the folder check.
@MainActor
struct RemoteHostsPaletteScopeTests {
    private let hosts = [
        SSHConfigHost(alias: "devbox", hostName: "devbox.example.com", user: "me"),
        SSHConfigHost(alias: "gpu", hostName: "10.0.0.7", user: nil),
        SSHConfigHost(alias: "web", hostName: nil, user: nil),
    ]

    private func makeContext() -> (PaletteContext, AppState, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        return (PaletteContext(appState: state, projectStore: store), state, store)
    }

    private func rows(_ query: String, hosts: [SSHConfigHost]? = nil) -> [PaletteItem] {
        let scope = RemoteHostsPaletteScope { hosts ?? self.hosts }
        return scope.sections(for: PaletteQuery(raw: query), context: makeContext().0).flatMap(\.items)
    }

    /// The rows of the folder step for `text`.
    private func folderRows(_ scope: InputPaletteScope, _ text: String, _ context: PaletteContext) -> [PaletteItem] {
        scope.sections(for: PaletteQuery(raw: text), context: context).flatMap(\.items)
    }

    /// The rows of the folder step for `text`, after the host's listing
    /// that they need has come.
    private func settledRows(_ scope: InputPaletteScope, _ text: String, _ context: PaletteContext) async throws -> [PaletteItem] {
        // A listing can lead to a probe of the path: draw again until a
        // draw starts no request.
        for _ in 0 ..< 10 {
            _ = folderRows(scope, text, context)
            guard scope.input.hostFolders?.isListing == true else { break }
            try await waitUntil { scope.input.hostFolders?.isListing != true }
        }
        return folderRows(scope, text, context)
    }

    /// Return on the first row of the folder step for `text`.
    private func press(_ scope: InputPaletteScope, _ text: String, _ context: PaletteContext) async throws -> PaletteInputPress {
        try await scope.press(settledRows(scope, text, context).first)
    }

    /// A host that gives no folder list: the folder step falls back to its
    /// action row and the host's check.
    private let noList: @MainActor (String, String) async -> FolderListing? = { _, _ in nil }

    /// A host that gives no answer as the user types.
    private let noProbe: @MainActor (String, String) async -> RemoteHosts.FolderCheck? = { _, _ in nil }

    /// The folder step of `destination` on a host with no list, whose
    /// check on Return answers `answer` and records each folder it checks.
    private func unlistedStep(
        _ context: PaletteContext,
        destination: String = "devbox",
        checked: @escaping @MainActor (String) -> Void = { _ in },
        answer: @escaping @MainActor (String) async -> RemoteHosts.FolderCheck = { _ in .exists }
    ) -> InputPaletteScope {
        let input = RemoteHostsPaletteScope.folderInput(
            destination: destination,
            context: context,
            listFolders: noList,
            probeFolder: noProbe
        ) { folder, _ in
            checked(folder)
            return await answer(folder)
        }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        return scope
    }

    /// A host whose home is `/home/me`, with `api`, `docs` and `.cache` in
    /// it, and `src` in `api`.
    private let homeList: @MainActor (String, String) async -> FolderListing? = { folder, _ in
        switch folder {
        case "~/": FolderListing(path: "/home/me", names: ["api", "docs", ".cache"])
        case "~/api/": FolderListing(path: "/home/me/api", names: ["src"])
        default: nil
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func empty_it_lists_every_host_with_where_it_goes() {
        let items = rows("")
        #expect(items.map(\.title) == ["devbox", "gpu", "web"])
        #expect(items.map(\.subtitle) == ["me@devbox.example.com", "10.0.0.7", nil])
    }

    @Test
    func a_search_matches_the_alias_the_host_name_or_the_user() {
        #expect(rows("gpu").map(\.title) == ["gpu"])
        #expect(rows("example").map(\.title).contains("devbox"))
        #expect(rows("10.0.0").map(\.title).contains("gpu"))
    }

    @Test
    func a_typed_host_that_no_row_names_is_the_first_row() {
        let items = rows("ops@bastion")
        #expect(items.first?.title == "ops@bastion")
        #expect(items.first?.subtitle == "Not in ~/.ssh/config")
        #expect(rows("devbox").map(\.title) == ["devbox"], "a host of the config has no typed row")
        #expect(rows("dev").map(\.title) == ["devbox", "dev"], "a matching host comes before the typed row")
        #expect(!rows("not a host").contains { $0.title == "not a host" })
        #expect(rows("@box").isEmpty, "an empty user is not a host")
        #expect(rows("me@").isEmpty, "an empty host is not a host")
        #expect(rows("dev/box").isEmpty)
    }

    @Test
    func a_typed_host_and_folder_opens_the_folder_step_on_that_folder() throws {
        let item = try #require(rows("me@devbox:~/dev/api").first)
        guard case let .input(input)? = item.opensScope else {
            Issue.record("the typed row opens the folder step")
            return
        }
        #expect(input.id == "remote-folder:me@devbox")
        #expect(input.initialValue == "~/dev/api")
        #expect(RemoteHostsPaletteScope.target("devbox:/srv")?.destination == "devbox")
        #expect(RemoteHostsPaletteScope.target("devbox:/srv")?.directory == "/srv")
        #expect(RemoteHostsPaletteScope.target("dev box:/srv") == nil)
    }

    @Test
    func no_config_shows_only_the_typed_row() {
        #expect(rows("", hosts: []).isEmpty)
        #expect(rows("devbox", hosts: []).map(\.title) == ["devbox"])
    }

    @Test
    func each_open_reads_the_config_again() {
        var reads = 0
        let read: () -> [SSHConfigHost] = {
            reads += 1
            return []
        }
        let context = makeContext().0
        for _ in 0 ..< 2 {
            let scope = RemoteHostsPaletteScope(readHosts: read)
            _ = scope.sections(for: PaletteQuery(raw: ""), context: context)
            _ = scope.sections(for: PaletteQuery(raw: "d"), context: context)
        }
        #expect(reads == 2, "one read for each screen, none for each keystroke")
    }

    @Test
    func a_host_row_opens_the_folder_step_on_the_home_folder() throws {
        let item = try #require(rows("").first)
        guard case let .input(input)? = item.opensScope else {
            Issue.record("a host row opens the folder step")
            return
        }
        #expect(input.id == "remote-folder:devbox")
        #expect(input.initialValue == "~")
        #expect(input.pill == PalettePill(title: "devbox", icon: nil), "an input screen's pill has no icon")
        #expect(input.prompt == "Folder on devbox")
    }

    @Test
    func the_command_opens_the_host_list() {
        #expect(AppCommand.newRemoteProject.paletteScope == .remoteHosts)
        #expect(PaletteScopeID.remoteHosts.command == .newRemoteProject)
        #expect(PaletteScopeID.remoteHosts.pill.title == AppCommand.newRemoteProject.title)
        #expect(!PaletteScopeID.builtIn.contains(.remoteHosts), "a step of a Projects command, not a Palettes screen")

        let (_, state, store) = makeContext()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        let run = AppCommand.newRemoteProject.action(in: AppCommandContext(appState: state, projectStore: store))
        run?()
        #expect(window.isCommandPaletteVisible)
        #expect(window.paletteScope == .remoteHosts)
    }

    @Test
    func the_folder_step_adds_the_project_when_the_folder_is_there() async throws {
        let (context, state, store) = makeContext()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        var checked: [String] = []
        let scope = unlistedStep(context, destination: "me@devbox", checked: { checked.append($0) })
        #expect(try await settledRows(scope, "~/dev/api", context).map(\.title) == ["New Project \"me@devbox:~/dev/api\""])
        #expect(try await press(scope, "~/dev/api", context) == .checking)
        #expect(scope.loading?.message == "Connecting to me@devbox…", "the host has not answered yet")
        #expect(folderRows(scope, "~/dev/api", context).isEmpty, "the check's notice is alone")
        try await waitUntil { scope.loading == nil }
        #expect(scope.takeCloseRequest())

        #expect(checked == ["~/dev/api"])
        #expect(store.projects.map(\.name) == ["api"])
        #expect(store.projects.map(\.path) == ["me@devbox:~/dev/api"])
        #expect(state.activeProjectID == store.projects.first?.id)
    }

    @Test
    func the_home_folder_names_the_project_after_the_host_and_an_empty_field_has_no_action() async throws {
        let (context, _, store) = makeContext()
        let scope = unlistedStep(context)
        #expect(folderRows(scope, "  ", context).isEmpty)
        #expect(scope.failure == nil)
        #expect(try await press(scope, "~", context) == .checking)
        try await waitUntil { scope.loading == nil }
        #expect(scope.takeCloseRequest())
        #expect(store.projects.map(\.name) == ["devbox"])
        #expect(store.projects.map(\.path) == ["devbox:~"])
    }

    @Test
    func a_missing_folder_or_a_file_shows_the_path_notice_alone() async throws {
        let (context, _, store) = makeContext()
        let scope = unlistedStep(context, answer: { $0.hasSuffix(".txt") ? .notDirectory : .missing })

        #expect(try await press(scope, "~/none", context) == .checking)
        try await waitUntil { scope.loading == nil }
        #expect(!scope.takeCloseRequest())
        #expect(scope.failure == PaletteFailure(title: "Path ~/none doesn't exist", retryable: false), "no Retry")
        #expect(folderRows(scope, "~/none", context).isEmpty, "the notice is alone and centered, as for a local path")

        #expect(try await press(scope, "~/notes.txt", context) == .checking)
        try await waitUntil { scope.loading == nil }
        #expect(scope.failure?.title == "~/notes.txt is not a directory")
        #expect(folderRows(scope, "~/notes.txt", context).isEmpty)
        #expect(store.projects.isEmpty)
    }

    @Test
    func no_connection_shows_its_reason_with_retry_alone() async throws {
        let (context, _, store) = makeContext()
        var answers: [RemoteHosts.FolderCheck] = [.unreachable, .exists]
        var checks = 0
        let scope = unlistedStep(context, checked: { _ in checks += 1 }, answer: { _ in answers.removeFirst() })
        _ = folderRows(scope, "~/other", context)
        scope.retry()
        #expect(checks == 0, "no refusal: Retry does nothing")

        #expect(try await press(scope, "~/api", context) == .checking)
        try await waitUntil { scope.loading == nil }
        #expect(scope.failure == PaletteFailure(title: "Macterm cannot connect to devbox.", retryable: true))
        #expect(folderRows(scope, "~/api", context).isEmpty, "the reason is alone, with Retry")

        scope.retry()
        #expect(scope.loading != nil, "Retry runs the check again")
        try await waitUntil { scope.loading == nil }
        #expect(checks == 2)
        #expect(scope.takeCloseRequest())
        #expect(store.projects.map(\.path) == ["devbox:~/api"])
    }

    @Test
    func a_probe_waits_for_the_user_to_stop_typing() async throws {
        let (context, _, _) = makeContext()
        var probed: [String] = []
        let input = RemoteHostsPaletteScope.folderInput(
            destination: "devbox",
            context: context,
            listFolders: homeList,
            probeFolder: { path, _ in
                probed.append(path)
                return .missing
            },
            folderCheck: { _, _ in .exists }
        )
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        _ = try await settledRows(scope, "~/", context)
        for text in ["~/z", "~/zz", "~/zzz"] {
            _ = folderRows(scope, text, context)
        }
        _ = try await settledRows(scope, "~/zzz", context)
        #expect(probed == ["~/zzz"], "a newer path stops the request of an older one")
        #expect(scope.failure?.title == "Path ~/zzz doesn't exist")
    }

    @Test
    func a_reserved_folder_name_is_changed_as_for_a_local_folder() async throws {
        let (context, _, store) = makeContext()
        let scope = unlistedStep(context)
        #expect(try await press(scope, "~/Pinned", context) == .checking)
        try await waitUntil { scope.loading == nil }
        #expect(scope.takeCloseRequest())
        #expect(store.projects.map(\.name) == ["Pinned 2"])
    }

    @Test
    func a_folder_step_left_during_its_check_adds_nothing() async throws {
        let (context, _, store) = makeContext()
        var answer: CheckedContinuation<RemoteHosts.FolderCheck, Never>?
        let scope = unlistedStep(context, answer: { _ in await withCheckedContinuation { answer = $0 } })
        #expect(try await press(scope, "~/api", context) == .checking)
        try await waitUntil { answer != nil }
        scope.deactivate()
        answer?.resume(returning: .exists)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!scope.takeCloseRequest())
        #expect(store.projects.isEmpty)
    }

    @Test
    func a_destination_that_is_not_a_host_has_a_notice_and_no_action() {
        let (context, _, _) = makeContext()
        var checks = 0
        let scope = unlistedStep(context, destination: "not a host", checked: { _ in checks += 1 })
        #expect(folderRows(scope, "~", context).isEmpty)
        #expect(scope.failure?.title == "not a host is not a host name.")
        #expect(checks == 0)
    }

    @Test
    func a_host_that_lists_its_folders_gives_folder_rows_that_add_the_project() async throws {
        let (context, state, store) = makeContext()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        var checks = 0
        let input = RemoteHostsPaletteScope.folderInput(
            destination: "devbox",
            context: context,
            listFolders: homeList,
            probeFolder: noProbe
        ) { _, _ in
            checks += 1
            return .exists
        }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}

        let home = try await settledRows(scope, "~", context)
        #expect(home.map(\.title) == ["me", "api", "docs"], "the typed folder, then the folders in it; no hidden one")
        #expect(home.first?.subtitle == "Open as new project: devbox:~")
        #expect(home.allSatisfy { $0.id != InputPaletteScope.actionItemID }, "a listed folder needs no action row")

        let api = try #require(try await settledRows(scope, "~/a", context).first)
        #expect(api.title == "api")
        #expect(api.subtitle == "Open as new project: devbox:~/api")
        #expect(scope.completion(for: api) == "~/api/", "Tab goes into the folder")
        #expect(scope.failure == nil)
        #expect(scope.press(api) == .closed, "a listed folder adds with no check")
        #expect(checks == 0)
        #expect(store.projects.map(\.path) == ["devbox:~/api"])
        #expect(store.projects.map(\.name) == ["api"])
        #expect(state.activeProjectID == store.projects.first?.id)
    }

    @Test
    func a_path_that_no_listed_folder_matches_shows_its_notice_as_the_user_types() async throws {
        let (context, _, store) = makeContext()
        var probed: [String] = []
        let input = RemoteHostsPaletteScope.folderInput(
            destination: "devbox",
            context: context,
            listFolders: homeList,
            probeFolder: { path, _ in
                probed.append(path)
                return path.hasSuffix(".txt") ? .notDirectory : .missing
            },
            folderCheck: { _, _ in .exists }
        )
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}

        // The list has folders only: the host tells a file from a missing
        // path, with no Return.
        #expect(try await settledRows(scope, "~/notes.txt", context).isEmpty, "no action row: the notice is alone")
        #expect(scope.failure == PaletteFailure(title: "~/notes.txt is not a directory", retryable: false))
        #expect(try await settledRows(scope, "~/zzz", context).isEmpty)
        #expect(scope.failure?.title == "Path ~/zzz doesn't exist")
        #expect(try await settledRows(scope, "~/zzz/ab", context).isEmpty, "a missing folder above the path")
        #expect(scope.failure?.title == "Path ~/zzz/ab doesn't exist")
        #expect(probed == ["~/notes.txt", "~/zzz", "~/zzz/ab"])
        #expect(folderRows(scope, "api", context).isEmpty, "a session starts only in a folder from / or ~")
        #expect(scope.failure?.title == "Path api doesn't exist")
        #expect(store.projects.isEmpty)
    }

    @Test
    func a_host_that_answered_once_checks_the_folder_and_does_not_connect() async throws {
        let (context, _, _) = makeContext()
        let input = RemoteHostsPaletteScope.folderInput(
            destination: "devbox",
            context: context,
            listFolders: homeList,
            probeFolder: noProbe
        ) { _, _ in .exists }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}

        // A listed host whose probe gives no answer: the action row, whose
        // message says that it checks.
        #expect(try await press(scope, "~/zzz", context) == .checking)
        #expect(scope.loading?.message == "Checking the folder on devbox")
    }
}
