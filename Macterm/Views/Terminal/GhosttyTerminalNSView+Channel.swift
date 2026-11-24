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

    /// Makes the pane's route (`PaneRoute`), before the surface: a key or
    /// the `initial_input` that the surface writes while it starts is held
    /// until the first attach. `launch` is nil for a remote pane.
    func prepareChannel(launch: PaneSession.Launch?) {
        let host = SurfaceChannelHost(view: self)
        let route = PaneRoute.make(session: sessionName, remote: remoteSpec != nil, launch: launch, surface: host)
        channelRuntime = ChannelRuntime(route: route, host: host)
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

/// What a pane's session drives: the surface. Its callbacks come in order on
/// the session's queue (or a plain shell's read queue), so each one hops to
/// the main actor where it touches the pane. A feed waits for the terminal,
/// which slows the reader of a fast program. `invalidate` runs before the
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

    init(view: GhosttyTerminalNSView) {
        self.view = view
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

    func paneState(_ state: MactermProtocol.State) {
        DispatchQueue.main.async { [weak view] in view?.onSessionState?(state) }
    }

    func paneForeground(_ foreground: MactermProtocol.Foreground) {
        guard let report = SessionForeground(foreground) else { return }
        DispatchQueue.main.async { [weak view] in view?.onSessionForeground?(report) }
    }

    func paneTitle(_ title: Data) {
        let text = String(decoding: title, as: UTF8.self)
        DispatchQueue.main.async { [weak view] in view?.onTitleChange?(text) }
    }

    /// Each surface keeps the folder for itself (`currentPwd`), as
    /// libghostty's own `pwd` action does for a surface with no session.
    func paneCwd(_ url: Data) {
        guard let path = Self.path(ofCwdURL: url) else { return }
        DispatchQueue.main.async { [weak view] in view?.currentPwd = path }
    }

    func paneMark(_ mark: MactermProtocol.Mark) {
        DispatchQueue.main.async { [weak view] in view?.onSessionMark?(mark) }
    }

    func paneStatus(_ status: MactermProtocol.Status) {
        DispatchQueue.main.async { [weak view] in view?.onSessionStatus?(status) }
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
        let lineMode = TerminalLineMode(canonical: mode.canonical, echo: mode.echo)
        DispatchQueue.main.async { [weak view] in view?.onTtyMode?(lineMode) }
    }

    func paneAttention(_ flags: MactermProtocol.Attention) {
        DispatchQueue.main.async { [weak view] in view?.onAttention?(flags) }
    }

    func paneLead(_ leader: Bool?) {
        DispatchQueue.main.async { [weak view] in view?.onLead?(leader) }
    }

    func paneExited(code _: UInt8?, signal _: UInt8?) {
        sessionEnded()
    }

    func paneGone() {
        sessionEnded()
    }

    private func sessionEnded() {
        DispatchQueue.main.async { [weak view] in
            view?.sessionEnded = true
            view?.onProcessExit?()
        }
    }
}
