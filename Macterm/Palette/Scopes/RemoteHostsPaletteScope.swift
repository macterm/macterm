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
    static let icon: PaletteIcon = "network"

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
        if !hosts.contains(where: { $0.alias == text }), let typed = typedItem(text, context: context) {
            sections.append(PaletteSection(header: nil, items: [typed]))
        }
        if !matches.isEmpty {
            sections.append(PaletteSection(header: header, items: matches))
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

    /// The row of a typed destination, nil when the text is not one.
    private func typedItem(_ text: String, context: PaletteContext) -> PaletteItem? {
        guard ProjectPath.composeRemote(host: text, directory: "~") != nil else { return nil }
        return PaletteItem(
            id: "remote-host-typed:\(text)",
            title: text,
            subtitle: String(localized: "Not in ~/.ssh/config"),
            score: 0,
            opensScope: .input(Self.folderInput(destination: text, context: context)),
            icon: Self.icon
        ) {}
    }

    /// New Remote Project, step 2: the folder on `destination`, `~` first
    /// (or `directory`, a folder that the user typed in the root's
    /// `host:folder`). Return checks the folder on the host
    /// (`RemoteHosts.refusal`, 0358) while the screen shows that it
    /// connects. The login and the install question show as sheets on the
    /// window. A refusal is the screen's line, and the user can correct the
    /// folder. A folder that is there adds the project, named by its folder
    /// (`ProjectPath.remoteDisplayName`), and shows it.
    static func folderInput(
        destination: String,
        directory: String = "~",
        context: PaletteContext,
        refusal: @escaping @MainActor (String) async -> String? = { await RemoteHosts.shared.refusal(forNewProjectPath: $0) }
    ) -> PaletteInput {
        PaletteInput(
            id: "remote-folder:\(destination)",
            pill: PalettePill(title: destination, icon: icon),
            prompt: String(localized: "Folder on \(destination)"),
            initialValue: directory
        ) { [appState = context.appState, projectStore = context.projectStore] text in
            let folder = text.trimmingCharacters(in: .whitespaces)
            guard let path = ProjectPath.composeRemote(host: destination, directory: folder.isEmpty ? "~" : folder),
                  case let .remote(_, host, parsedFolder) = ProjectPath.parse(path)
            else { return .refused(String(localized: "\(destination) is not a host name.")) }
            let name = ProjectPath.remoteDisplayName(host: host, directory: parsedFolder)
            if let reason = Project.nameRefusal(for: name) { return .refused(reason) }
            return .check(PaletteCheck(message: String(localized: "Connecting to \(destination)…")) {
                let answer = await refusal(path)
                guard !Task.isCancelled else { return .refused("") }
                if let answer {
                    logger.info("new remote project \(path, privacy: .public): not added")
                    return .refused(answer)
                }
                // Always create: a folder can back several projects.
                appState.selectProject(projectStore.create(name: name, path: path))
                return .done
            })
        }
    }
}
