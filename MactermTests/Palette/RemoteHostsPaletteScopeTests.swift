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
        #expect(input.pill.title == "devbox")
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
        let input = RemoteHostsPaletteScope.folderInput(destination: "me@devbox", context: context) { path in
            checked.append(path)
            return nil
        }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        #expect(!scope.commit("~/dev/api"))
        #expect(scope.loading?.message == "Connecting to me@devbox…")
        try await waitUntil { scope.isFinished }

        #expect(checked == ["me@devbox:~/dev/api"])
        #expect(store.projects.map(\.name) == ["api"])
        #expect(store.projects.map(\.path) == ["me@devbox:~/dev/api"])
        #expect(state.activeProjectID == store.projects.first?.id)
    }

    @Test
    func an_empty_folder_is_the_home_folder_and_names_the_project_after_the_host() async throws {
        let (context, _, store) = makeContext()
        let input = RemoteHostsPaletteScope.folderInput(destination: "devbox", context: context) { _ in nil }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        #expect(!scope.commit("  "))
        try await waitUntil { scope.isFinished }
        #expect(store.projects.map(\.name) == ["devbox"])
        #expect(store.projects.map(\.path) == ["devbox:~"])
    }

    @Test
    func a_refused_folder_adds_nothing_and_shows_why() async throws {
        let (context, _, store) = makeContext()
        let input = RemoteHostsPaletteScope.folderInput(destination: "devbox", context: context) { _ in
            "There is no path ~/none on devbox."
        }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        #expect(!scope.commit("~/none"))
        try await waitUntil { scope.loading == nil }
        #expect(!scope.isFinished)
        #expect(scope.failure?.title == "There is no path ~/none on devbox.")
        #expect(store.projects.isEmpty)
    }

    @Test
    func a_reserved_folder_name_is_changed_as_for_a_local_folder() async throws {
        let (context, _, store) = makeContext()
        let input = RemoteHostsPaletteScope.folderInput(destination: "devbox", context: context) { _ in nil }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        #expect(!scope.commit("~/Pinned"))
        try await waitUntil { scope.isFinished }
        #expect(store.projects.map(\.name) == ["Pinned 2"])
    }

    @Test
    func a_folder_step_left_during_its_check_adds_nothing() async throws {
        let (context, _, store) = makeContext()
        var answer: CheckedContinuation<String?, Never>?
        let input = RemoteHostsPaletteScope.folderInput(destination: "devbox", context: context) { _ in
            await withCheckedContinuation { answer = $0 }
        }
        let scope = InputPaletteScope(input: input)
        scope.activate(context: context) {}
        #expect(!scope.commit("~/api"))
        try await waitUntil { answer != nil }
        scope.deactivate()
        answer?.resume(returning: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!scope.isFinished)
        #expect(store.projects.isEmpty)
    }

    @Test
    func a_destination_that_is_not_a_host_is_refused_before_any_check() {
        let (context, _, _) = makeContext()
        var checks = 0
        let input = RemoteHostsPaletteScope.folderInput(destination: "not a host", context: context) { _ in
            checks += 1
            return nil
        }
        #expect(input.commit("~") == .refused("not a host is not a host name."))
        #expect(checks == 0)
    }
}
