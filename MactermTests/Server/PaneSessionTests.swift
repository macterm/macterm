import Foundation
@testable import Macterm
import Testing

/// A pane session against the bundled server, in a runtime directory of its
/// own (see `LocalServerTests`), with a host that records what it is given.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneSessionTests {
    @Test
    func a_session_is_made_fed_and_ends_with_the_exit_status() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let session = try await PaneSession.made(
                name: "ps-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; exit 5"],
                    env: []
                ),
                wantsForeground: false,
                host: host,
                connect: { try await server.connect() }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            session.sendInput(Data("hi\n".utf8))
            try await host.waitFor { $0.exit != nil }
            let state = host.snapshot()
            #expect(state.screen.contains("got-hi"))
            #expect(state.exit?.code == 5)
            session.stop()
        }
    }

    @Test
    func the_size_goes_to_the_session_when_the_client_claims() async throws {
        try await withServer { server in
            let host = RecordingPaneHost(grid: PaneGrid(cols: 91, rows: 17))
            let session = try await PaneSession.made(
                name: "ps-size-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "sleep 1; stty size; sleep 30"], env: []),
                wantsForeground: false,
                host: host,
                connect: { try await server.connect() }
            )
            session.start()
            session.claim(grid: nil)
            try await host.waitFor { $0.screen.contains("17 91") }
            session.stop()
        }
    }

    @Test
    func the_host_hears_the_sessions_lead_for_each_client() async throws {
        try await withServer { server in
            let name = "ps-lead-\(UInt32.random(in: 0 ... .max))"
            let first = RecordingPaneHost()
            let a = try await PaneSession.made(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: first,
                connect: { try await server.connect() }
            )
            a.start()
            try await first.waitFor { $0.leads == [true] && $0.screen.contains("up-ok") }

            // A second client of the session does not lead, and hears so.
            let second = RecordingPaneHost()
            let b = PaneSession(name: name, wantsForeground: false, host: second, connect: { try await server.connect() })
            b.start()
            try await second.waitFor { $0.leads == [false] }

            b.claim(grid: nil)
            try await second.waitFor { $0.leads == [false, true] }
            try await first.waitFor { $0.leads == [true, false] }
            a.stop()
            b.stop()
        }
    }

    @Test
    func a_lost_connection_is_made_again_and_the_screen_is_drawn_again() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = ConnectionBox()
            let session = try await PaneSession.made(
                name: "ps-lost-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf before-%s lost; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                connect: { try await connections.next(server) }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("before-lost") }
            connections.current?.close()
            try await host.waitFor { $0.linkLost > 0 }
            try await host.waitFor { $0.resets >= 2 && $0.screen.contains("before-lost") }
            #expect(host.snapshot().leads.contains { $0 == nil }, "the lost channel forgets the lead")
            session.stop()
        }
    }

    @Test
    func input_after_a_lost_link_is_handed_back_and_not_dropped() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = ConnectionBox()
            let session = try await PaneSession.made(
                name: "ps-keep-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                reconnects: false,
                host: host,
                connect: { try await connections.next(server) }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            connections.current?.close()
            try await host.waitFor { $0.linkLost > 0 }
            let reports = host.snapshot().linkLost
            session.sendInput(Data("k".utf8))
            // The key comes back, and reports the lost link again: a pane
            // whose first report went missing must not stay frozen.
            try await host.waitFor { $0.undelivered == Data("k".utf8) && $0.linkLost == reports + 1 }
            session.stop()
        }
    }

    @Test
    func a_lost_link_with_no_reconnect_forgets_the_lead() async throws {
        // A remote pane's session does not reconnect. When its link stops,
        // the surface must not keep the lead of a client that is gone.
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = ConnectionBox()
            let session = try await PaneSession.made(
                name: "ps-nolead-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                reconnects: false,
                host: host,
                connect: { try await connections.next(server) }
            )
            session.start()
            try await host.waitFor { $0.leads == [true] && $0.screen.contains("up-ok") }
            connections.current?.close()
            try await host.waitFor { $0.linkLost > 0 }
            #expect(host.snapshot().leads == [true, nil])
            #expect(host.snapshot().linkLost == 1)
            session.stop()
        }
    }

    /// The session's flags reach every client, and a `seen` from one client
    /// clears them for both.
    @Test
    func the_attention_flags_reach_each_client_and_seen_clears_them() async throws {
        try await withServer { server in
            let name = "ps-seen-\(UInt32.random(in: 0 ... .max))"
            let first = RecordingPaneHost()
            let a = try await PaneSession.made(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "read l; printf '\\a'; sleep 60"], env: []),
                wantsForeground: false,
                host: first,
                connect: { try await server.connect() }
            )
            a.start()
            try await first.waitFor { $0.leads == [true] }
            let second = RecordingPaneHost()
            let b = PaneSession(name: name, wantsForeground: false, host: second, connect: { try await server.connect() })
            b.start()
            try await second.waitFor { $0.leads == [false] }

            a.sendInput(Data("\n".utf8))
            let bell = MactermProtocol.Attention(bell: true)
            try await first.waitFor { $0.attention.last == bell }
            try await second.waitFor { $0.attention.last == bell }

            b.seen()
            try await first.waitFor { $0.attention.last == MactermProtocol.Attention() }
            try await second.waitFor { $0.attention.last == MactermProtocol.Attention() }
            a.stop()
            b.stop()
        }
    }

    /// The session sends its flags at an attach only when one is set, so a
    /// channel that ends clears the host's copy.
    @Test
    func a_lost_link_clears_the_attention_flags() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = ConnectionBox()
            let session = try await PaneSession.made(
                name: "ps-flags-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf '\\a'; sleep 60"], env: []),
                wantsForeground: false,
                reconnects: false,
                host: host,
                connect: { try await connections.next(server) }
            )
            session.start()
            try await host.waitFor { $0.attention.last == MactermProtocol.Attention(bell: true) }
            connections.current?.close()
            try await host.waitFor { $0.linkLost > 0 }
            #expect(host.snapshot().attention.last == MactermProtocol.Attention())
            session.stop()
        }
    }

    @Test
    func a_session_that_was_killed_ends_the_pane_and_is_not_made_again() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let name = "ps-kill-\(UInt32.random(in: 0 ... .max))"
            let session = try await PaneSession.made(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf alive-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                connect: { try await server.connect() }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("alive-ok") }
            let other = try await server.connect()
            defer { other.close() }
            _ = try await other.call(MactermProtocol.SessionKill.self, .init(id: name))
            try await host.waitFor { $0.exit != nil }
            let sessions = try await other.call(MactermProtocol.SessionList.self, .init()).sessions
            #expect(sessions.isEmpty)
            session.stop()
        }
    }

    @Test
    func a_grid_that_changes_before_the_snapshot_gets_a_snapshot_for_the_new_grid() async throws {
        // A restored pane attaches in the incubator, then moves into its
        // tile before the snapshot comes. A snapshot laid out for the
        // incubator puts the cursor on the wrong row of the tile.
        try await withServer { server in
            let name = "ps-regrid-\(UInt32.random(in: 0 ... .max))"
            let wide = PaneGrid(cols: 100, rows: 10)
            let first = RecordingPaneHost(grid: wide)
            let a = try await PaneSession.made(
                name: name,
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf '%060d\\n' 0; printf END; sleep 60"],
                    env: []
                ),
                wantsForeground: false,
                host: first,
                connect: { try await server.connect() }
            )
            a.start()
            try await first.waitFor { $0.screen.contains("END") }
            a.stop()

            let narrow = PaneGrid(cols: 30, rows: 10)
            let box = SessionBox()
            let second = RecordingPaneHost(grid: wide) { [box] in
                box.host?.setGrid(narrow)
                box.session?.sendSize(narrow)
            }
            let b = PaneSession(name: name, wantsForeground: false, host: second, connect: { try await server.connect() })
            box.set(session: b, host: second)
            b.start()
            try await second.waitFor { $0.snapshots.contains { $0.contains("END") } }
            // At 30 columns the line of 60 takes rows 1 and 2, and END is on
            // row 3. At 100 columns it would be on row 2.
            let drawn = second.snapshot().snapshots
            #expect(drawn.count == 1)
            #expect(drawn.last?.contains("\u{1B}[3;4H") == true, "\(drawn.last.debugDescription)")
            b.stop()
        }
    }

    // MARK: - Input before the shell starts

    /// A shell that prints its prompt mark after a delay, as a login shell
    /// does, then reads one line.
    private static let markedShell =
        "sleep 0.3; printf '\\033]133;A\\007$ \\033]133;B\\007'; read l; printf 'got-%s' \"$l\"; read m; printf 'twice-%s' \"$m\"; sleep 30"

    @Test
    func input_before_the_attach_waits_for_the_prompt_mark() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let session = try await PaneSession.made(
                name: "ps-mark-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", Self.markedShell], env: []),
                wantsForeground: false,
                startWait: .seconds(30),
                host: host,
                connect: { try await server.connect() }
            )
            session.sendInput(Data("hi\n".utf8))
            session.start()
            try await host.waitFor { $0.screen.contains("got-hi") }
            // The pty echoes the line when it comes: after the prompt, never
            // before it.
            let screen = host.snapshot().screen
            let prompt = try #require(screen.range(of: "$ "))
            let echo = try #require(screen.range(of: "hi"))
            #expect(prompt.lowerBound < echo.lowerBound)
            session.stop()
        }
    }

    @Test
    func input_for_a_session_at_its_prompt_goes_with_no_wait() async throws {
        // The mark came before this client greeted: the session tells it
        // from the screen.
        try await withServer { server in
            let name = "ps-atprompt-\(UInt32.random(in: 0 ... .max))"
            let first = RecordingPaneHost()
            let a = try await PaneSession.made(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", Self.markedShell], env: []),
                wantsForeground: false,
                host: first,
                connect: { try await server.connect() }
            )
            a.start()
            try await first.waitFor { $0.screen.contains("$ ") }

            let second = RecordingPaneHost()
            let b = PaneSession(
                name: name,
                wantsForeground: false,
                startWait: .seconds(30),
                host: second,
                connect: { try await server.connect() }
            )
            b.sendInput(Data("hi\n".utf8))
            b.start()
            try await first.waitFor { $0.screen.contains("got-hi") }
            a.stop()
            b.stop()
        }
    }

    @Test
    func input_for_a_shell_with_no_marks_goes_after_the_wait() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let session = try await PaneSession.made(
                name: "ps-nomark-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; sleep 30"],
                    env: []
                ),
                wantsForeground: false,
                startWait: .milliseconds(300),
                host: host,
                connect: { try await server.connect() }
            )
            session.sendInput(Data("hi\n".utf8))
            session.start()
            try await host.waitFor { $0.screen.contains("got-hi") }
            session.stop()
        }
    }

    @Test
    func input_after_the_attach_does_not_wait() async throws {
        // Terminal replies come after the attach: a shell can query the
        // terminal before its first prompt and wait for the answer.
        try await withServer { server in
            let host = RecordingPaneHost()
            let session = try await PaneSession.made(
                name: "ps-reply-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; sleep 30"],
                    env: []
                ),
                wantsForeground: false,
                startWait: .seconds(30),
                host: host,
                connect: { try await server.connect() }
            )
            session.sendInput(Data("early\n".utf8))
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            session.sendInput(Data("reply\n".utf8))
            try await host.waitFor { $0.screen.contains("got-reply") }
            session.stop()
        }
    }

    @Test
    func held_input_goes_once() async throws {
        // The mark sends the input. The wait that ends later sends nothing.
        try await withServer { server in
            let host = RecordingPaneHost()
            let session = try await PaneSession.made(
                name: "ps-once-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", Self.markedShell], env: []),
                wantsForeground: false,
                startWait: .milliseconds(1500),
                host: host,
                connect: { try await server.connect() }
            )
            session.sendInput(Data("hi\n".utf8))
            session.start()
            try await host.waitFor { $0.screen.contains("got-hi") }
            try await Task.sleep(for: .seconds(2))
            #expect(!host.snapshot().screen.contains("twice-"))
            session.stop()
        }
    }

    @Test
    func held_input_is_not_sent_after_the_pane_closed() async throws {
        try await withServer { server in
            let name = "ps-closed-\(UInt32.random(in: 0 ... .max))"
            let host = RecordingPaneHost()
            let session = try await PaneSession.made(
                name: name,
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; sleep 30"],
                    env: []
                ),
                wantsForeground: false,
                startWait: .seconds(1),
                host: host,
                connect: { try await server.connect() }
            )
            session.sendInput(Data("hi\n".utf8))
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            session.stop()
            #expect(session.takePendingInput() == Data("hi\n".utf8))
            try await Task.sleep(for: .seconds(1.5))

            // Another client sees the session's screen: the line never came.
            let viewer = RecordingPaneHost()
            let other = PaneSession(name: name, wantsForeground: false, host: viewer, connect: { try await server.connect() })
            other.start()
            try await viewer.waitFor { $0.screen.contains("up-ok") }
            #expect(!viewer.snapshot().screen.contains("hi"))
            other.stop()
        }
    }

    // MARK: - Support

    /// The session and host of a test, for a host's hook.
    final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (PaneSession, RecordingPaneHost)?
        var session: PaneSession? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.0
        }

        var host: RecordingPaneHost? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.1
        }

        func set(session: PaneSession, host: RecordingPaneHost) {
            lock.lock()
            stored = (session, host)
            lock.unlock()
        }
    }

    /// Holds the connection that a session got, so that a test can end it.
    final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ServerConnection?
        var current: ServerConnection? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func next(_ server: LocalServer) async throws -> ServerConnection {
            let connection = try await server.connect()
            store(connection)
            return connection
        }

        private func store(_ connection: ServerConnection) {
            lock.lock()
            stored = connection
            lock.unlock()
        }
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

struct RemotePaneDriverTests {
    @Test
    func a_line_of_macterm_starts_on_a_line_of_its_own_and_ends_with_cr_lf() {
        #expect(RemotePaneDriver.paneText("box refuses.\nPress a key.") == "\r\nbox refuses.\r\nPress a key.\r\n")
    }
}
