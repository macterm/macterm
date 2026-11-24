import Foundation

/// The live pane previews of the tab switcher (#344) and of the project
/// screen's grid. It is the one owner of `GhosttyTerminalNSView.rendersForPreview`.
///
/// Each view that shows previews is a client. A client gives the panes it
/// shows with `begin` and takes them back with `end`. The sampler wakes the
/// renderer of each pane that any client shows, and samples all of them at
/// `interval` while one or more clients show panes. A pane that two clients
/// show is woken one time, and it stays awake until the last of them ends.
/// When no client shows a pane, no renderer stays awake and the timer is off.
///
/// An off-screen pane's renderer is parked (`syncOcclusion`) and holds no
/// frame, so without the wake-up there is nothing to sample. Waking it makes
/// libghostty draw at once, and the pty has kept the screen current all
/// along.
@MainActor @Observable
final class PanePreviewSampler {
    /// A view that shows live previews.
    enum Client: Hashable {
        /// The tab switcher overlay while a Recent Tab cycle shows it.
        case tabSwitcher
        /// The project screen of one window.
        case projectScreen(WindowState.ID)
    }

    /// Sampling cadence while a client shows panes. Fast enough to read as
    /// the terminal moving; the copy for each pane is a downsample of one
    /// frame, and `PanePreview.frameID` skips a pane that drew nothing new.
    static let interval: TimeInterval = 0.2

    /// The last preview of each pane, keyed by pane ID: what the cards draw.
    ///
    /// The entries outlive a client on purpose: the next one opens on each
    /// pane's last frame for the tick or two that a woken renderer needs,
    /// not on a bare fill. `store` never lets a frameless sample erase a
    /// frame, so a card only goes from nothing to a picture.
    private(set) var previews: [UUID: PanePreview] = [:]

    /// The panes of each client. Kept as panes, not as IDs to look up later:
    /// a tab that closes while a client shows it must still get its override
    /// cleared.
    @ObservationIgnored
    private var clientPanes: [Client: [Pane]] = [:]
    /// The panes whose renderers this sampler holds awake: the union of
    /// `clientPanes`.
    @ObservationIgnored
    private var awakePanes: [UUID: Pane] = [:]
    @ObservationIgnored
    private var timer: Timer?

    /// Whether any client shows panes.
    var isSampling: Bool { timer != nil }

    /// Whether `client` shows panes.
    func isSampling(for client: Client) -> Bool {
        clientPanes[client] != nil
    }

    /// Show `panes` for `client`, in place of what it showed before. Wakes
    /// the renderers that are new, parks those that no client shows now,
    /// and samples at once: the frames that exist now (a pane on screen)
    /// show at once, and the woken renderers are picked up by the next tick.
    func begin(_ client: Client, panes: [Pane]) {
        clientPanes[client] = panes
        sync()
        sample()
    }

    /// Stop showing the panes of `client`. Every exit of a client goes
    /// through here, so no renderer stays awake.
    func end(_ client: Client) {
        guard clientPanes.removeValue(forKey: client) != nil else { return }
        sync()
    }

    /// Drop the previews of panes that closed. `live` is every pane of every
    /// workspace: a preview belongs to a pane, and a pane in another project
    /// is still alive.
    func forget(keeping live: Set<UUID>) {
        previews = previews.filter { live.contains($0.key) }
    }

    /// Make the awake set the union of the clients' panes, and run the timer
    /// only while that set has panes.
    private func sync() {
        var wanted: [UUID: Pane] = [:]
        for pane in clientPanes.values.joined() {
            wanted[pane.id] = pane
        }
        for (id, pane) in awakePanes where wanted[id] == nil {
            SurfaceRegistry.shared.view(of: pane)?.rendersForPreview = false
        }
        for (id, pane) in wanted where awakePanes[id] == nil {
            SurfaceRegistry.shared.view(of: pane)?.rendersForPreview = true
        }
        awakePanes = wanted
        if wanted.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// One sampling tick. Each pane's last preview goes back in, so a pane
    /// whose renderer drew nothing since is returned as it is: the copy is
    /// the cost, and only the panes that move pay it.
    private func sample() {
        for pane in awakePanes.values {
            // Again at each tick: a pane whose view did not exist at `begin`
            // (a tab that the launch warms later) gets its renderer woken
            // when the view comes. The setter ignores an unchanged value.
            SurfaceRegistry.shared.view(of: pane)?.rendersForPreview = true
            store(PanePreviewCapture.capture(pane, reusing: previews[pane.id]), for: pane.id)
        }
    }

    /// Keep the best preview: a sample that came back frameless must not
    /// erase a frame, so a pane whose woken renderer has not drawn yet keeps
    /// its last picture.
    /// A sample that is the stored one (nothing drawn since) is not stored
    /// again, so the cards do not draw again at each tick.
    private func store(_ preview: PanePreview, for paneID: UUID) {
        let old = previews[paneID]
        if preview.image == nil, old?.image != nil { return }
        if let old, old.image === preview.image, old.background == preview.background { return }
        previews[paneID] = preview
    }
}
