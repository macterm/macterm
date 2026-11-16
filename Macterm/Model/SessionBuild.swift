import Foundation

/// Which sessions run an older build than the app (design/002, option A).
/// A session keeps the build that started it, and an update never changes
/// it. The tab shows one badge for it, and Restart Session cures it.
///
/// A session reports its build key (`build_key` in `session.list`). The app
/// compares it with the key of the bundled server (`ServerBuilds.bundledKey`).
/// Two keys that differ mean another build. Each build flavor has its own
/// runtime folder, so a session of another build is an older one. If either
/// side has no key, nothing is known, and nothing is marked.
enum SessionBuild {
    /// Whether the session's build key is another than `appKey`.
    static func isOlder(_ sessionKey: String?, appKey: String?) -> Bool {
        guard let appKey, let sessionKey else { return false }
        return sessionKey != appKey
    }

    /// The names of the running sessions that are older than the app.
    static func outdatedNames(in sessions: [LocalSession], appKey: String?) -> Set<String> {
        Set(sessions.filter { $0.isRunning && isOlder($0.buildKey, appKey: appKey) }.map(\.name))
    }
}
