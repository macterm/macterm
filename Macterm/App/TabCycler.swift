import Foundation

/// The Recent Tab cycle (Ctrl+Tab) and the tab switcher's live previews
/// (#344). It holds the order that a cycle walks. The cards' pictures come
/// from the shared `PanePreviewSampler`. It holds no tab and changes no
/// model: `AppState` asks it which tab a gesture picked and selects that tab
/// itself, so the cycle survives the model cut-over unchanged.
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

    /// Aspect ratio of the region a workspace's panes fill on screen, so the
    /// switcher's cards can be shaped like the thing they picture rather than
    /// cropping it. Measured from whichever tab is visible; every tab in the
    /// workspace fills the same container, so one value shapes the strip.
    private(set) var paneContainerAspect: CGFloat?

    /// The live previews of the cards, shared with the project screen
    /// (`PanePreviewSampler`).
    @ObservationIgnored
    let sampler: PanePreviewSampler

    /// Whether a cycle is currently re-sampling its cards.
    var isLivePreviewing: Bool { sampler.isSampling(for: .tabSwitcher) }

    init(sampler: PanePreviewSampler = PanePreviewSampler()) {
        self.sampler = sampler
    }

    /// Start a cycle over `recency` (the workspace's tabs, most recent first)
    /// unless one is in flight. The limit bounds the cycle whether or not the
    /// switcher shows it: the cards and the keyboard walk one list, so a limit
    /// that only applied with the overlay on would make a tab's reachability
    /// depend on a display preference.
    func startIfNeeded(recency: [UUID], in ws: Workspace, livePaneIDs: () -> Set<UUID>) {
        guard order.isEmpty else { return }
        let candidateLimit = Preferences.shared.recentTabCandidates
        order = candidateLimit == Preferences.unlimitedRecentTabCandidates
            ? recency
            : Array(recency.prefix(candidateLimit))
        index = 0
        preparePreviews(in: ws, livePaneIDs: livePaneIDs)
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
        sampler.end(.tabSwitcher)
        let selected = selectedTabID
        order = []
        index = 0
        return selected
    }

    /// Ready the cards for the workspace a cycle is about to walk: shape them
    /// from the visible tab (the only one with a measurable on-screen region),
    /// forget panes that have closed, and start sampling. Skipped entirely
    /// when the overlay is off, so the default cycling path costs nothing.
    private func preparePreviews(in ws: Workspace, livePaneIDs: () -> Set<UUID>) {
        guard Preferences.shared.showTabSwitcherOverlay else { return }
        if let tab = ws.activeTab, let aspect = PanePreviewCapture.containerAspect(of: tab) {
            paneContainerAspect = aspect
        }
        // Drop previews of panes that have closed, across every workspace.
        sampler.forget(keeping: livePaneIDs())
        // Wake and sample every pane the cycle offers, the visible tab's
        // too: it is on screen anyway, and one rule beats tracking which tab
        // that is. `finish` ends it.
        let cycleTabs = order.compactMap { id in ws.tabs.first { $0.id == id } }
        sampler.begin(.tabSwitcher, panes: cycleTabs.flatMap { $0.splitRoot.allPanes() })
    }
}
