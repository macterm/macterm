import Foundation

/// The directories that a typed local path can complete to — the one
/// completer of the palette. Path mode of the root (`DirectorySource`) and
/// the folder rows of an input screen
/// (`AppState.changeProjectDirectoryChoices`) both read it, so a typed
/// path completes the same way in both.
///
/// `~` expands to the home directory. A typed directory lists its children;
/// any other path lists the children of its parent whose name starts with
/// the last component (folded as `Search` folds). Only directories, sorted,
/// at most `limit`. Hidden directories show only after a typed dot, so
/// `~/.conf` completes `.config` and `~/` does not list it.
///
/// Local paths only: a remote spec (`devbox:~/api`) never expands to an
/// absolute path, so it gets no completion. Nothing asks the host.
enum PathCompleter {
    /// What a typed path completes to.
    struct Completion: Equatable {
        /// The typed path, expanded, when it names a directory itself.
        let exactMatch: String?
        /// The full paths of the directories that complete it.
        let children: [String]
    }

    /// Nil when `typed` is not an absolute path after `~` expands, or when
    /// the directory it lists does not exist.
    static func complete(_ typed: String, limit: Int = 10) -> Completion? {
        let expanded = (typed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }

        let fm = FileManager.default
        let dir: String
        let prefix: String
        let exactMatch: String?
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            dir = expanded
            prefix = ""
            exactMatch = expanded
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
            exactMatch = nil
        }
        guard fm.fileExists(atPath: dir) else { return nil }

        let children = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { name in
                let full = (dir as NSString).appendingPathComponent(name)
                var childIsDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &childIsDir), childIsDir.boolValue else { return false }
                if !prefix.hasPrefix("."), name.hasPrefix(".") { return false }
                if prefix.isEmpty { return true }
                // Completion, not search: a prefix.
                return Search.hasPrefix(name, prefix)
            }
            // `contentsOfDirectory` order is unspecified; sort so both which
            // children survive the cap and their order are the same on every
            // run and filesystem.
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(limit)
            .map { (dir as NSString).appendingPathComponent($0) }
        return Completion(exactMatch: exactMatch, children: Array(children))
    }

    /// The text that the field takes when it completes to `path`: with a
    /// trailing slash, so that the next completion descends into it, and
    /// with `~` again when the user typed it.
    static func fieldText(for path: String, typed: String) -> String {
        // Abbreviate first: `abbreviatingWithTildeInPath` drops a trailing
        // slash.
        let text = typed.hasPrefix("~") ? (path as NSString).abbreviatingWithTildeInPath : path
        return text.hasSuffix("/") ? text : text + "/"
    }
}
