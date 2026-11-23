import Foundation
@testable import Macterm

@MainActor
private let testHosts = RemoteHosts(connections: .shared, servers: .shared, configuration: .init(key: "k", declines: .memory()))

extension Pane {
    /// Sets the link state that the pane reads from its host
    /// (`isRemoteLinkLost`, `isRemoteReconnecting`), as its driver does.
    @MainActor
    func setRemoteLink(lost: Bool? = nil, reconnecting: Bool? = nil) {
        let host = linkHost ?? testHosts.host(remoteDestination ?? "local")
        linkHost = host
        host.setLinkState(
            of: sessionName,
            lost: lost ?? host.isLost(sessionName),
            reconnecting: reconnecting ?? host.isReconnecting(sessionName)
        )
    }
}
