import Foundation

/// Why a typed path is not a folder, with the one notice for it. Every
/// input screen of a path uses it, local and remote (Ethan, 0579: one
/// message for each case for both kinds of project). A local screen asks
/// the file system (`local(atPath:)`). A remote screen asks the host
/// (`RemoteHosts.checkFolder`, whose `notDirectory` and `missing` answers
/// map to these cases).
enum PathProblem: Equatable {
    /// Nothing is at the path.
    case missing
    /// The path is a file, not a folder.
    case notDirectory

    /// The notice for `path`, as the user typed it (with `~`).
    func notice(for path: String) -> String {
        switch self {
        case .missing: String(localized: "Path \(path) doesn't exist")
        case .notDirectory: String(localized: "\(path) is not a directory")
        }
    }

    /// The problem of a local path, nil for a folder. A `~` expands. A
    /// relative path is the caller's to resolve first: this reads no
    /// working directory.
    static func local(atPath path: String) -> PathProblem? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .missing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? nil : .notDirectory
    }
}
