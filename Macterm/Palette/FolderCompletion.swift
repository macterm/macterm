import Foundation

/// The folders in one folder: its path from `/`, and the names of the
/// folders in it. A folder on a host asks the host
/// (`RemoteHosts.listFolders`).
struct FolderListing: Equatable {
    let path: String
    let names: [String]
}

/// What a host says about a folder that the field lists
/// (`RemoteHosts.listFolders`).
enum HostFolderAnswer: Equatable {
    /// The folders in it.
    case listed(FolderListing)
    /// A shell cannot `cd` to it: it is not there, or it is a file.
    case missing
    /// No connection up, or no clear answer in time.
    case unavailable
}

/// The folder rows of a typed path, from any listing of folders: the rule
/// of `PathCompleter`, for a source that is not the file system of this Mac
/// (a host, 0614). The rows of a local path and a remote path therefore
/// have the same order, the same hidden-folder rule and the same cap.
///
/// A typed folder (`~/api`, or `~/api/`) is the first row, then the folders
/// in it. Any other path lists the folders of its parent whose names start
/// with the last part (folded as `Search` folds). A hidden folder shows
/// only after a typed dot. `~` is a folder.
enum FolderCompletion {
    /// One folder row: the folder's path from `/`, and the text that Tab
    /// puts in the field (the folder as the user typed it, with a slash at
    /// the end, so the next completion goes into it).
    struct Row: Equatable {
        let path: String
        let fieldText: String
    }

    /// The rows of `typed`, or nil while a listing that they need is not
    /// there: `listing` gives the listing of a folder as typed (`~/`,
    /// `/srv/`), nil when it has none (yet, or ever).
    static func rows(
        for typed: String,
        limit: Int = 10,
        listing: (String) -> FolderListing?
    ) -> [Row]? {
        guard let parts = split(typed), let parent = listing(parts.parent) else { return nil }
        let text = parts.text
        let name = parts.name
        if name.isEmpty {
            return [Row(path: parent.path, fieldText: text)] + children(of: parent, typedFolder: text, name: "", limit: limit)
        }
        if parent.names.contains(name) {
            // The typed path is a folder: it, then the folders in it.
            let folderText = text + "/"
            let exact = Row(path: join(parent.path, name), fieldText: folderText)
            guard let folder = listing(folderText) else { return [exact] }
            return [exact] + children(of: folder, typedFolder: folderText, name: "", limit: limit)
        }
        return children(of: parent, typedFolder: parts.parent, name: name, limit: limit)
    }

    /// The folder that `typed` lists (as typed, with a slash at the end):
    /// the typed folder for a text that ends with a slash, else its parent.
    /// nil for a text that is not a path from `/` or `~`, and for `~name`
    /// with no slash, which names another user's home, not a folder in
    /// this one.
    static func listedFolder(for typed: String) -> String? {
        split(typed)?.parent
    }

    /// A typed path cut at its last slash.
    private struct Parts {
        /// The path, with `~` as `~/`.
        let text: String
        /// The folder to list, with a slash at the end.
        let parent: String
        /// The part after the last slash.
        let name: String
    }

    private static func split(_ typed: String) -> Parts? {
        if typed == "~" { return Parts(text: "~/", parent: "~/", name: "") }
        guard typed.hasPrefix("/") || (typed.hasPrefix("~") && typed.contains("/")) else { return nil }
        if typed.hasSuffix("/") { return Parts(text: typed, parent: typed, name: "") }
        let cut = typed.index(after: typed.lastIndex(of: "/") ?? typed.startIndex)
        return Parts(text: typed, parent: String(typed[..<cut]), name: String(typed[cut...]))
    }

    /// The folders of `listing` whose names start with `name`, sorted, at
    /// most `limit`. Hidden folders only when `name` starts with a dot.
    private static func children(of listing: FolderListing, typedFolder: String, name: String, limit: Int) -> [Row] {
        listing.names
            .filter { child in
                if !name.hasPrefix("."), child.hasPrefix(".") { return false }
                return name.isEmpty || Search.hasPrefix(child, name)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(limit)
            .map { Row(path: join(listing.path, $0), fieldText: typedFolder + $0 + "/") }
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }
}

/// The folder listings of one host for one screen (0614): a listing is
/// asked once, kept, and filtered as the user types the name part. A
/// screen reads `listing(_:)` from its rows. A listing that is not there
/// yet starts a request, and `onChange` tells the screen to draw again
/// when it comes. A request with no answer gives no rows.
@MainActor
final class HostFolderLister {
    private let list: @MainActor (String) async -> HostFolderAnswer
    /// The listings that came, the newest last. A read moves one to the end.
    private var listings: [(folder: String, listing: FolderListing)] = []
    /// The folders that the host says a shell cannot enter.
    private var missing: Set<String> = []
    /// When a request for a folder gave no clear answer: the lister asks
    /// again only after `retryAfter`, so that a host that is down is not
    /// asked at each redraw. The record stays while it asks again, so the
    /// screen keeps what it shows meanwhile.
    private var failed: [String: ContinuousClock.Instant] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    /// Called when a request ends, so that the screen draws its rows.
    var onChange: (@MainActor () -> Void)?

    /// The most folders whose listings stay. A screen types down one path,
    /// so it needs few. The one read last goes last.
    static let kept = 8
    /// How long a folder with no clear answer waits before the lister asks
    /// again (no connection yet, a slow host).
    static let retryAfter: Duration = .seconds(5)

    /// `list` asks the host about a folder as typed
    /// (`RemoteHosts.listFolders`).
    init(list: @escaping @MainActor (String) async -> HostFolderAnswer) {
        self.list = list
    }

    /// The listing of `folder` (as typed, with a slash at the end), or nil
    /// while it is asked or when the host gave none.
    func listing(_ folder: String) -> FolderListing? {
        if let index = listings.firstIndex(where: { $0.folder == folder }) {
            let kept = listings.remove(at: index)
            listings.append(kept)
            return kept.listing
        }
        if missing.contains(folder) { return nil }
        if let when = failed[folder], ContinuousClock.now - when < Self.retryAfter { return nil }
        if requests[folder] == nil {
            requests[folder] = Task { [weak self] in
                guard let self else { return }
                let answer = await list(folder)
                guard !Task.isCancelled else { return }
                requests[folder] = nil
                switch answer {
                case let .listed(listing):
                    failed[folder] = nil
                    listings.append((folder, listing))
                    if listings.count > Self.kept { listings.removeFirst() }
                case .missing:
                    failed[folder] = nil
                    missing.insert(folder)
                case .unavailable:
                    failed[folder] = .now
                }
                onChange?()
            }
        }
        return nil
    }

    /// The host says that a shell cannot enter `folder`.
    func isMissing(_ folder: String) -> Bool {
        missing.contains(folder)
    }

    /// The host gave no clear answer for `folder`, also while the lister
    /// asks again.
    func hasFailed(_ folder: String) -> Bool {
        failed[folder] != nil
    }

    /// The folder of the pane's process on the host (`paneFolder`): not
    /// asked yet, asked, or the answer.
    private var paneFolderAnswer: String??
    private var paneFolderRequest: Task<Void, Never>?

    /// The folder of the focused pane's process on the host, for the
    /// Current Pane's Directory row (UI review 0617). The first call asks
    /// with `read`, and `onChange` draws the screen again when the answer
    /// comes. The screen asks once. nil while it asks, and when the host
    /// gave no folder.
    func paneFolder(read: @escaping @MainActor () async -> String?) -> String? {
        if let paneFolderAnswer { return paneFolderAnswer }
        if paneFolderRequest == nil {
            paneFolderRequest = Task { [weak self] in
                let answer = await read()
                guard let self, !Task.isCancelled else { return }
                paneFolderRequest = nil
                paneFolderAnswer = .some(answer)
                onChange?()
            }
        }
        return nil
    }

    /// Whether a request is in flight.
    var isListing: Bool { !requests.isEmpty || paneFolderRequest != nil }

    /// Stop every request: the screen left.
    func cancel() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        paneFolderRequest?.cancel()
        paneFolderRequest = nil
    }
}
