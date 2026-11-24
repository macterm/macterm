import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: appBundleID, category: "SurfaceChannel")

/// A surface that runs from a channel (`PaneSession`) and not from a client
/// on a pty: libghostty's manual surface (fork patch 0022). The session
/// makes the pane's shell from the launch that libghostty resolved
/// (`ghostty_launch_resolve`, fork patch 0023); its bytes are fed to the
/// surface, and the surface's input, size and claims go back on the channel.
extension GhosttyTerminalNSView {
    /// The pane's route and its host, for the callbacks that libghostty
    /// makes on its io thread.
    final class ChannelRuntime: @unchecked Sendable {
        let route: PaneRoute
        let host: SurfaceChannelHost

        init(route: PaneRoute, host: SurfaceChannelHost) {
            self.route = route
            self.host = host
        }
    }

    /// The launch that libghostty resolves for `config` (the options of a
    /// normal surface), as strings. nil when it cannot.
    static func resolveLaunch(app: ghostty_app_t, config: inout ghostty_surface_config_s) -> PaneSession.Launch? {
        // The header marks the pointers non-null, so the struct has no zero
        // initializer: libghostty fills zeroed memory.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<ghostty_launch_s>.size,
            alignment: MemoryLayout<ghostty_launch_s>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<ghostty_launch_s>.size)
        let launchPointer = raw.bindMemory(to: ghostty_launch_s.self, capacity: 1)
        defer { raw.deallocate() }
        guard ghostty_launch_resolve(app, &config, launchPointer) else {
            logger.error("ghostty_launch_resolve failed")
            return nil
        }
        defer { ghostty_launch_free(launchPointer) }
        let launch = launchPointer.pointee
        var argv: [String] = []
        for index in 0 ..< launch.argv_count {
            if let arg = launch.argv[index] { argv.append(String(cString: arg)) }
        }
        var env: [String] = []
        for index in 0 ..< launch.env_count {
            env.append("\(String(cString: launch.env[index].key))=\(String(cString: launch.env[index].value))")
        }
        let cwd = launch.cwd.map { String(cString: $0) }
        return PaneSession.Launch(cwd: cwd, argv: argv, env: env)
    }

    /// Sets the manual surface fields. Both callbacks run on libghostty's io
    /// thread, possibly with the renderer lock held: they copy and return.
    static func enableManualIO(_ config: inout ghostty_surface_config_s) {
        config.manual_io = true
        config.manual_write = { userdata, bytes, count in
            guard let userdata else { return }
            let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            view.channelRuntime?.route.input.sendInput(Data(bytes: bytes, count: count))
        }
        config.manual_resize = { userdata, columns, rows, widthPx, heightPx in
            guard let userdata else { return }
            let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let runtime = view.channelRuntime else { return }
            let grid = PaneGrid(cols: columns, rows: rows, widthPx: widthPx, heightPx: heightPx)
            runtime.host.setGrid(grid)
            runtime.route.input.sendSize(grid)
        }
    }

    /// Gives the surface its view channel on the pane's link, before the
    /// surface: a key or the `initial_input` that the surface writes while it
    /// starts is held until the first attach. `launch` is nil for a remote
    /// pane. The link makes the session, once for the pane.
    func prepareChannel(launch: PaneSession.Launch?) {
        guard let pane = owningPane else {
            logger.error("surface channel: the view has no pane")
            return
        }
        let host = SurfaceChannelHost(view: self)
        let link = pane.sessionLink
        let input = link.attach(host, launch: launch)
        let route = PaneRoute(
            input: input,
            start: { [weak link] in Self.onMain { link?.viewReady(host) } },
            stop: { [weak link] in Self.onMain { link?.detach(host) } }
        )
        channelRuntime = ChannelRuntime(route: route, host: host)
    }

    /// Runs `body` on the main actor: at once from the main thread, so a view
    /// that goes stops counting before anything else runs.
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    /// Gives the host its surface and starts the reading. The surface exists.
    func startChannel(surface: ghostty_surface_t) {
        guard let runtime = channelRuntime else { return }
        let size = ghostty_surface_size(surface)
        runtime.host.setSurface(surface)
        runtime.host.setGrid(PaneGrid(cols: size.columns, rows: size.rows, widthPx: size.width_px, heightPx: size.height_px))
        runtime.route.start()
    }

    /// Ends the reading and cuts the host from the surface, before the
    /// surface is freed. The session keeps running.
    func stopChannel() {
        guard let runtime = channelRuntime else { return }
        channelRuntime = nil
        runtime.host.invalidate()
        runtime.route.stop()
    }
}

/// One surface's view of the pane's session. Its bytes, size and lead are the
/// surface's own; the session's messages go to the pane's `PaneLink`, which
/// gives the pane each one once. Its callbacks come from the session's
/// tasks, so each one hops to the main actor. `invalidate` runs before the
/// surface is freed: it waits for a feed in flight, and no later one reaches
/// the surface.
final class SurfaceChannelHost: PaneSessionHost, @unchecked Sendable {
    /// Guards `surface`. Held across a feed, so nothing that libghostty's
    /// callbacks call may take it (`manual_resize` takes `gridLock`).
    private let lock = NSLock()
    private var surface: ghostty_surface_t?
    private weak var view: GhosttyTerminalNSView?
    private let gridLock = NSLock()
    private var grid = PaneGrid(cols: 80, rows: 24)
    /// The pane's link. Set on the main actor before the first message.
    @MainActor weak var link: PaneLink?

    /// `view` is nil only in a test, which reads the link's events.
    init(view: GhosttyTerminalNSView?) {
        self.view = view
    }

    /// The id of the surface that owns this channel, nil in a test.
    @MainActor var surfaceID: UUID? {
        view?.owningSurface?.id
    }

    /// The terminal view of this channel, nil in a test.
    @MainActor var terminalView: GhosttyTerminalNSView? {
        view
    }

    func setSurface(_ new: ghostty_surface_t) {
        lock.lock()
        surface = new
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        surface = nil
        lock.unlock()
    }

    func setGrid(_ new: PaneGrid) {
        gridLock.lock()
        grid = new
        gridLock.unlock()
    }

    func paneGrid() -> PaneGrid {
        gridLock.lock()
        defer { gridLock.unlock() }
        return grid
    }

    func paneFeed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed(surface, base, UInt(buffer.count))
        }
    }

    /// Sends a message of the session to the link, on the main actor.
    private func toLink(_ event: PaneLinkEvent) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { link?.receive(event, from: self) }
        }
    }

    func paneState(_ state: MactermProtocol.State) {
        toLink(.state(state))
    }

    func paneForeground(_ foreground: MactermProtocol.Foreground) {
        guard let report = SessionForeground(foreground) else { return }
        toLink(.foreground(report))
    }

    func paneTitle(_ title: Data) {
        toLink(.title(String(decoding: title, as: UTF8.self)))
    }

    /// Each surface keeps the folder for itself (`currentPwd`), as
    /// libghostty's own `pwd` action does for a surface with no session.
    func paneCwd(_ url: Data) {
        guard let path = Self.path(ofCwdURL: url) else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard let link, link.counts(self) else { return }
                link.receiveCwd(path)
            }
        }
    }

    @MainActor
    func setCwd(_ path: String) {
        view?.currentPwd = path
    }

    /// The session ended: the surface runs nothing now.
    @MainActor
    func markEnded() {
        view?.sessionEnded = true
    }

    func paneMark(_ mark: MactermProtocol.Mark) {
        toLink(.mark(mark, self))
    }

    func paneStatus(_ status: MactermProtocol.Status) {
        toLink(.status(status))
    }

    /// The path of an OSC 7 URL: what follows the host. A `file://` URL has
    /// percent escapes, which are decoded. A `kitty-shell-cwd://` URL (the
    /// shell integration of Ghostty) has the raw path, which can hold `#`,
    /// `?` and `%`, so it is not parsed as a URL. nil for anything else.
    static func path(ofCwdURL data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let scheme = text.range(of: "://") else { return nil }
        let rest = text[scheme.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = String(rest[slash...])
        guard text.hasPrefix("file://") else { return path }
        return path.removingPercentEncoding ?? path
    }

    func paneTtyMode(_ mode: MactermProtocol.TtyMode) {
        toLink(.ttyMode(TerminalLineMode(canonical: mode.canonical, echo: mode.echo)))
    }

    func paneAttention(_ flags: MactermProtocol.Attention) {
        toLink(.attention(flags))
    }

    /// The lead is this surface's own: the session says it for each client.
    func paneLead(_ leader: Bool?) {
        DispatchQueue.main.async { [weak view] in view?.onLead?(leader) }
    }

    /// The session's exit, or a session that is gone after the create: a
    /// fact of the session, so any view's channel tells it.
    func paneExited(code _: UInt8?, signal _: UInt8?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { link?.receiveExit() }
        }
    }

    /// The channel could not come back. It counts only from the counting
    /// view: another window's channel that fails alone is a detach.
    func paneGone() {
        toLink(.ended)
    }
}
