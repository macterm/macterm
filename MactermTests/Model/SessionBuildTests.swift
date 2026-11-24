import Foundation
@testable import Macterm
import Testing

struct SessionBuildTests {
    private func session(_ name: String, key: String?, running: Bool = true) -> SessionInfo {
        SessionInfo(name: name, isRunning: running, buildKey: key)
    }

    @Test
    func a_session_of_another_build_is_older() {
        #expect(SessionBuild.isOlder("aaa111", appKey: "bbb222"))
    }

    @Test
    func a_session_of_the_same_build_is_not_marked() {
        #expect(!SessionBuild.isOlder("bbb222", appKey: "bbb222"))
    }

    @Test
    func nothing_is_marked_when_a_side_has_no_key() {
        #expect(!SessionBuild.isOlder(nil, appKey: "bbb222"))
        #expect(!SessionBuild.isOlder("aaa111", appKey: nil))
    }

    @Test
    func only_running_sessions_of_another_build_are_listed() {
        let sessions = [
            session("old", key: "aaa111"),
            session("new", key: "bbb222"),
            session("gone", key: "aaa111", running: false),
            session("unknown", key: nil),
        ]
        #expect(SessionBuild.outdatedNames(in: sessions, appKey: "bbb222", executableIsDeleted: { _ in false }) == ["old"])
    }

    @Test
    func a_session_whose_file_an_update_deleted_is_older_with_the_same_key() {
        let sessions = [
            SessionInfo(name: "stale", pid: 101, buildKey: "bbb222"),
            SessionInfo(name: "current", pid: 102, buildKey: "bbb222"),
            SessionInfo(name: "stale-exited", pid: 103, isRunning: false, buildKey: "bbb222"),
            SessionInfo(name: "no-pid", buildKey: "bbb222"),
            SessionInfo(name: "no-key", pid: 104, buildKey: nil),
        ]
        let deleted: Set<pid_t> = [101, 103, 104]
        let names = SessionBuild.outdatedNames(in: sessions, appKey: "bbb222") { deleted.contains($0) }
        #expect(names == ["stale", "no-key"])
    }
}
