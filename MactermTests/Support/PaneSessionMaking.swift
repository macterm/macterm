import Foundation
@testable import Macterm

extension RemotePaneDriver {
    /// Starts the driver with one ready view for each host, as the surfaces
    /// of the windows that show the pane. The routes are in the same order.
    @discardableResult
    func start(showing hosts: [any PaneSessionHost]) -> [View] {
        let views = hosts.map { addView($0) }
        start()
        views.forEach { $0.start() }
        return views
    }
}

/// A remote pane's driver with one view, as one window shows it: the tests
/// of one surface start, type and stop through it.
@MainActor
final class OneViewDriver {
    let driver: RemotePaneDriver
    private let host: any PaneSessionHost
    private var view: RemotePaneDriver.View?

    init(name: String, surface: any PaneSessionHost, hosts: RemoteHosts, slowConnectAfter: Duration = RemotePaneDriver.slowConnectAfter) {
        driver = RemotePaneDriver(name: name, hosts: hosts, slowConnectAfter: slowConnectAfter)
        host = surface
    }

    func start() {
        view = driver.start(showing: [host])[0]
    }

    func stop() {
        driver.stop()
    }

    func sendInput(_ data: Data) {
        view?.sendInput(data)
    }
}
