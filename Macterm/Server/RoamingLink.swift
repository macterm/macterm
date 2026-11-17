import Darwin
import Foundation
import os
import Security

private let logger = Logger(subsystem: appBundleID, category: "RoamingLink")

/// Opens the roaming link of a host (design/009) over the host's ssh
/// connection to its server, and gives back a `RemoteServers.Link` whose
/// connection speaks UDP. Any failure gives nil and changes nothing: the
/// host keeps its ssh link (UDP blocked, the link off on the host, a jump
/// host, an older server).
///
/// A link outlives the ssh connection that opened it. After sleep or a new
/// network the host still holds the link, and the transport's next packet
/// from the new address brings it back, with no login (`LinkTransport`).
enum RoamingLink {
    /// The protocol level that has `link.open`.
    static let level: UInt32 = 3

    struct Opened {
        var link: RemoteServers.Link
        var transport: LinkTransport
    }

    /// What the transport reports, on its thread.
    struct Events {
        /// The link ended by itself (no packet for `LinkTransport.deadAfter`).
        var dead: @Sendable () -> Void
        /// The link became quiet, or hears the host again: read
        /// `LinkTransport.isQuiet`.
        var quiet: @Sendable () -> Void
    }

    static func open(
        destination: String,
        over ssh: RemoteServers.Link,
        connections: SSHConnections,
        enabled: Bool,
        events: Events
    ) async -> Opened? {
        guard enabled else { return nil }
        let hello = ssh.connection.serverHello
        guard hello.level >= level, hello.caps.contains("udp-link") else { return nil }
        guard let host = await connections.directHostname(destination) else { return nil }

        // A new key for each link: the nonce is the counter alone, so a key
        // that two links share repeats nonces. The key goes only in this
        // request, over ssh.
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { buffer in
            buffer.baseAddress.map { SecRandomCopyBytes(kSecRandomDefault, 32, $0) } ?? errSecAllocate
        }
        guard status == errSecSuccess else { return nil }
        let keyID = UInt32.random(in: 1 ... UInt32.max)

        let port: UInt16
        do {
            port = try await ssh.connection.call(MactermProtocol.LinkOpen.self, .init(secret: ProtocolSecret(key), keyId: keyID)).port
        } catch {
            logger.info("link.open on \(destination, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        var transport: LinkTransport?
        var handedOff = false
        do {
            let made = try LinkTransport(host: host, port: port, key: key, keyID: keyID)
            transport = made
            try made.start(onDead: events.dead, onQuiet: events.quiet)
            handedOff = true
            let connection = try await Task.detached {
                try ServerConnection.handshake(fd: made.connectionFD, peerPID: nil, timeout: 3)
            }.value
            logger.info("link: host=\(destination, privacy: .public) port=\(port, privacy: .public)")
            return Opened(
                link: RemoteServers.Link(connection: connection, process: nil, installed: false, commands: 0, isRoaming: true),
                transport: made
            )
        } catch {
            // UDP does not get through, or the host did not answer: ssh only.
            // The handshake closes the descriptor when it fails.
            if let transport {
                if !handedOff { Darwin.close(transport.connectionFD) }
                transport.stop()
            }
            logger.info("link on \(destination, privacy: .public) unused: \(String(describing: error), privacy: .public)")
            _ = try? await ssh.connection.call(MactermProtocol.LinkClose.self, .init(keyId: keyID))
            return nil
        }
    }
}
