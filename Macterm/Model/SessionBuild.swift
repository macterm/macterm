import Foundation

/// Which sessions run an older build than the app (design/002, option A).
/// A session keeps the build that started it, and an update never changes
/// it. The tab shows one badge for it, and Restart Session cures it.
///
/// A session reports its build key (`build_key` in `session.list`). The app
/// compares it with the key of the bundled server (`ServerBuilds.bundledKey`).
/// Two keys that differ mean another build. Each build flavor has its own
/// runtime folder, so a session of another build is an older one. If either
/// side has no key, the key marks nothing.
///
/// A session whose own file an update deleted is older too, also with the
/// same key: an update that did not change the server still replaces the
/// bundle. Each session process is the responsible process of its programs,
/// and tccd denies every protected folder (Documents, Desktop, Downloads)
/// to a process with no file (server/AGENTS.md, "Session daemons and macOS
/// attribution"). Only a restart from the new bundle gives the access back.
enum SessionBuild {
    /// Whether the session's build key is another than `appKey`.
    static func isOlder(_ sessionKey: String?, appKey: String?) -> Bool {
        guard let appKey, let sessionKey else { return false }
        return sessionKey != appKey
    }

    /// The names of the running sessions that are older than the app.
    /// `executableIsDeleted` is asked for each session process
    /// (`ProcessInspector.executableIsDeleted`).
    static func outdatedNames(
        in sessions: [LocalSession],
        appKey: String?,
        executableIsDeleted: (pid_t) -> Bool = ProcessInspector.executableIsDeleted
    ) -> Set<String> {
        Set(sessions.filter { session in
            guard session.isRunning else { return false }
            if isOlder(session.buildKey, appKey: appKey) { return true }
            return session.pid.map(executableIsDeleted) ?? false
        }.map(\.name))
    }
}
