import Foundation

/// The folders in one folder: its path from `/`, and the names of the
/// folders in it. A folder on a host asks the host
/// (`RemoteHosts.listFolders`).
struct FolderListing: Equatable {
    let path: String
    let names: [String]
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
        let parentText = parts.parent
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
        return children(of: parent, typedFolder: parentText, name: name, limit: limit)
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

    /// nil for a text that is not a path from `/` or `~`, and for `~name`
    /// with no slash, which names another user's home, not a folder in
    /// this one: no rows, as for a local path.
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
    private let list: @MainActor (String) async -> FolderListing?
    private let probe: (@MainActor (String) async -> RemoteHosts.FolderCheck?)?
    /// The listings that came, the newest last.
    private var listings: [(folder: String, listing: FolderListing)] = []
    /// The answers of `check(_:)` that came, the newest last.
    private var checks: [(path: String, answer: RemoteHosts.FolderCheck)] = []
    /// Whether the host answered a request once. A screen takes it as a sign
    /// that the connection is up; the connection can end later.
    private(set) var hasAnswered = false
    /// When a request for a folder gave no answer: the lister asks again
    /// only after `retryAfter`, so that a host that is down is not asked
    /// at each redraw.
    private var failed: [String: ContinuousClock.Instant] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    /// Called when a request ends, so that the screen draws its rows.
    var onChange: (@MainActor () -> Void)?

    /// The most folders whose listings stay. A screen types down one path,
    /// so it needs few. The oldest goes first.
    static let kept = 8
    /// How long a folder with no answer waits before the lister asks again
    /// (no connection yet, a slow host, a folder that is made later).
    static let retryAfter: Duration = .seconds(5)

    /// `list` asks the host for the listing of a folder as typed
    /// (`RemoteHosts.listFolders`). `probe` asks what a path is
    /// (`RemoteHosts.probeFolder`), for `check(_:)`.
    init(
        list: @escaping @MainActor (String) async -> FolderListing?,
        probe: (@MainActor (String) async -> RemoteHosts.FolderCheck?)? = nil
    ) {
        self.list = list
        self.probe = probe
    }

    /// The listing of `folder` (as typed, with a slash at the end), or nil
    /// while it is asked or when the host gave none.
    func listing(_ folder: String) -> FolderListing? {
        if let index = listings.firstIndex(where: { $0.folder == folder }) {
            // A read keeps the listing: the oldest unread one goes first.
            let kept = listings.remove(at: index)
            listings.append(kept)
            return kept.listing
        }
        if let when = failed[folder], ContinuousClock.now - when < Self.retryAfter { return nil }
        if requests[folder] == nil {
            requests[folder] = Task { [weak self] in
                guard let self else { return }
                let answer = await list(folder)
                guard !Task.isCancelled else { return }
                requests[folder] = nil
                if let answer {
                    failed[folder] = nil
                    hasAnswered = true
                    listings.append((folder, answer))
                    if listings.count > Self.kept { listings.removeFirst() }
                } else {
                    failed[folder] = .now
                }
                onChange?()
            }
        }
        return nil
    }

    /// What the path `path` is on the host, or nil while it is asked, when
    /// the host gave no answer, or with no `probe`. A screen asks it for a
    /// path that its listing does not show, so that it can tell a file from
    /// a missing path as the user types. The rules of `listing(_:)` apply.
    /// The host is asked only after `checkDelay` with no newer path, and a
    /// newer path stops the request of an older one: one keystroke does not
    /// start one command on the host.
    func check(_ path: String) -> RemoteHosts.FolderCheck? {
        guard let probe else { return nil }
        if let index = checks.firstIndex(where: { $0.path == path }) {
            return checks[index].answer
        }
        let key = Self.checkPrefix + path
        if let when = failed[key], ContinuousClock.now - when < Self.retryAfter { return nil }
        for (other, request) in requests where other.hasPrefix(Self.checkPrefix) && other != key {
            request.cancel()
            requests[other] = nil
        }
        if requests[key] == nil {
            requests[key] = Task { [weak self] in
                try? await Task.sleep(for: Self.checkDelay)
                guard let self, !Task.isCancelled else { return }
                let answer = await probe(path)
                guard !Task.isCancelled else { return }
                requests[key] = nil
                if let answer {
                    failed[key] = nil
                    hasAnswered = true
                    checks.append((path, answer))
                    if checks.count > Self.kept { checks.removeFirst() }
                } else {
                    failed[key] = .now
                }
                onChange?()
            }
        }
        return nil
    }

    private static let checkPrefix = "check:"
    /// How long `check(_:)` waits for the user to stop typing.
    static let checkDelay: Duration = .milliseconds(250)

    /// The folder of the pane's process on the host (`paneFolder`), and
    /// when an ask gave none, so that it is asked again after `retryAfter`.
    private var paneFolderAnswer: String?
    private var paneFolderFailed: ContinuousClock.Instant?
    private var paneFolderRequest: Task<Void, Never>?

    /// The folder of the focused pane's process on the host, for the
    /// Current Pane's Directory row (UI review 0617). The first call asks
    /// with `read`, and `onChange` draws the screen again when the answer
    /// comes. A folder is asked once. No folder (no pid yet, no connection,
    /// no answer in time) is asked again after `retryAfter`. nil while it
    /// asks, and while there is no folder.
    func paneFolder(read: @escaping @MainActor () async -> String?) -> String? {
        if let paneFolderAnswer { return paneFolderAnswer }
        if let paneFolderFailed, ContinuousClock.now - paneFolderFailed < Self.retryAfter { return nil }
        if paneFolderRequest == nil {
            paneFolderRequest = Task { [weak self] in
                let answer = await read()
                guard let self, !Task.isCancelled else { return }
                paneFolderRequest = nil
                paneFolderAnswer = answer
                paneFolderFailed = answer == nil ? .now : nil
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
