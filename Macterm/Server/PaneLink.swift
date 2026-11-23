import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaneLink")

/// What a pane's session says about the pane, once for the pane however many
/// surfaces show it (`PaneLink.onEvent`).
enum PaneLinkEvent {
    case state(MactermProtocol.State)
    case foreground(SessionForeground)
    case title(String)
    case ttyMode(TerminalLineMode)
    case mark(MactermProtocol.Mark)
    case status(MactermProtocol.Status)
    case attention(MactermProtocol.Attention)
    /// The session ended: its shell exited, it is gone, or the host has none.
    case ended
}

/// One pane's link to its session (F2 of the 2026-11-15 architecture review,
/// option A). The pane owns it; it does what is the session's, once for the
/// pane: it makes or finds the session, runs the remote driver, takes the
/// exit, and gives the pane the session's own messages. Each surface of the
/// pane has only a view channel through it (`attach`): bytes in, and input,
/// size and claims out, with its own lead.
///
/// The transport is the seam where a pane reaches its session: `local` (the
/// local server, through `connect`) or `remote` (the host's server or a plain
/// ssh shell, through `RemotePaneDriver`).
@MainActor
final class PaneLink {
    enum Transport {
        /// The local server. `connect` gives a connection that is up.
        case local(connect: PaneSession.Connect)
        /// A host. The driver asks `hosts` what to do.
        case remote(RemoteHosts)
    }

    /// One surface's view of the session.
    private final class View {
        let host: SurfaceChannelHost
        /// The surface's route: a local channel, or the driver's view.
        let route: any PaneInputRoute
        var ready = false
        /// The local channel, started when the view is ready and the
        /// session is made.
        let session: PaneSession?
        let remote: RemotePaneDriver.View?

        init(host: SurfaceChannelHost, session: PaneSession) {
            self.host = host
            route = session
            self.session = session
            remote = nil
        }

        init(host: SurfaceChannelHost, remote: RemotePaneDriver.View) {
            self.host = host
            route = remote
            session = nil
            self.remote = remote
        }
    }

    private enum Creation {
        case none
        case running(Task<Void, Never>)
        case made
    }

    let name: String
    private let transport: Transport
    /// The pane's handler of the session's messages and its end.
    var onEvent: ((PaneLinkEvent) -> Void)?
    private var views: [View] = []
    private var creation = Creation.none
    /// The launch of the first surface: what a new session runs.
    private var launch: PaneSession.Launch?
    private var driver: RemotePaneDriver?
    /// The session ended. Each view knows; the pane heard it once.
    private(set) var hasEnded = false

    init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    /// The link of a pane: local, or remote for a remote pane.
    static func make(for pane: Pane) -> PaneLink {
        let transport: Transport = pane.isRemote
            ? .remote(.shared)
            : .local(connect: { try await LocalSessions.shared.channelConnection() })
        return PaneLink(name: pane.sessionName, transport: transport)
    }

    // MARK: - Views

    /// A surface's view channel. `launch` is what the surface resolved for a
    /// local pane; the first one makes the session. Input before the view is
    /// ready waits for the first attach.
    func attach(_ host: SurfaceChannelHost, launch: PaneSession.Launch?) -> any PaneInputRoute {
        host.link = self
        if self.launch == nil { self.launch = launch }
        let view: View
        switch transport {
        case let .local(connect):
            let session = PaneSession(
                name: name, wantsForeground: true, wantsTty: true, host: host, connect: connect
            )
            view = View(host: host, session: session)
        case let .remote(hosts):
            let driver = driver ?? RemotePaneDriver(name: name, hosts: hosts)
            self.driver = driver
            view = View(host: host, remote: driver.addView(host))
        }
        views.append(view)
        return view.route
    }

    /// The surface of `host` exists: its view can show the session.
    func viewReady(_ host: SurfaceChannelHost) {
        guard let view = view(of: host), !view.ready, !hasEnded else { return }
        view.ready = true
        switch transport {
        case .local:
            switch creation {
            case .made: view.session?.start()
            case .running: break
            case .none: create()
            }
        case .remote:
            driver?.start()
            view.remote?.start()
        }
    }

    /// The surface of `host` goes. The session keeps running.
    func detach(_ host: SurfaceChannelHost) {
        guard let index = views.firstIndex(where: { $0.host === host }) else { return }
        let view = views.remove(at: index)
        view.session?.stop()
        view.remote?.stop()
        if views.isEmpty {
            // No surface shows the pane: the next one starts again.
            driver?.stop()
            driver = nil
            if case let .running(task) = creation {
                task.cancel()
                creation = .none
            }
        }
    }

    /// Whether the plain shell of a remote pane shows in `host`. nil when
    /// the pane runs no plain shell.
    func showsPlainShell(in host: SurfaceChannelHost) -> Bool? {
        driver?.showsPlainShell(in: host)
    }

    private func view(of host: SurfaceChannelHost) -> View? {
        views.first { $0.host === host }
    }

    // MARK: - The local session

    /// Makes the session or finds it, once for the pane, then starts the
    /// channel of each ready view. A server that does not come back ends
    /// the pane, as a channel that cannot reconnect does.
    private func create() {
        guard case let .local(connect) = transport, let launch else { return }
        let name = name
        let grid = views.first(where: \.ready)?.host.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
        creation = .running(Task { [weak self] in
            var tries = 0
            while !Task.isCancelled {
                do {
                    let connection = try await connect()
                    try await PaneSession.create(on: connection, name: name, launch: launch, grid: grid)
                    self?.made()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    logger.info("pane \(name, privacy: .public): create failed: \(String(describing: error), privacy: .public)")
                }
                tries += 1
                if tries > PaneSession.reconnectTries {
                    self?.sessionEnded()
                    return
                }
                try? await Task.sleep(for: PaneSession.reconnectWait)
            }
        })
    }

    private func made() {
        guard !hasEnded else { return }
        creation = .made
        NotificationCenter.default.post(name: .zmxSessionsChanged, object: nil)
        for view in views where view.ready {
            view.session?.start()
        }
    }

    // MARK: - The session's messages

    /// A message of the session, from the channel of `host`. Every channel
    /// gets the same messages, so only the first view's count: the pane
    /// hears each one once.
    func receive(_ event: PaneLinkEvent, from host: SurfaceChannelHost) {
        if case .ended = event {
            sessionEnded()
            return
        }
        guard !hasEnded, isFirstView(host) else { return }
        onEvent?(event)
    }

    /// Whether `host` is the first view: its channel's messages count.
    func isFirstView(_ host: SurfaceChannelHost) -> Bool {
        views.first?.host === host
    }

    /// The shell's folder goes to every surface: each keeps it for itself.
    func receiveCwd(_ path: String) {
        for view in views {
            view.host.setCwd(path)
        }
    }

    /// The session ended. Every view stops, and the pane hears it once.
    private func sessionEnded() {
        guard !hasEnded else { return }
        hasEnded = true
        logger.info("pane \(self.name, privacy: .public): session ended")
        for view in views {
            view.host.markEnded()
            view.session?.stop()
        }
        driver?.stop()
        driver = nil
        onEvent?(.ended)
    }
}
