import Foundation

/// The folders in one folder: its path from `/`, and the names of the
/// folders in it. A local folder reads the file system
/// (`FolderListing.local`). A folder on a host asks the host
/// (`RemoteHosts.listFolders`).
struct FolderListing: Equatable {
    let path: String
    let names: [String]

    /// The listing of a local folder, as `PathCompleter` reads it: `~`
    /// expands, and a link to a folder counts as a folder. nil when the
    /// folder is not there.
    static func local(_ directory: String) -> FolderListing? {
        let expanded = (directory as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: expanded)
        else { return nil }
        let path = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        let folders = names.filter { name in
            var childIsDirectory: ObjCBool = false
            let full = (path as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: full, isDirectory: &childIsDirectory) && childIsDirectory.boolValue
        }
        return FolderListing(path: path, names: folders)
    }
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
        guard typed.hasPrefix("/") || typed.hasPrefix("~") else { return nil }
        let text = typed == "~" ? "~/" : typed
        let parentText: String
        let name: String
        if text.hasSuffix("/") {
            parentText = text
            name = ""
        } else {
            let cut = text.index(after: text.lastIndex(of: "/") ?? text.startIndex)
            parentText = String(text[..<cut])
            name = String(text[cut...])
        }
        guard let parent = listing(parentText) else { return nil }
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
    private var listings: [String: FolderListing?] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    /// Called when a listing comes, so that the screen draws its rows.
    var onChange: (@MainActor () -> Void)?

    /// The most folders whose listings stay. A screen types down one path,
    /// so it needs few.
    static let kept = 8

    /// `list` asks the host for the listing of a folder as typed
    /// (`RemoteHosts.listFolders`).
    init(list: @escaping @MainActor (String) async -> FolderListing?) {
        self.list = list
    }

    /// The listing of `folder` (as typed, with a slash at the end), or nil
    /// while it is asked or when the host gave none.
    func listing(_ folder: String) -> FolderListing? {
        if let kept = listings[folder] { return kept }
        if requests[folder] == nil {
            requests[folder] = Task { [weak self] in
                guard let self else { return }
                let answer = await list(folder)
                guard !Task.isCancelled else { return }
                requests[folder] = nil
                if listings.count >= Self.kept { listings.removeAll() }
                listings[folder] = .some(answer)
                onChange?()
            }
        }
        return nil
    }

    /// Whether a request is in flight.
    var isListing: Bool { !requests.isEmpty }

    /// Stop every request: the screen left.
    func cancel() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }
}
