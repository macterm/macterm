import Darwin
import Foundation
@testable import Macterm
import Testing

/// Requests on a connection whose server never answers: the far end of a
/// socket pair that sent its `hello` and then reads nothing.
@Suite(.timeLimit(.minutes(1)))
struct ServerConnectionTests {
    @Test
    func a_request_that_times_out_leaves_no_waiting_entry() async throws {
        let (connection, peer) = try Self.silentServer()
        defer {
            connection.close()
            Darwin.close(peer)
        }
        await #expect(throws: ServerClientError.noAnswer) {
            try await connection.call(MactermProtocol.Ping.self, .init(), timeout: .milliseconds(50))
        }
        #expect(connection.pendingCount == 0)
    }

    @Test
    func a_cancelled_request_leaves_no_waiting_entry() async throws {
        let (connection, peer) = try Self.silentServer()
        defer {
            connection.close()
            Darwin.close(peer)
        }
        let request = Task { try await connection.call(MactermProtocol.Ping.self, .init()) }
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.pendingCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(connection.pendingCount == 1)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(connection.pendingCount == 0)
    }

    @Test
    func a_request_after_the_connection_ended_fails() async throws {
        let (connection, peer) = try Self.silentServer()
        Darwin.close(peer)
        defer { connection.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.isOpen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await #expect(throws: ServerClientError.disconnected) {
            try await connection.call(MactermProtocol.Ping.self, .init(), timeout: .seconds(5))
        }
        #expect(connection.pendingCount == 0)
    }

    /// A connection to a server that sent its `hello` and answers nothing.
    /// The caller closes the returned peer fd.
    private static func silentServer() throws -> (ServerConnection, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let hello = MactermProtocol.Hello(
            level: MactermProtocol.level,
            minLevel: MactermProtocol.minLevel,
            build: "test",
            role: .server,
            epoch: 1,
            caps: []
        )
        let body = try #require(ProtocolControl.hello(hello).encoded())
        let frame = try ProtocolFrame(channel: ProtocolFrame.controlChannel, kind: .msg, body: body).encoded()
        let connection = try ServerConnection.handshake(fd: fds[0], peerPID: nil, timeout: 5, buffered: frame)
        return (connection, fds[1])
    }
}
