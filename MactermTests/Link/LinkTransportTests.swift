import Darwin
import Foundation
@testable import Macterm
import Testing

/// The roaming link against the bundled server: the app's transport over UDP
/// to a real `macterm server`, as a link that `RoamingLink` opens.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LinkTransportTests {
    @Test
    func a_connection_over_the_link_works_and_survives_a_new_socket() async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)

        let control = try await server.connect()
        defer { control.close() }
        // The ssh connection of a real host opens the link in the same way.
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let keyID = UInt32.random(in: 1 ... .max)
        let port = try await control.call(
            MactermProtocol.LinkOpen.self,
            .init(secret: ProtocolSecret(key), keyId: keyID)
        ).port

        let transport = try LinkTransport(host: "127.0.0.1", port: port, key: key, keyID: keyID)
        try transport.start(onDead: {})
        let link = try await Task.detached {
            try ServerConnection.handshake(fd: transport.connectionFD, peerPID: nil, timeout: 5)
        }.value
        defer { link.close() }
        #expect(link.serverHello.role == .server)
        _ = try await link.call(MactermProtocol.Ping.self, .init())

        // A new network: the transport opens a new socket, and the same
        // connection goes on.
        transport.pathChanged()
        _ = try await link.call(MactermProtocol.Ping.self, .init())

        // A close from another connection ends the link.
        _ = try await control.call(MactermProtocol.LinkClose.self, .init(keyId: keyID))
        _ = try await control.call(MactermProtocol.ServerExit.self, .init())
        link.close()
    }

    @Test
    func a_link_that_hears_nothing_from_the_host_becomes_quiet() async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)

        let control = try await server.connect()
        defer { control.close() }
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let keyID = UInt32.random(in: 1 ... .max)
        let port = try await control.call(
            MactermProtocol.LinkOpen.self,
            .init(secret: ProtocolSecret(key), keyId: keyID)
        ).port

        let changes = LockedBox<[Bool]>([])
        let transport = try LinkTransport(host: "127.0.0.1", port: port, key: key, keyID: keyID)
        try transport.start(onDead: {}, onQuiet: { quiet in changes.mutate { $0.append(quiet) } })
        defer { transport.stop() }
        let link = try await Task.detached {
            try ServerConnection.handshake(fd: transport.connectionFD, peerPID: nil, timeout: 5)
        }.value
        defer { link.close() }
        _ = try await link.call(MactermProtocol.Ping.self, .init())
        #expect(changes.value.isEmpty)

        // The host stops: no packet comes back, as when the network drops.
        _ = try await control.call(MactermProtocol.ServerExit.self, .init())
        let deadline = Date().addingTimeInterval(Double(LinkTransport.quietAfter) / 1000 + 10)
        while changes.value.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(changes.value == [true])
    }

    @Test
    func a_link_is_quiet_after_three_missed_keepalives() {
        #expect(LinkTransport.quietAfter >= 3 * LinkStream.keepalive)
        #expect(!LinkTransport.isQuiet(now: 10000, lastRx: 10000 - LinkTransport.quietAfter + 1))
        #expect(LinkTransport.isQuiet(now: 10000, lastRx: 10000 - LinkTransport.quietAfter))
    }
}
