import Darwin
import Foundation
@testable import Macterm

/// The model of a test: a server of the bundled build in a folder of its own
/// under `/tmp` (a socket path has at most 103 bytes), with a model, and the
/// app's objects over it. The server is the model's one owner, as in the app
/// (design/010): a test changes the model with the app's requests and reads
/// the mirror. The server exits when the test's connection ends.
@MainActor
enum TestModel {
    /// The folder of this test process. A run removes the folders of earlier
    /// runs whose process is gone.
    private static let processRoot: URL = {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let prefix = "mtt-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: tmp.appending(path: name))
        }
        let root = tmp.appending(path: "\(prefix)\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    private static var count = 0

    /// A new server and a connection to it, with the model installed.
    static func connection() -> ModelConnection {
        guard let bundled = LocalServer.bundled else {
            preconditionFailure("zmx/zmx missing from the built bundle. Run `mise run setup`.")
        }
        count += 1
        let root = processRoot.appending(path: "\(count)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var server = bundled
        server.directory = root.appending(path: "r", directoryHint: .isDirectory)
        server.stateDirectory = root.appending(path: "s", directoryHint: .isDirectory)
        let connection = ModelConnection(server: server)
        do {
            try connection.connectNow()
        } catch {
            preconditionFailure("the test server did not start: \(error)")
        }
        return connection
    }

    /// A second connection to the server of `state`: a relaunch of the app
    /// on the same model (the server and `model.json` stay).
    static func reconnect(_ state: AppState) -> ModelConnection {
        let connection = ModelConnection(server: state.modelConnection.server)
        do {
            try connection.connectNow()
        } catch {
            preconditionFailure("the test server did not answer: \(error)")
        }
        return connection
    }

    /// A relaunch: a new AppState on the same server, with the same files.
    static func relaunch(
        _ state: AppState,
        guiStateStore: GUIStateStore,
        projectFiles: ProjectFileStore? = nil,
        workspaceStore: WorkspaceStore? = nil
    ) -> AppState {
        AppState(
            modelConnection: reconnect(state),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: folder("state").appending(path: "workspaces_v3.json")),
            guiStateStore: guiStateStore,
            projectFiles: projectFiles ?? state.projectFiles,
            quickTerminal: QuickTerminalSplitState(),
            legacyPanelVisible: { false }
        )
    }

    /// A temp folder of its own.
    static func folder(_ name: String = "dir") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An AppState over a new server, with every file of its own in a temp
    /// folder, so a test never touches the user's data.
    static func appState(
        workspaceStore: WorkspaceStore? = nil,
        guiStateStore: GUIStateStore? = nil,
        projectFiles: ProjectFileStore? = nil,
        quickTerminal: QuickTerminalSplitState? = nil
    ) -> AppState {
        let dir = folder("state")
        return AppState(
            modelConnection: connection(),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: dir.appending(path: "workspaces_v3.json")),
            guiStateStore: guiStateStore ?? GUIStateStore(fileURL: dir.appending(path: "gui-state.json")),
            projectFiles: projectFiles ?? ProjectFileStore(directoryURL: dir.appending(path: "projects", directoryHint: .isDirectory)),
            quickTerminal: quickTerminal ?? QuickTerminalSplitState(),
            legacyPanelVisible: { false }
        )
    }

    /// The project store of `state`'s model.
    static func projectStore(_ state: AppState) -> ProjectStore {
        let store = ProjectStore(writer: state.writer)
        store.autoAssignsColors = { false }
        return store
    }

    /// A project of the tree in `state`'s model, with its first tab, and
    /// selected. `path` empty: a project with no folder and no tab.
    @discardableResult
    static func project(_ state: AppState, name: String = "proj", path: String = "/tmp", parent: UUID? = nil, select: Bool = true) -> Project {
        let project = Project(name: name, path: path, parent: parent)
        guard state.writer.projectCreate(project), let stored = state.model.project(project.id) else {
            preconditionFailure("the test server refused the project")
        }
        state.projectAdded(stored)
        if select { state.selectProject(stored) }
        return stored
    }
}

/// The tabs of one project of the mirror, read live: each property reads
/// the model again, so a test can hold it across a change.
@MainActor
struct LiveTabs {
    let model: ModelMirror
    let id: UUID

    var tabs: [TerminalTab] { model.tabs(of: id) }
    var activeTabID: UUID? { model.activeTabID(of: id) }
    var activeTab: TerminalTab? { model.activeTab(of: id) }
    var project: Project? { model.project(id) }

    func recencyOrder() -> [UUID] {
        model.recencyOrder(of: id)
    }
}

/// `state.liveTabs[projectID]`: the tabs of a project of the model, or nil
/// for a project that the model does not have.
@MainActor
struct LiveTabsLookup {
    let model: ModelMirror

    subscript(_ id: UUID) -> LiveTabs? {
        model.project(id) == nil ? nil : LiveTabs(model: model, id: id)
    }

    var count: Int { model.projects.count }
}

extension AppState {
    var liveTabs: LiveTabsLookup { LiveTabsLookup(model: model) }
}
