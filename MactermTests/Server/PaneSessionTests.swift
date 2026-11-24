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
            let session = PaneSession(
                name: "ps-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; exit 5"],
                    env: []
                ),
                wantsForeground: false,
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let session = PaneSession(
                name: "ps-size-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "sleep 1; stty size; sleep 30"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let a = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: first,
                endpoint: TestServerEndpoint(server)
            )
            a.start()
            try await first.waitFor { $0.leads == [true] && $0.screen.contains("up-ok") }

            // A second client of the session does not lead, and hears so.
            let second = RecordingPaneHost()
            let b = PaneSession(name: name, launch: nil, wantsForeground: false, host: second, endpoint: TestServerEndpoint(server))
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
    func a_lost_connection_is_made_again_and_resumes_with_the_screen_and_scrollback_kept() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = TestServerEndpoint(server)
            let session = PaneSession(
                name: "ps-lost-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf before-%s lost; read l; printf after-%s \"$l\"; sleep 60"],
                    env: []
                ),
                wantsForeground: false,
                host: host,
                endpoint: connections
            )
            session.start()
            try await host.waitFor { $0.screen.contains("before-lost") && $0.leads == [true] }
            connections.current?.close()
            try await host.waitFor { $0.linkLost > 0 }
            // The new channel asks to resume: the session sends only the
            // bytes after the offset, and draws no snapshot.
            try await host.waitFor { $0.leads.count >= 3 && $0.leads.last == true }
            #expect(await session.resumePoint != nil)
            session.sendInput(Data("x\n".utf8))
            try await host.waitFor { $0.screen.contains("after-x") }
            let state = host.snapshot()
            #expect(state.resets == 1, "a resume keeps the screen and the scrollback")
            #expect(state.screen.components(separatedBy: "before-lost").count == 2, "no byte comes twice")
            session.stop()
        }
    }

    @Test
    func input_after_a_lost_link_is_handed_back_and_not_dropped() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = TestServerEndpoint(server, once: true)
            let session = PaneSession(
                name: "ps-keep-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: connections
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
    func a_lost_link_with_no_next_connection_forgets_the_lead() async throws {
        // A host's link gives no next connection. When it stops, the
        // surface must not keep the lead of a client that is gone.
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = TestServerEndpoint(server, once: true)
            let session = PaneSession(
                name: "ps-nolead-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf up-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: connections
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
            let a = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "read l; printf '\\a'; sleep 60"], env: []),
                wantsForeground: false,
                host: first,
                endpoint: TestServerEndpoint(server)
            )
            a.start()
            try await first.waitFor { $0.leads == [true] }
            let second = RecordingPaneHost()
            let b = PaneSession(name: name, launch: nil, wantsForeground: false, host: second, endpoint: TestServerEndpoint(server))
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
            let connections = TestServerEndpoint(server, once: true)
            let session = PaneSession(
                name: "ps-flags-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf '\\a'; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: connections
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
            let session = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf alive-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let a = PaneSession(
                name: name,
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf '%060d\\n' 0; printf END; sleep 60"],
                    env: []
                ),
                wantsForeground: false,
                host: first,
                endpoint: TestServerEndpoint(server)
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
            let b = PaneSession(name: name, launch: nil, wantsForeground: false, host: second, endpoint: TestServerEndpoint(server))
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
            let session = PaneSession(
                name: "ps-mark-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", Self.markedShell], env: []),
                wantsForeground: false,
                startWait: .seconds(30),
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let a = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", Self.markedShell], env: []),
                wantsForeground: false,
                host: first,
                endpoint: TestServerEndpoint(server)
            )
            a.start()
            try await first.waitFor { $0.screen.contains("$ ") }

            let second = RecordingPaneHost()
            let b = PaneSession(
                name: name,
                launch: nil,
                wantsForeground: false,
                startWait: .seconds(30),
                host: second,
                endpoint: TestServerEndpoint(server)
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
            let session = PaneSession(
                name: "ps-nomark-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; sleep 30"],
                    env: []
                ),
                wantsForeground: false,
                startWait: .milliseconds(300),
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let session = PaneSession(
                name: "ps-reply-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; sleep 30"],
                    env: []
                ),
                wantsForeground: false,
                startWait: .seconds(30),
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let session = PaneSession(
                name: "ps-once-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", Self.markedShell], env: []),
                wantsForeground: false,
                startWait: .milliseconds(1500),
                host: host,
                endpoint: TestServerEndpoint(server)
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
            let session = PaneSession(
                name: name,
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; sleep 30"],
                    env: []
                ),
                wantsForeground: false,
                startWait: .seconds(1),
                host: host,
                endpoint: TestServerEndpoint(server)
            )
            session.sendInput(Data("hi\n".utf8))
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            #expect(await session.finish().pendingInput == Data("hi\n".utf8))
            try await Task.sleep(for: .seconds(1.5))

            // Another client sees the session's screen: the line never came.
            let viewer = RecordingPaneHost()
            let other = PaneSession(name: name, launch: nil, wantsForeground: false, host: viewer, endpoint: TestServerEndpoint(server))
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

/// A pane session over in-memory links (`FakeServerLink`): the rule for a
/// lost link, with no server.
@Suite(.timeLimit(.minutes(1)))
struct PaneSessionEndpointTests {
    private static let launch = PaneSession.Launch(cwd: "/tmp", argv: ["/bin/sh"], env: [])

    /// The session's first lead and snapshot on `link`.
    private static func attach(_ link: FakeServerLink, _ name: String, screen: String) {
        link.deliver(MactermProtocol.Lead(leader: true), to: name)
        link.deliver(MactermProtocol.SnapshotStart(scrollback: false), to: name)
        link.deliver(output: screen, to: name)
        link.deliver(MactermProtocol.SnapshotEnd(), to: name)
    }

    @Test
    func a_lost_link_asks_the_endpoint_again_and_draws_the_new_snapshot() async throws {
        let first = FakeServerLink()
        let second = FakeServerLink()
        let endpoint = FakeEndpoint([first, second])
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: Self.launch, wantsForeground: false, host: host, endpoint: endpoint)
        session.start()
        try await host.waitFor { _ in first.sent(on: "s").contains(MactermProtocol.Attach.name) }
        Self.attach(first, "s", screen: "one")
        try await host.waitFor { $0.screen == "one" }

        first.close()
        try await host.waitFor { _ in second.sent(on: "s").contains(MactermProtocol.Attach.name) }
        Self.attach(second, "s", screen: "two")
        try await host.waitFor { $0.screen == "two" }
        let state = host.snapshot()
        #expect(state.linkLost == 1)
        #expect(state.gone == 0)
        #expect(state.leads == [true, nil, true])
        // Only the first attach makes the session.
        #expect(first.calls.contains(MactermProtocol.SessionCreate.name))
        #expect(!second.calls.contains(MactermProtocol.SessionCreate.name))
        session.stop()
    }

    @Test
    func a_lost_link_resumes_after_the_last_output_byte_and_keeps_the_screen() async throws {
        let first = FakeServerLink(epoch: 7)
        let second = FakeServerLink(epoch: 7)
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: FakeEndpoint([first, second]))
        session.start()
        try await host.waitFor { _ in first.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(first.attaches(on: "s").first?.resumeEpoch == nil)
        first.deliver(MactermProtocol.Lead(leader: true), to: "s")
        first.deliver(MactermProtocol.SnapshotStart(scrollback: true, offset: 100), to: "s")
        first.deliver(output: "one", to: "s")
        first.deliver(MactermProtocol.SnapshotEnd(), to: "s")
        first.deliver(output: "two", to: "s")
        try await host.waitFor { $0.screen == "onetwo" }

        first.close()
        try await host.waitFor { _ in second.sent(on: "s").contains(MactermProtocol.Attach.name) }
        let attach = try #require(second.attaches(on: "s").first)
        #expect(attach.resumeEpoch == 7)
        #expect(attach.resumeOffset == 103, "the snapshot's offset and the 3 output bytes after it")
        #expect(await session.resumePoint == PaneSession.ResumePoint(epoch: 7, offset: 103))
        second.deliver(MactermProtocol.Resumed(offset: 103), to: "s")
        second.deliver(output: "three", to: "s")
        try await host.waitFor { $0.screen == "onetwothree" }
        #expect(host.snapshot().resets == 1, "only the first attach clears the screen")

        // A skip-ahead snapshot after the resume sets the count again.
        second.deliver(MactermProtocol.SnapshotStart(scrollback: false, offset: 500), to: "s")
        second.deliver(output: "screen", to: "s")
        second.deliver(MactermProtocol.SnapshotEnd(), to: "s")
        second.deliver(output: "!", to: "s")
        try await host.waitFor { $0.screen.hasSuffix("screen!") }
        #expect(host.snapshot().resets == 1, "a skip-ahead snapshot clears its own screen, not the scrollback")
        second.close()
        try await host.waitFor { $0.gone == 1 }
        #expect(await session.resumePoint == PaneSession.ResumePoint(epoch: 7, offset: 501))
        session.stop()
    }

    @Test
    func a_new_epoch_or_a_lost_offset_draws_the_snapshot_over_a_cleared_screen() async throws {
        let first = FakeServerLink(epoch: 7)
        let restarted = FakeServerLink(epoch: 8)
        let third = FakeServerLink(epoch: 8)
        let host = RecordingPaneHost()
        let session = PaneSession(
            name: "s", launch: nil, wantsForeground: false, host: host,
            endpoint: FakeEndpoint([first, restarted, third])
        )
        session.start()
        try await host.waitFor { _ in first.sent(on: "s").contains(MactermProtocol.Attach.name) }
        first.deliver(output: "one", to: "s")
        try await host.waitFor { $0.screen == "one" }

        // Another epoch: the session process is another one. No resume.
        first.close()
        try await host.waitFor { _ in restarted.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(restarted.attaches(on: "s").first?.resumeEpoch == nil)
        restarted.deliver(MactermProtocol.SnapshotStart(scrollback: true, offset: 50), to: "s")
        restarted.deliver(output: "two", to: "s")
        restarted.deliver(MactermProtocol.SnapshotEnd(), to: "s")
        try await host.waitFor { $0.screen == "two" }
        #expect(host.snapshot().resets == 2)

        // The ring lost the bytes: the session answers with a snapshot.
        restarted.close()
        try await host.waitFor { _ in third.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(third.attaches(on: "s").first?.resumeEpoch == 8)
        #expect(third.attaches(on: "s").first?.resumeOffset == 50)
        Self.attach(third, "s", screen: "three")
        try await host.waitFor { $0.screen == "three" }
        #expect(host.snapshot().resets == 3)
        session.stop()
    }

    @Test
    func a_resume_point_from_an_earlier_session_keeps_the_screen_at_the_first_attach() async throws {
        let link = FakeServerLink(epoch: 7)
        let host = RecordingPaneHost()
        let session = PaneSession(
            name: "s", launch: nil, wantsForeground: false,
            resume: .init(epoch: 7, offset: 42),
            host: host, endpoint: FakeEndpoint([link])
        )
        session.start()
        try await host.waitFor { _ in link.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(link.attaches(on: "s").first?.resumeOffset == 42)
        link.deliver(MactermProtocol.Resumed(offset: 42), to: "s")
        link.deliver(output: "more", to: "s")
        try await host.waitFor { $0.screen == "more" }
        #expect(host.snapshot().resets == 0)
        session.stop()
    }

    @Test
    func finish_waits_for_the_reading_and_gives_the_offset_of_the_last_byte() async throws {
        let link = FakeServerLink(epoch: 7)
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        session.start()
        try await host.waitFor { _ in link.sent(on: "s").contains(MactermProtocol.Attach.name) }
        link.deliver(output: "abc", to: "s")
        try await host.waitFor { $0.screen == "abc" }
        // The channel is still open: a key that found the link down ends a
        // remote pane's session while it reads.
        #expect(await session.finish().resume == PaneSession.ResumePoint(epoch: 7, offset: 3))
    }

    @Test
    func a_link_that_drops_before_resumed_keeps_the_resume_point() async throws {
        let first = FakeServerLink(epoch: 7)
        let second = FakeServerLink(epoch: 7)
        let host = RecordingPaneHost()
        let session = PaneSession(
            name: "s", launch: nil, wantsForeground: false,
            resume: .init(epoch: 7, offset: 42),
            host: host, endpoint: FakeEndpoint([first, second])
        )
        session.start()
        try await host.waitFor { _ in first.sent(on: "s").contains(MactermProtocol.Attach.name) }
        first.close()
        try await host.waitFor { _ in second.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(second.attaches(on: "s").first?.resumeOffset == 42)
        #expect(host.snapshot().resets == 0)
        session.stop()
    }

    @Test
    func a_drop_before_the_snapshot_of_another_epoch_leaves_no_resume_point() async throws {
        let first = FakeServerLink(epoch: 7)
        let restarted = FakeServerLink(epoch: 8)
        let third = FakeServerLink(epoch: 8)
        let host = RecordingPaneHost()
        let session = PaneSession(
            name: "s", launch: nil, wantsForeground: false, host: host,
            endpoint: FakeEndpoint([first, restarted, third])
        )
        session.start()
        try await host.waitFor { _ in first.sent(on: "s").contains(MactermProtocol.Attach.name) }
        first.deliver(output: "one", to: "s")
        try await host.waitFor { $0.screen == "one" }
        first.close()
        // The screen still shows the old session: its offsets are not the
        // new session's.
        try await host.waitFor { _ in restarted.sent(on: "s").contains(MactermProtocol.Attach.name) }
        restarted.close()
        try await host.waitFor { _ in third.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(third.attaches(on: "s").first?.resumeEpoch == nil)
        session.stop()
    }

    @Test
    func an_endpoint_with_no_next_connection_ends_the_session_once() async throws {
        let link = FakeServerLink()
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        session.start()
        try await host.waitFor { _ in link.sent(on: "s").contains(MactermProtocol.Attach.name) }
        Self.attach(link, "s", screen: "up")
        try await host.waitFor { $0.screen == "up" }

        link.close()
        try await host.waitFor { $0.gone == 1 }
        let state = host.snapshot()
        #expect(state.linkLost == 1)
        #expect(state.leads == [true, nil])
        #expect(state.attention.last == MactermProtocol.Attention())
        // A key after the end comes back to the host.
        session.sendInput(Data("k".utf8))
        try await host.waitFor { $0.undelivered == Data("k".utf8) }
        session.stop()
    }

    @Test
    func channels_that_fail_at_once_end_the_pane_after_the_tries() async throws {
        // A server that drops each connection: every link is closed.
        let links = (0 ..< 20).map { _ in FakeServerLink() }
        for link in links {
            link.close()
        }
        let endpoint = FakeEndpoint(links)
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: endpoint)
        session.start()
        try await host.waitFor { $0.gone == 1 }
        // 13 failed tries, 500 ms apart: no tight loop.
        #expect(endpoint.connected.count == 13)
        session.stop()
    }

    @Test
    func a_failed_attach_on_an_endpoint_with_no_next_connection_ends_the_pane_at_once() async throws {
        let link = FakeServerLink { method, args in
            if method == MactermProtocol.SessionCreate.name { throw ServerClientError.noAnswer }
            return try FakeServerLink.standard(method, args)
        }
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: Self.launch, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        let started = Date()
        session.start()
        try await host.waitFor { $0.gone == 1 }
        #expect(Date().timeIntervalSince(started) < 0.4, "no wait before an endpoint with no next connection")
        #expect(host.snapshot().linkLost == 0)
        session.stop()
    }

    @Test
    func the_create_asks_the_server_to_replace_an_exited_session_and_ends_none_itself() async throws {
        // As the server: a session of this id whose shell exited.
        let replace = LockedBox<[Bool]>([])
        let link = FakeServerLink { method, args in
            if method == MactermProtocol.SessionCreate.name, let create = args as? MactermProtocol.SessionCreate.Args {
                replace.mutate { $0.append(create.replaceExited) }
                if !create.replaceExited {
                    throw ProtocolControlError.errorResponse(.init(code: "exited", message: "The session's shell exited."))
                }
            }
            return try FakeServerLink.standard(method, args)
        }
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: Self.launch, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        session.start()
        try await host.waitFor { _ in link.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(replace.value == [true])
        #expect(!link.calls.contains(MactermProtocol.SessionKill.name))
        session.stop()
    }

    @Test
    func an_exit_ends_the_session_with_no_new_connection() async throws {
        let first = FakeServerLink()
        let endpoint = FakeEndpoint([first, FakeServerLink()])
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: endpoint)
        session.start()
        try await host.waitFor { _ in first.sent(on: "s").contains(MactermProtocol.Attach.name) }
        first.deliver(MactermProtocol.Exit(code: 3), to: "s")
        try await host.waitFor { $0.exit != nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.snapshot().exit?.code == 3)
        #expect(endpoint.connected.count == 1)
        #expect(host.snapshot().linkLost == 0)
        session.stop()
    }

    @Test
    func input_before_the_attach_goes_on_the_channel_after_a_run_starts() async throws {
        let link = FakeServerLink()
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        session.sendInput(Data("ls\n".utf8))
        session.start()
        try await host.waitFor { _ in link.sent(on: "s").contains(MactermProtocol.Attach.name) }
        #expect(link.input(on: "s").isEmpty, "the input waits for the shell")
        link.deliver(MactermProtocol.Status(state: .running), to: "s")
        try await host.waitFor { _ in link.input(on: "s") == Data("ls\n".utf8) }
        session.stop()
    }

    @Test
    func keys_claims_and_sizes_reach_the_channel_in_the_order_of_the_calls() async throws {
        let link = FakeServerLink()
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        session.start()
        try await host.waitFor { _ in link.sent(on: "s").contains(MactermProtocol.Attach.name) }
        let grid = PaneGrid(cols: 100, rows: 30)
        for _ in 0 ..< 50 {
            session.sendInput(Data("a".utf8))
            session.claim(grid: grid)
            session.sendSize(grid)
            session.seen()
        }
        try await host.waitFor { _ in link.sent(on: "s").count(where: { $0 == MactermProtocol.Seen.name }) == 50 }
        let sent = link.sent(on: "s").drop { $0 != "bytes" }
        let round = [
            "bytes",
            MactermProtocol.Claim.name,
            MactermProtocol.Resize.name,
            MactermProtocol.Resize.name,
            MactermProtocol.Seen.name,
        ]
        #expect(Array(sent) == Array(repeating: round, count: 50).flatMap(\.self))
        session.stop()
    }

    @Test
    func finish_comes_after_the_calls_before_it_and_gives_back_their_input() async {
        let link = FakeServerLink()
        let host = RecordingPaneHost()
        let session = PaneSession(name: "s", launch: nil, wantsForeground: false, host: host, endpoint: FakeEndpoint([link]))
        // No attach yet: the input waits, and `finish` gives it back.
        session.sendInput(Data("ls\n".utf8))
        let finished = await session.finish()
        #expect(finished.pendingInput == Data("ls\n".utf8))
        #expect(link.sent(on: "s").isEmpty)
    }
}
