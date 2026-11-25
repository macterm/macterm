import Foundation

/// The Recent Tab cycle (Ctrl+Tab) and the tab switcher's live previews
/// (#344). It holds the order that a cycle walks and the cards' pictures. It
/// holds no tab and changes no model: `AppState` asks it which tab a gesture
/// picked and selects that tab itself, so the cycle survives the model
/// cut-over unchanged.
@MainActor @Observable
final class TabCycler {
    /// The tab IDs the current cycle walks, most-recent-first. Empty when no
    /// cycle is in flight.
    private(set) var order: [UUID] = []
    /// Where in `order` the gesture currently sits.
    private(set) var index = 0

    var isCycling: Bool { !order.isEmpty }

    /// The tab the gesture currently points at.
    var selectedTabID: UUID? { order.indices.contains(index) ? order[index] : nil }

    /// Last sampled preview per pane, keyed by pane ID — what the tab
    /// switcher renders.
    ///
    /// Filled only while a cycle is showing the switcher: `beginLivePreviews`
    /// wakes the renderer of every offered pane (an off-screen renderer is
    /// parked and holds no frame, see `PanePreview`) and re-samples them all
    /// on a timer until the cycle commits, so a card pictures its tab as it
    /// is now. The entries outlive the gesture on purpose — the next one opens
    /// on each tab's last frame for the tick or two the woken renderers need,
    /// instead of on a bare fill — and `store` never lets a frameless sample
    /// erase a frame, so a card can only ever go from nothing to a picture.
    private(set) var panePreviews: [UUID: PanePreview] = [:]

    /// Aspect ratio of the region a workspace's panes fill on screen, so the
    /// switcher's cards can be shaped like the thing they picture rather than
    /// cropping it. Measured from whichever tab is visible; every tab in the
    /// workspace fills the same container, so one value shapes the strip.
    private(set) var paneContainerAspect: CGFloat?

    /// The panes whose renderers a cycle in flight is keeping awake
    /// (`GhosttyTerminalNSView.rendersForPreview`), and the timer re-sampling
    /// them. Remembered as panes, not looked up from the cycle order: a tab
    /// that closes mid-gesture must still get its override cleared. Both are
    /// empty whenever no cycle is showing the switcher.
    @ObservationIgnored
    private var livePreviewPanes: [Pane] = []
    @ObservationIgnored
    private var livePreviewTimer: Timer?
    /// Sampling cadence while the switcher is up. Fast enough to read as the
    /// terminal moving; the copy per pane is a downsample of one frame.
    static let livePreviewInterval: TimeInterval = 0.2
    /// Whether a cycle is currently re-sampling its cards.
    var isLivePreviewing: Bool { livePreviewTimer != nil }

    /// Start a cycle over `recency` (the project's tabs, most recent first)
    /// unless one is in flight. The limit bounds the cycle whether or not the
    /// switcher shows it: the cards and the keyboard walk one list, so a limit
    /// that only applied with the overlay on would make a tab's reachability
    /// depend on a display preference.
    func startIfNeeded(recency: [UUID], tabs: [TerminalTab], livePaneIDs: () -> Set<UUID>) {
        guard order.isEmpty else { return }
        let candidateLimit = Preferences.shared.recentTabCandidates
        order = candidateLimit == Preferences.unlimitedRecentTabCandidates
            ? recency
            : Array(recency.prefix(candidateLimit))
        index = 0
        preparePreviews(tabs: tabs, livePaneIDs: livePaneIDs)
    }

    /// Move the gesture to the next tab. False when there is nothing to move
    /// to (a cycle of one tab).
    func advance() -> Bool {
        guard order.count > 1 else { return false }
        index = (index + 1) % order.count
        return true
    }

    /// Point the in-flight cycle at `index` without committing — what hovering
    /// a card in the switcher does. Out-of-range indices are ignored, since a
    /// tab can close under the pointer mid-gesture.
    func focus(at index: Int) {
        guard order.indices.contains(index) else { return }
        self.index = index
    }

    /// End the cycle and return the tab it picked, nil when none was in
    /// flight. Every way a cycle ends goes through here, so no renderer is
    /// left awake.
    func finish() -> UUID? {
        endLivePreviews()
        let selected = selectedTabID
        order = []
        index = 0
        return selected
    }

    /// Ready the cards for the workspace a cycle is about to walk: shape them
    /// from the visible tab (the only one with a measurable on-screen region),
    /// forget panes that have closed, and start sampling. Skipped entirely
    /// when the overlay is off, so the default cycling path costs nothing.
    private func preparePreviews(tabs: [TerminalTab], livePaneIDs: () -> Set<UUID>) {
        guard Preferences.shared.showTabSwitcherOverlay else { return }
        if let tab = order.first.flatMap({ id in tabs.first { $0.id == id } }), let aspect = PanePreviewCapture.containerAspect(of: tab) {
            paneContainerAspect = aspect
        }
        // Drop previews of panes that have closed. Checked across every
        // workspace, not just this one — a cached preview belongs to a pane,
        // and a pane in another project is still alive.
        let live = livePaneIDs()
        panePreviews = panePreviews.filter { live.contains($0.key) }
        beginLivePreviews(tabs: tabs)
    }

    /// Keep the cards current for as long as the gesture lasts: wake the
    /// renderer of every pane the cycle offers and sample them all, now and
    /// then on a timer. An off-screen pane's renderer is parked
    /// (`syncOcclusion`) and holds no frame, so without the wake-up there
    /// would be nothing to sample; waking it makes libghostty rebuild and draw
    /// at once, and the pty has kept the screen current all along. Every pane
    /// is woken, the visible tab's included — it is on screen anyway, and one
    /// rule beats tracking which tab that is. The immediate sample is for the
    /// visible tab, whose frame exists right now; the woken renderers draw
    /// asynchronously and are picked up by the first tick, under the overlay's
    /// fade-in. Undone by `endLivePreviews`.
    private func beginLivePreviews(tabs: [TerminalTab]) {
        endLivePreviews()
        let cycleTabs = order.compactMap { id in tabs.first { $0.id == id } }
        livePreviewPanes = cycleTabs.flatMap { $0.splitRoot.allPanes() }
        for pane in livePreviewPanes {
            SurfaceRegistry.shared.view(of: pane)?.rendersForPreview = true
        }
        captureLivePreviews()
        let timer = Timer(timeInterval: Self.livePreviewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureLivePreviews() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livePreviewTimer = timer
    }

    /// One sampling tick. Each pane's last preview is handed back in so a
    /// pane whose renderer drew nothing since is returned as is — the copy
    /// is the cost here, and only the panes that are actually moving pay it.
    private func captureLivePreviews() {
        for pane in livePreviewPanes {
            store(PanePreviewCapture.capture(pane, reusing: panePreviews[pane.id]), for: pane.id)
        }
    }

    /// Park the renderers `beginLivePreviews` woke and stop sampling.
    private func endLivePreviews() {
        livePreviewTimer?.invalidate()
        livePreviewTimer = nil
        for pane in livePreviewPanes {
            SurfaceRegistry.shared.view(of: pane)?.rendersForPreview = false
        }
        livePreviewPanes = []
    }

    /// Keep the best preview we have: a sample that came back frameless must
    /// not erase a frame already collected, so a pane whose woken renderer has
    /// not drawn yet keeps showing its last picture rather than blanking.
    private func store(_ preview: PanePreview, for paneID: UUID) {
        if preview.image == nil, panePreviews[paneID]?.image != nil { return }
        panePreviews[paneID] = preview
    }
}
