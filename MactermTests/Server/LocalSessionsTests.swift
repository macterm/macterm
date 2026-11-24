import Foundation
@testable import Macterm
import Testing

/// `LocalSessions` against the bundled server, in a runtime directory of its
/// own, so that no test meets the server or the sessions of the Macterm that
/// runs on this Mac.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalSessionsTests {
    @Test
    func a_running_session_is_listed_with_its_shell_and_is_killed() async throws {
        try await withServer { server in
            let sessions = LocalSessions(server: server)
            let id = "list-\(UInt32.random(in: 0 ... .max))"
            let other = try await server.connect()
            defer { other.close() }
            _ = try await other.call(MactermProtocol.SessionCreate.self, Self.args(id: id, command: ["/bin/sleep", "60"]))

            let listed = try #require(await sessions.list()?.first { $0.name == id })
            #expect(listed.isRunning)
            #expect(listed.shellPID != nil)

            await sessions.kill(id)
            #expect(await sessions.list()?.contains { $0.name == id } == false)
            // A session that is not there is no error.
            await sessions.kill(id)
        }
    }

    /// The server ends it when a list reads the status. `LocalSessions`
    /// ends no session itself.
    @Test
    func a_session_whose_shell_exits_is_ended_after_a_list_reads_it() async throws {
        try await withServer { server in
            let sessions = LocalSessions(server: server)
            await sessions.prepare()
            let id = "exit-\(UInt32.random(in: 0 ... .max))"
            let other = try await server.connect()
            defer { other.close() }
            _ = try await other.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sh", "-c", "sleep 0.2; exit 3"])
            )
            let deadline = Date().addingTimeInterval(10)
            while await sessions.list()?.contains(where: { $0.name == id }) != false, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await sessions.list()?.contains { $0.name == id } == false)
        }
    }

    @Test
    func a_session_that_exited_while_no_app_was_connected_is_ended_after_a_list_reads_it() async throws {
        try await withServer { server in
            let id = "gone-\(UInt32.random(in: 0 ... .max))"
            let other = try await server.connect()
            defer { other.close() }
            var events = other.events.makeAsyncIterator()
            _ = try await other.call(MactermProtocol.SessionCreate.self, Self.args(id: id, command: ["/bin/sh", "-c", "exit 0"]))
            while let batch = await events.next(), !batch.events.contains(where: {
                if case let .sessionExit(exit) = $0 { exit.id == id } else { false }
            }) {}

            let sessions = LocalSessions(server: server)
            await sessions.prepare()
            let deadline = Date().addingTimeInterval(10)
            while await sessions.list()?.contains(where: { $0.name == id }) != false, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await sessions.list()?.contains { $0.name == id } == false)
        }
    }

    @Test
    func no_server_lists_nothing() async {
        #expect(await LocalSessions(server: nil).list() == nil)
    }

    // MARK: - Helpers

    /// As in `LocalServerTests`: a server of the bundled build in a new
    /// runtime directory under `/tmp`, removed with its sessions after.
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

    private static func args(id: String, command: [String]) -> MactermProtocol.SessionCreate.Args {
        .init(
            id: id,
            cwd: ProtocolBin(Data(NSTemporaryDirectory().utf8)),
            command: command.map { ProtocolBin(Data($0.utf8)) },
            cols: 80,
            rows: 24
        )
    }
}

struct LocalSessionConversionTests {
    @Test
    func a_server_session_becomes_a_local_session() {
        let session = MactermProtocol.Session(
            id: "macterm-x", state: .running, build: "b", level: 1, buildKey: "k",
            pid: 10, shellPid: 11, pty: ProtocolBin(Data("/dev/ttys004".utf8)), cols: 80, rows: 24, clients: 2
        )
        #expect(SessionInfo(session) == SessionInfo(name: "macterm-x", pid: 10, shellPID: 11, clients: 2, buildKey: "k"))
        var exited = session
        exited.state = .exited
        #expect(!SessionInfo(exited).isRunning)
    }
}
