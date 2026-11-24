import Foundation

/// The way from a pane's surface to its session: the surface's view on the
/// pane's `PaneLink` (`PaneLink.attach`), so the view only hosts the
/// surface.
struct PaneRoute {
    /// Where the surface sends keys, sizes and claims.
    let input: any PaneInputRoute
    /// Starts the reading. The surface exists.
    let start: @Sendable () -> Void
    /// Ends the reading. The session keeps running.
    let stop: @Sendable () -> Void
}
