import Foundation
@testable import Macterm
import Testing

/// The shadow stage against the bundled server (design/010 §9, step 3): an
/// `AppState` fixture saves, the server takes the copy in `model.replace`,
/// and the mirror that follows the server's events agrees with the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ModelShadowTests {
    @Test
    func the_mirror_agrees_with_the_app_after_each_save() async throws {
        try await withServer { server in
            let dir = server.directory.deletingLastPathComponent()
            let store = ProjectStore(fileURL: dir.appending(path: "projects.json"))
            let group = store.add(.group(name: "Group"))
            let a = store.add(Project(name: "a", path: "/tmp", sortOrder: 0))
            let b = store.add(Project(name: "b", path: "/var", sortOrder: 0))
            store.move(b.id, into: group.id)
            let remote = store.add(Project(name: "r", path: "bob@box:/srv", sortOrder: 0))

            let state = AppState(
                workspaceStore: WorkspaceStore(fileURL: dir.appending(path: "workspaces.json")),
                projectFiles: ProjectFileStore(directoryURL: dir.appending(path: "projects", directoryHint: .isDirectory))
            )
            state.sessionClient = .noop
            state.incubatePane = { _ in }
            state.selectProject(remote)
            state.selectProject(a)
            state.splitPane(direction: .vertical, projectID: a.id, projects: store.projects)
            _ = state.createTab(projectID: a.id, projectPath: a.path)
            let pinned = try #require(state.workspaces[a.id]?.activeTab)
            state.pinTab(pinned.id, fromProject: a.id)
            _ = try #require(state.createScratchTab(focus: false))

            let sessions = LocalSessions(server: server)
            let shadow = ModelShadow(projectStore: store, sessions: sessions)
            state.modelShadow = shadow
            await shadow.start()
            await sessions.prepare()
            state.saveWorkspaces()
            let first = try await agreement(shadow)

            // Every project, the group and the one with no workspace too.
            #expect(Set(first.projects.map(\.id)) == Set([group, a, b, remote].map { $0.id.uuidString }))
            #expect(first.projects.first { $0.id == b.id.uuidString }?.parent == group.id.uuidString)
            let spaces = Dictionary(uniqueKeysWithValues: first.workspaces.map { ($0.id, $0) })
            #expect(spaces[b.id.uuidString]?.tabs.isEmpty == true)
            #expect(spaces[PinnedTabs.workspaceID.uuidString]?.kind == .pinned)
            #expect(spaces[PinnedTabs.workspaceID.uuidString]?.tabs.map(\.id) == [pinned.id.uuidString])
            #expect(spaces[ScratchTabs.workspaceID.uuidString]?.kind == .scratch)
            let tabs = try #require(state.workspaces[a.id]?.tabs)
            #expect(spaces[a.id.uuidString]?.tabs.map(\.id) == tabs.map(\.id.uuidString))
            guard case let .split(split)? = spaces[a.id.uuidString]?.tabs.first?.root else {
                Issue.record("the split tab is not a split")
                return
            }
            #expect(split.dir == .vertical)
            let panes = tabs[0].splitRoot.allPanes()
            #expect(panes.map(\.sessionName) == [split.first, split.second].compactMap {
                if case let .pane(p) = $0 { p.session } else { nil }
            })
            let remotePane = spaces[remote.id.uuidString]?.tabs.first?.root
            if case let .pane(p)? = remotePane {
                #expect(p.host == "bob@box")
            } else {
                Issue.record("the remote tab has no pane")
            }
            #expect(first.selection.activeProject == a.id.uuidString)

            // A change after the first save comes back as events.
            state.closeTab(tabs[0].id, projectID: a.id)
            state.saveWorkspaces()
            let second = try await agreement(shadow)
            #expect(second.workspaces.first { $0.id == a.id.uuidString }?.tabs.map(\.id) == tabs.dropFirst().map(\.id.uuidString))
            #expect(shadow.mirror.seq > 0)
        }
    }

    /// Waits until the server took the newest save and the mirror agrees
    /// with it.
    private func agreement(_ shadow: ModelShadow) async throws -> MactermProtocol.ModelData {
        var differences = ["nothing sent"]
        for _ in 0 ..< 100 {
            if let sent = shadow.lastSent, let data = shadow.mirror.data {
                differences = ModelConversion.differences(mirror: data, sent: sent)
                if differences.isEmpty { return data }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the mirror differs: \(differences)")
        throw CancellationError()
    }

    // MARK: - Server

    /// A server of the bundled build with a runtime and a state directory of
    /// its own. The path is short: a socket path has at most 103 bytes.
    private func withServer(_ body: (LocalServer) async throws -> Void) async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "ms-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)
        server.stateDirectory = root.appending(path: "state", directoryHint: .isDirectory)
        do {
            try await body(server)
        } catch {
            await Self.stop(server)
            throw error
        }
        await Self.stop(server)
    }

    private static func stop(_ server: LocalServer) async {
        guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }
}
