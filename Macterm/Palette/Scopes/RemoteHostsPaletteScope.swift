import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteHostsPaletteScope")

/// New Remote Project, step 1: the hosts of the user's ssh config
/// (`SSHConfigHosts`), each with its `HostName` and `User`. A typed
/// `[user@]host` that no row names is the first row. A row opens step 2,
/// the folder on that host (`folderInput`).
///
/// The config is read once for each screen, so each open of the screen
/// reads the file again. A missing file shows only the typed row.
@MainActor
final class RemoteHostsPaletteScope: PaletteScope {
    nonisolated static let icon: PaletteIcon = "network"

    let placeholder = String(localized: "Search hosts or type user@host...")
    private let readHosts: () -> [SSHConfigHost]
    private lazy var hosts: [SSHConfigHost] = readHosts()

    init(readHosts: @escaping () -> [SSHConfigHost] = { SSHConfigHosts.load() }) {
        self.readHosts = readHosts
    }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        let header = String(
            localized: "palette.remoteHosts.header",
            defaultValue: "SSH Config",
            comment: "Command palette, New Remote Project: the heading of the hosts of ~/.ssh/config"
        )
        guard !query.isEmpty else {
            let items = hosts.map { item(for: $0, context: context) }
            return items.isEmpty ? [] : [PaletteSection(header: header, items: items)]
        }
        let text = query.trimmed
        let search = SearchQuery(text)
        let matches = hosts.compactMap { host -> PaletteItem? in
            let fields = [host.alias, host.hostName, host.user].compactMap(\.self)
            guard let match = Search.match(search, fields: fields) else { return nil }
            return item(for: host, context: context).with(match)
        }
        .rankedByScore()
        var sections: [PaletteSection] = []
        if !matches.isEmpty {
            sections.append(PaletteSection(header: header, items: matches))
        }
        // The typed row is first only when no host matches, so Return on a
        // part of a name picks the host and not the part.
        if !hosts.contains(where: { $0.alias == text }), let typed = typedItem(text, context: context) {
            sections.insert(PaletteSection(header: nil, items: [typed]), at: matches.isEmpty ? 0 : sections.count)
        }
        return sections
    }

    private func item(for host: SSHConfigHost, context: PaletteContext) -> PaletteItem {
        PaletteItem(
            id: "remote-host:\(host.alias)",
            title: host.alias,
            subtitle: host.detail,
            score: 0,
            opensScope: .input(Self.folderInput(destination: host.alias, context: context)),
            icon: Self.icon
        ) {}
    }

    /// The row of a typed `[user@]host` or `[user@]host:folder`, nil when
    /// the text is neither.
    private func typedItem(_ text: String, context: PaletteContext) -> PaletteItem? {
        guard let target = Self.target(text) else { return nil }
        return PaletteItem(
            id: "remote-host-typed:\(text)",
            title: text,
            subtitle: String(localized: "Not in ~/.ssh/config"),
            score: 0,
            opensScope: .input(Self.folderInput(
                destination: target.destination,
                directory: target.directory ?? "~",
                context: context
            )),
            icon: Self.icon
        ) {}
    }

    /// The destination and the folder of a typed `[user@]host` or
    /// `[user@]host:folder`. Nil for any other text: a space, an empty part,
    /// or a host name with characters that a host name cannot have.
    static func target(_ text: String) -> (destination: String, directory: String?)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.contains(where: \.isWhitespace) else { return nil }
        if text.contains(":") {
            guard case let .remote(user, host, directory) = ProjectPath.parse(text),
                  isDestination(HostCommands.destination(user: user, host: host))
            else { return nil }
            return (HostCommands.destination(user: user, host: host), directory)
        }
        return isDestination(text) ? (text, nil) : nil
    }

    /// Whether `text` is `[user@]host`: a destination that ssh takes
    /// (`SSHConnections.isValidDestination`), with no `:` or `/` (they
    /// would read as the folder of a spec), and no empty user or host.
    static func isDestination(_ text: String) -> Bool {
        guard SSHConnections.isValidDestination(text), !text.contains(":"), !text.contains("/") else { return false }
        let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty }
    }

    /// New Remote Project, step 2: the folder on `destination`. It starts
    /// on `directory` (`~`, or the folder of a typed `host:folder`).
    ///
    /// A typed path lists the host's folders as the rows of a local path
    /// (`FolderCompletion`, `HostFolderLister`): the typed folder, then the
    /// folders in it or the folders that complete it. Each row is the
    /// action: Return or a click adds the folder as a project, with no
    /// check, because the host listed it. Tab goes into it. A path with no
    /// row is the one notice of a path (`PathProblem`), as on a local
    /// screen.
    ///
    /// Only when the host gives no list (no connection up, no answer in
    /// time) does a typed folder give the action row
    /// `New Project "devbox:~/api"`. It checks the folder on the host
    /// (`RemoteHosts.refusal`) while the palette shows that it connects,
    /// and a missing folder or a file is the notice of `PathProblem`.
    ///
    /// A new project is named by its folder
    /// (`ProjectPath.remoteDisplayName`) and is always new: a folder can
    /// back several projects.
    static func folderInput(
        destination: String,
        directory: String = "~",
        context: PaletteContext,
        listFolders: @escaping @MainActor (String, String) async -> FolderListing? = {
            await RemoteHosts.shared.listFolders($0, destination: $1)
        },
        refusal: @escaping @MainActor (String) async -> String? = { await RemoteHosts.shared.refusal(forNewProjectPath: $0) }
    ) -> PaletteInput {
        let lister = HostFolderLister { folder in await listFolders(folder, destination) }
        let appState = context.appState
        let projectStore = context.projectStore
        return PaletteInput(
            id: "remote-folder:\(destination)",
            title: destination,
            prompt: String(localized: "Folder on \(destination)"),
            initialValue: directory,
            choices: { text, _ in
                folderChoices(for: text, destination: destination, lister: lister, appState: appState, projectStore: projectStore) ?? []
            },
            hostFolders: lister,
            check: { text, _ in
                let folder = hostFolder(text)
                if folder.isEmpty { return .nothing }
                guard isDestination(destination),
                      let path = ProjectPath.composeRemote(host: destination, directory: folder)
                else { return .notice(String(localized: "\(destination) is not a host name.")) }
                // A session starts only in a folder from `/` or `~`.
                guard HostCommands.isSafeHostFolder(folder) else {
                    return .notice(PathProblem.missing.notice(for: folder))
                }
                switch folderChoices(for: text, destination: destination, lister: lister, appState: appState, projectStore: projectStore) {
                case let rows? where rows.isEmpty:
                    // The host listed the folders and none matches.
                    return .notice(PathProblem.missing.notice(for: folder))
                case .some:
                    // The folder rows are the action.
                    return .nothing
                case nil where lister.isListing:
                    return .nothing
                case nil:
                    break
                }
                // No list from the host: the typed folder is the action, and
                // the host checks it when it runs.
                let title = String(
                    localized: "palette.remoteFolder.action",
                    defaultValue: "New Project \"\(path)\"",
                    comment: "Command palette, New Remote Project: the action row that adds the typed folder of the host"
                )
                return .action(PaletteInputAction(
                    title: title,
                    check: (
                        message: String(localized: "Connecting to \(destination)…"),
                        answer: {
                            let answer = await refusal(path)
                            if answer != nil { logger.info("new remote project \(path, privacy: .public): not added") }
                            return answer
                        }
                    ),
                    run: { addProject(path, appState: appState, projectStore: projectStore) }
                ))
            }
        )
    }

    /// The folder rows of a path typed in step 2: the rows of a local path
    /// (`FolderCompletion`), from the host's folder list. Each row adds the
    /// folder as the user typed it, with no slash at the end
    /// (`hostFolder`). nil while the host lists, or when it gave no list.
    static func folderChoices(
        for text: String,
        destination: String,
        lister: HostFolderLister,
        appState: AppState,
        projectStore: ProjectStore
    ) -> [PaletteInputChoice]? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard isDestination(destination),
              HostCommands.isSafeHostFolder(hostFolder(typed)),
              let rows = FolderCompletion.rows(for: typed, listing: lister.listing)
        else { return nil }
        return rows.compactMap { row in
            guard let path = ProjectPath.composeRemote(host: destination, directory: hostFolder(row.fieldText)) else { return nil }
            return PaletteInputChoice(
                item: PaletteItem(
                    id: "remote-folder:\(row.path)",
                    title: PathRow.title(for: row.path),
                    subtitle: PathRow.Action.openAsNewProject.subtitle(for: path),
                    subtitleIsPath: true,
                    action: { _ = addProject(path, appState: appState, projectStore: projectStore) }
                ),
                value: row.fieldText
            )
        }
    }

    /// The folder of a field, with no slash at the end (`~/api/` is
    /// `~/api`), as a project keeps it. `/` and `~/` stay a folder.
    static func hostFolder(_ text: String) -> String {
        var folder = text.trimmingCharacters(in: .whitespaces)
        while folder.count > 1, folder.hasSuffix("/") {
            folder.removeLast()
        }
        return folder
    }

    /// Add the remote project at `path` (`host:folder`) and show it.
    private static func addProject(_ path: String, appState: AppState, projectStore: ProjectStore) -> PaletteCommit {
        guard case let .remote(_, host, folder) = ProjectPath.parse(path) else { return .refused("") }
        // A name that nobody typed: `ProjectStore.create` changes a reserved
        // one (`Pinned 2`), as for a local folder.
        let name = ProjectPath.remoteDisplayName(host: host, directory: folder)
        appState.selectProject(projectStore.create(name: name, path: path))
        return .done
    }
}
