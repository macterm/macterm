import Foundation
@testable import Macterm
import Testing

/// A pane channel against the bundled server, in a runtime directory of its
/// own (see `LocalServerTests`).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneChannelTests {
    /// With a read-ahead limit, the reader waits while that many events wait
    /// for the consumer, and a close wakes it.
    @Test
    func a_reader_waits_at_the_read_ahead_limit_and_a_close_wakes_it() async throws {
        let link = FakeServerLink()
        let channel = PaneChannel(transport: link, number: 1, buffering: .readAhead(2))
        let delivered = LockedBox(0)
        let done = LockedBox(false)
        let reader = Thread {
            for index in 0 ..< 5 {
                channel.sink.deliver(ProtocolFrame(channel: 1, kind: .bytes, body: Data([UInt8(index)])))
                delivered.mutate { $0 += 1 }
            }
            done.mutate { $0 = true }
        }
        reader.start()
        try await Self.waitFor { delivered.value == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(delivered.value == 2, "the reader waits for room")

        var events = channel.events.makeAsyncIterator()
        #expect(await events.next() == .output(Data([0])))
        try await Self.waitFor { delivered.value == 3 }

        channel.sink.finish()
        try await Self.waitFor { done.value }
    }

    /// A relayed channel never waits. Over its limit it drops the output up
    /// to the next snapshot, says so once, and asks the session for a
    /// snapshot. The snapshot's own bytes always pass.
    @Test
    func a_relayed_channel_over_its_limit_skips_to_the_next_snapshot() async throws {
        let link = FakeServerLink(buffering: .skipAhead(bytes: 4))
        let channel = try await link.openChannel(session: "s")
        link.deliver(output: "ab", to: "s")
        link.deliver(output: "cd", to: "s")
        link.deliver(output: "e", to: "s")
        link.deliver(output: "f", to: "s")
        try await Self.waitFor { link.sent(on: "s").contains(MactermProtocol.Refresh.name) }
        link.deliver(MactermProtocol.SnapshotStart(scrollback: false, offset: 10), to: "s")
        link.deliver(output: "screen", to: "s")
        link.deliver(MactermProtocol.SnapshotEnd(), to: "s")

        var events = channel.events.makeAsyncIterator()
        var seen: [PaneChannelEvent] = []
        for _ in 0 ..< 6 {
            if let event = await events.next() { seen.append(event) }
        }
        #expect(seen == [
            .output(Data("ab".utf8)),
            .output(Data("cd".utf8)),
            .skipped,
            .snapshotStart(.init(scrollback: false, offset: 10)),
            .output(Data("screen".utf8)),
            .snapshotEnd,
        ])

        // Output after the snapshot passes, now that the pane took the rest.
        link.deliver(output: "g", to: "s")
        #expect(await events.next() == .output(Data("g".utf8)))
        #expect(link.sent(on: "s") == [MactermProtocol.Refresh.name], "one request while the snapshot came in time")
        channel.sink.finish()
    }

    /// A session that is behind ignores a request for a snapshot: the
    /// channel asks again while the skip waits.
    @Test
    func a_skipped_channel_asks_again_until_the_snapshot_comes() async throws {
        let link = FakeServerLink(buffering: .skipAhead(bytes: 1, askAgain: .milliseconds(20)))
        let channel = try await link.openChannel(session: "s")
        link.deliver(output: "ab", to: "s")
        try await Self.waitFor { link.sent(on: "s").count >= 2 }
        #expect(Set(link.sent(on: "s")) == [MactermProtocol.Refresh.name])

        link.deliver(MactermProtocol.SnapshotStart(scrollback: false), to: "s")
        try await Task.sleep(for: .milliseconds(50))
        let asked = link.sent(on: "s").count
        try await Task.sleep(for: .milliseconds(150))
        #expect(link.sent(on: "s").count == asked, "no request after the snapshot started")
        channel.sink.finish()
    }

    @Test
    func a_skipped_channel_stops_asking_when_it_ends() async throws {
        let link = FakeServerLink(buffering: .skipAhead(bytes: 1, askAgain: .milliseconds(20)))
        let channel = try await link.openChannel(session: "s")
        link.deliver(output: "ab", to: "s")
        try await Self.waitFor { !link.sent(on: "s").isEmpty }
        channel.sink.finish()
        try await Task.sleep(for: .milliseconds(50))
        let asked = link.sent(on: "s").count
        try await Task.sleep(for: .milliseconds(150))
        #expect(link.sent(on: "s").count == asked)
    }

    /// Output over the limit inside a snapshot passes: the pane never draws
    /// half a snapshot.
    @Test
    func a_snapshot_is_never_cut() async throws {
        let link = FakeServerLink(buffering: .skipAhead(bytes: 2))
        let channel = try await link.openChannel(session: "s")
        link.deliver(MactermProtocol.SnapshotStart(scrollback: false), to: "s")
        link.deliver(output: "abc", to: "s")
        link.deliver(output: "def", to: "s")
        link.deliver(MactermProtocol.SnapshotEnd(), to: "s")
        var events = channel.events.makeAsyncIterator()
        var seen: [PaneChannelEvent] = []
        for _ in 0 ..< 4 {
            if let event = await events.next() { seen.append(event) }
        }
        #expect(seen == [
            .snapshotStart(.init(scrollback: false)),
            .output(Data("abc".utf8)),
            .output(Data("def".utf8)),
            .snapshotEnd,
        ])
        #expect(link.sent(on: "s").isEmpty)
        channel.sink.finish()
    }

    /// A paused channel gets no output, and the resume brings a snapshot
    /// with the screen as it is now.
    @Test
    func a_paused_channel_gets_no_output_and_the_resume_brings_a_snapshot() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "chan-pause-\(UInt32.random(in: 0 ... .max))"
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(
                    id: id,
                    command: ["/bin/sh", "-c", "stty -echo; printf ready-%s ok; read line; printf hidden-%s \"$line\"; read line"]
                )
            )
            let channel = try await connection.openChannel(session: id)
            try channel.send(MactermProtocol.Attach(cols: 80, rows: 24))
            var iterator = channel.events.makeAsyncIterator()
            var screen = Data()
            while !String(decoding: screen, as: UTF8.self).contains("ready-ok") {
                guard let event = await iterator.next() else { Issue.record("no output")
                    return
                }
                if case let .output(data) = event { screen.append(data) }
            }

            try await channel.setPaused(true)
            try channel.sendInput(Data("one\n".utf8))
            try await Task.sleep(for: .milliseconds(300))
            try await channel.setPaused(false)

            var output = Data()
            var snapshot = Data()
            var inSnapshot = false
            // The attach's own snapshot can still be in progress: read up to
            // the snapshot that has the screen.
            reading: while let event = await iterator.next() {
                switch event {
                case .snapshotStart:
                    inSnapshot = true
                    snapshot = Data()
                case .snapshotEnd:
                    inSnapshot = false
                    if String(decoding: snapshot, as: UTF8.self).contains("hidden-one") { break reading }
                case let .output(data):
                    if inSnapshot { snapshot.append(data) } else { output.append(data) }
                default: break
                }
            }
            #expect(!String(decoding: output, as: UTF8.self).contains("hidden-one"), "no output while paused")
            #expect(String(decoding: snapshot, as: UTF8.self).contains("hidden-one"), "the snapshot has the screen")
            await channel.close()
        }
    }

    @Test
    func a_channel_attaches_gets_output_sends_input_and_sees_the_exit() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "chan-\(UInt32.random(in: 0 ... .max))"
            // The first output is the marker that shows the channel reads the
            // pane. The program echoes one line of input, then exits.
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sh", "-c", "printf ready-%s ok; read line; printf got-%s \"$line\"; exit 4"])
            )
            let channel = try await connection.openChannel(session: id)
            try channel.send(MactermProtocol.Attach(cols: 80, rows: 24))
            var iterator = channel.events.makeAsyncIterator()
            var screen = Data()
            while !String(decoding: screen, as: UTF8.self).contains("ready-ok") {
                guard let event = await iterator.next() else { Issue.record("no output")
                    return
                }
                if case let .output(data) = event { screen.append(data) }
            }
            try channel.sendInput(Data("hello\n".utf8))
            var exit: MactermProtocol.Exit?
            while exit == nil {
                guard let event = await iterator.next() else { break }
                switch event {
                case let .output(data): screen.append(data)
                case let .exit(value): exit = value
                default: break
                }
            }
            #expect(String(decoding: screen, as: UTF8.self).contains("got-hello"))
            #expect(exit?.code == 4)
            await channel.close()
        }
    }

    @Test
    func a_burst_of_output_right_after_the_open_arrives_whole_and_in_order() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "chan-burst-\(UInt32.random(in: 0 ... .max))"
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sh", "-c", "i=1; while [ $i -le 3000 ]; do echo n$i; i=$((i+1)); done; sleep 30"])
            )
            let channel = try await connection.openChannel(session: id)
            try channel.send(MactermProtocol.Attach(cols: 200, rows: 24))
            var iterator = channel.events.makeAsyncIterator()
            var screen = Data()
            while !String(decoding: screen, as: UTF8.self).contains("n3000") {
                guard let event = await iterator.next() else { Issue.record("ended early")
                    return
                }
                if case let .output(data) = event { screen.append(data) }
            }
            let numbers = String(decoding: screen, as: UTF8.self)
                .split(whereSeparator: \.isNewline).compactMap { $0.hasPrefix("n") ? Int($0.dropFirst()) : nil }
            // A snapshot may repeat lines that output carries too, but a line never
            // comes before an earlier one.
            #expect(numbers == numbers.sorted())
            #expect(numbers.last == 3000)
            await channel.close()
        }
    }

    @Test
    func a_closed_connection_ends_the_events_of_its_channels() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            let id = "chan-end-\(UInt32.random(in: 0 ... .max))"
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sleep", "60"])
            )
            let channel = try await connection.openChannel(session: id)
            connection.close()
            var iterator = channel.events.makeAsyncIterator()
            while await iterator.next() != nil {}
            #expect(throws: ServerClientError.self) { try channel.sendInput(Data("x".utf8)) }
        }
    }

    @Test
    func events_decode_output_and_the_sessions_messages() {
        let output = ProtocolFrame(channel: 3, kind: .bytes, body: Data("abc".utf8))
        #expect(PaneChannelEvent(output) == .output(Data("abc".utf8)))

        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(MactermProtocol.Lead(leader: true)).encode(to: &writer)
        let lead = ProtocolFrame(channel: 3, kind: .msg, body: writer.data)
        #expect(PaneChannelEvent(lead) == .lead(true))

        var flags = MessagePackWriter()
        let attention = MactermProtocol.Attention(unseen: true, failed: true, bell: false)
        MactermProtocol.PaneMessage(attention).encode(to: &flags)
        #expect(PaneChannelEvent(ProtocolFrame(channel: 3, kind: .msg, body: flags.data)) == .attention(attention))

        var unknown = MessagePackWriter()
        MactermProtocol.PaneMessage(t: "from.a.later.build", a: nil).encode(to: &unknown)
        #expect(PaneChannelEvent(ProtocolFrame(channel: 3, kind: .msg, body: unknown.data)) == .other("from.a.later.build"))
    }

    private static func args(id: String, command: [String]) -> MactermProtocol.SessionCreate.Args {
        .init(
            id: id,
            cwd: ProtocolBin(Data(NSTemporaryDirectory().utf8)),
            command: command.map { ProtocolBin(Data($0.utf8)) },
            cols: 80,
            rows: 24
        )
    }

    private static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out")
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
