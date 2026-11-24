import Foundation

/// The way from a pane's surface to its session: a `PaneSession` on the
/// local endpoint, or the driver of a remote pane, which runs a
/// `PaneSession` on its host's link. `make` picks it from the pane's
/// place, so the view only hosts the surface.
struct PaneRoute {
    /// Where the surface sends keys, sizes and claims.
    let input: any PaneInputRoute
    /// Starts the reading. The surface exists.
    let start: @Sendable () -> Void
    /// Ends the reading. The session keeps running.
    let stop: @Sendable () -> Void

    /// The route of the session `name`. A remote pane (`remote`) gets its
    /// host from the pane that shows the session; `launch` is then nil,
    /// because its session runs the user's login shell on the host.
    @MainActor
    static func make(
        session name: String,
        remote: Bool,
        launch: PaneSession.Launch?,
        surface: any PaneSessionHost,
        local: any ServerEndpoint = LocalSessions.shared
    ) -> PaneRoute {
        if remote {
            let driver = RemotePaneDriver(name: name, surface: surface)
            return PaneRoute(
                input: driver,
                start: { DispatchQueue.main.async { MainActor.assumeIsolated { driver.start() } } },
                stop: { DispatchQueue.main.async { MainActor.assumeIsolated { driver.stop() } } }
            )
        }
        let session = PaneSession(
            name: name,
            launch: launch,
            wantsForeground: true,
            wantsTty: true,
            host: surface,
            endpoint: local
        )
        return PaneRoute(input: session, start: { session.start() }, stop: { session.stop() })
    }
}
