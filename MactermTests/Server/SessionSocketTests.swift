import Darwin
import Foundation
@testable import Macterm
import Testing

/// A local pane's channel on its session's own socket (`SessionSockets`),
/// through `LocalSessions`, against the bundled server in a runtime
/// directory of its own (see `LocalServerTests`).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionSocketTests {
    /// The server makes the session. Then the bytes go to the session's own
    /// socket: a server that dies does not stop typing.
    @Test
    func a_local_pane_types_after_its_server_is_killed() async throws {
        try await withServer { server in
            let sessions = LocalSessions(server: server)
            let host = RecordingPaneHost()
            let session = PaneSession(
                name: "ss-kill-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "while read l; do printf 'got-%s.' \"$l\"; done"],
                    env: []
                ),
                wantsForeground: false,
                host: host,
                endpoint: sessions
            )
            session.start()
            session.sendInput(Data("a\n".utf8))
            try await host.waitFor { $0.screen.contains("got-a.") }

            let probe = try ServerConnection.connect(path: server.socketPath)
            let pid = try #require(probe.serverPID)
            probe.close()
            #expect(kill(pid, SIGKILL) == 0)
            // The server is gone: its socket answers no more.
            let deadline = Date().addingTimeInterval(10)
            while (try? ServerConnection.connect(path: server.socketPath))?.close() != nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect((try? ServerConnection.connect(path: server.socketPath)) == nil)

            session.sendInput(Data("b\n".utf8))
            try await host.waitFor { $0.screen.contains("got-b.") }
            let state = host.snapshot()
            #expect(state.linkLost == 0, "the channel does not pass through the server")
            #expect(state.exit == nil)
            session.stop()
            // A new server finds the session, so that the clean-up ends it.
            #expect(await sessions.list()?.isEmpty == false)
        }
    }

    /// Two windows show one pane: each view has a connection of its own to
    /// the session, and the session tells each one whether it leads.
    @Test
    func two_views_on_the_session_socket_hear_the_lead() async throws {
        try await withServer { server in
            let sessions = LocalSessions(server: server)
            let name = "ss-lead-\(UInt32.random(in: 0 ... .max))"
            let first = RecordingPaneHost()
            let a = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: first,
                endpoint: sessions
            )
            a.start()
            try await first.waitFor { $0.leads == [true] && $0.screen.contains("up-ok") }
            let second = RecordingPaneHost()
            let b = PaneSession(name: name, launch: nil, wantsForeground: false, host: second, endpoint: sessions)
            b.start()
            try await second.waitFor { $0.leads == [false] && $0.screen.contains("up-ok") }
            b.claim(grid: nil)
            try await first.waitFor { $0.leads == [true, false] }
            try await second.waitFor { $0.leads == [false, true] }
            a.stop()
            b.stop()
        }
    }

    /// The exit comes on the session's socket, which the server does not
    /// see. The channel tells the server, which then ends the session.
    @Test
    func an_exit_on_the_session_socket_ends_the_session() async throws {
        try await withServer { server in
            let sessions = LocalSessions(server: server)
            let host = RecordingPaneHost()
            let name = "ss-exit-\(UInt32.random(in: 0 ... .max))"
            let session = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "read l; exit 5"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: sessions
            )
            session.start()
            session.sendInput(Data("x\n".utf8))
            try await host.waitFor { $0.exit != nil }
            #expect(host.snapshot().exit?.code == 5)
            let path = server.directory.appending(path: name).path
            let deadline = Date().addingTimeInterval(10)
            while Self.listens(path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(!Self.listens(path), "the server ended the session")
            session.stop()
        }
    }

    /// A session that ends with no exit status closes its socket. The
    /// channel finds no session at the next connect: the pane exits.
    @Test
    func a_killed_session_ends_the_pane_with_no_status() async throws {
        try await withServer { server in
            let sessions = LocalSessions(server: server)
            let host = RecordingPaneHost()
            let name = "ss-end-\(UInt32.random(in: 0 ... .max))"
            let session = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: sessions
            )
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            await sessions.kill(name)
            try await host.waitFor { $0.exit != nil }
            #expect(host.snapshot().gone == 0)
            session.stop()
        }
    }

    // MARK: - Support

    private static func listens(_ path: String) -> Bool {
        guard let fd = try? ServerConnection.connectSocket(path: path) else { return false }
        close(fd)
        return true
    }

    private func withServer(_ body: (LocalServer) async throws -> Void) async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)
        do {
            try await body(server)
        } catch {
            await Self.cleanUp(server)
            throw error
        }
        await Self.cleanUp(server)
    }

    private static func cleanUp(_ server: LocalServer) async {
        guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
        for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
            _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
        }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }
}
