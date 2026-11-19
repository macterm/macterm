import CoreGraphics
import Foundation

/// One window's view of one pane: a libghostty view, its scroll view and the
/// UI state that belongs to that view alone (search, copy mode, read-only,
/// hover link, adaptive background, closing ghost).
///
/// The `Pane` is the record: its identity, its session and the runtime state
/// that the session's output decides (titles, foreground, run state, bells).
/// A pane has one surface for each window that draws it, so two windows on one
/// tab show the same pane ids and each has its own view and its own client on
/// the session.
///
/// `SurfaceRegistry` owns the surfaces, keyed by their host and the pane id.
/// The pane holds no view. A surface starts in the incubator; the first host
/// that draws the pane takes it (`SurfaceRegistry.surface(for:in:)`).
@MainActor @Observable
final class PaneSurface: Identifiable {
    let id = UUID()
    @ObservationIgnored
    unowned let pane: Pane
    /// What draws this surface. `.incubator` until a host takes it.
    @ObservationIgnored
    fileprivate(set) var host: SurfaceHost

    /// The window that draws this surface; nil for every other host.
    var windowID: UUID? { host.windowID }

    let searchState = TerminalSearchState()
    /// What the copy-mode pill says (`Copy Mode`, `Select Mode`), nil while the
    /// mode is off. The view's `CopyModeController` owns the mode and reports
    /// it here. Live UI state only — never persisted.
    var copyModeLabel: String?
    /// The surface is read-only (ghostty's `toggle_readonly`): libghostty sends
    /// no input to the pty. Drives the Read-Only pill. A new surface starts
    /// writable, so `destroy` clears it. Live UI state only.
    var isReadOnly = false
    /// Temporary full-pane fill used when a TUI owns this leaf's background in
    /// a split. Presentation only, never persisted, and a CGColor so the model
    /// stays independent of AppKit and SwiftUI.
    var adaptiveBackgroundColor: CGColor?
    /// The OSC 8 link URL under the mouse, for the hover banner
    /// (`GHOSTTY_ACTION_MOUSE_OVER_LINK`). Live UI state only.
    var hoverURL: String?
    /// Bumped when the scroll view finds itself orphaned with no living
    /// container to heal into (#227 — SwiftUI can deallocate a transient
    /// container outright, killing the weak re-attach pointer).
    /// `TerminalPane` reads this, so a bump re-renders the pane's subtree and
    /// `TerminalSurface.updateNSView` re-attaches on a container SwiftUI
    /// guarantees is alive.
    var reattachTick = 0
    /// What the session's last `lead` message said about this surface's
    /// client: true when its size is the pty's. Nil until the session says,
    /// and again after the channel ended. The session decides leadership
    /// (design 004 §5); the app only reads it.
    private(set) var lead: Bool?

    /// Whether this surface's client drives its session's pty size. Only an
    /// explicit false blurs: a client that the session has not answered yet
    /// counts as the leader, so a new pane never blurs before its attach.
    var isLeader: Bool { lead != false }

    /// A claim went out and the session has not answered since. Stops the
    /// repeated focus reports of one click from sending a claim each.
    @ObservationIgnored
    var claimSent = false

    /// The session's `lead` message for this surface's client, or nil when
    /// the channel ended. The first answer after an attach, and every true,
    /// let the key window claim again (`.terminalSessionLead`): a claim that
    /// went out while the channel was down is lost.
    func receiveLead(_ leader: Bool?) {
        let first = lead == nil
        lead = leader
        claimSent = false
        if let leader, leader || first {
            NotificationCenter.default.post(name: .terminalSessionLead, object: id)
        }
    }

    func requestReattach() {
        reattachTick &+= 1
    }

    fileprivate init(pane: Pane, host: SurfaceHost) {
        self.pane = pane
        self.host = host
    }

    /// Whether this surface's runtime callbacks feed the pane: the first
    /// surface of the pane. Every surface parses the same output, so only one
    /// may count titles, runs, bells and notifications.
    var isFeed: Bool { SurfaceRegistry.shared.isFeed(self) }

    /// The live terminal NSView. Created lazily the first time it's requested,
    /// destroyed explicitly with the pane or when its window goes. Owning the
    /// view here (not in a cache or inside SwiftUI) keeps the underlying
    /// ghostty surface alive across any SwiftUI view churn: tab switches,
    /// split tree reshapes, window hide/show. Not observed.
    @ObservationIgnored
    private var _nsView: GhosttyTerminalNSView?

    var nsView: GhosttyTerminalNSView? { _nsView }

    func ensureNSView() -> GhosttyTerminalNSView {
        if let existing = _nsView { return existing }
        let view = SurfaceRegistry.shared.makeView(for: pane)
        view.owningPane = pane
        view.owningSurface = self
        _nsView = view
        connectUICallbacks(view)
        pane.connectViewCallbacks(view, isFeed: isFeed)
        MactermPaneEntity.annotate(view, for: pane)
        return view
    }

    /// The `NSScrollView` that hosts the surface and renders the native
    /// overlay scrollbar. Owned here (not by SwiftUI) for the same reason as
    /// `_nsView`: it must survive tab switches and split reshapes, and it
    /// sidesteps Ghostty's #9444 bug where the scroll wrapper isn't persisted.
    @ObservationIgnored
    private var _scrollView: SurfaceScrollView?

    var scrollView: SurfaceScrollView? { _scrollView }

    func ensureScrollView() -> SurfaceScrollView {
        if let existing = _scrollView { return existing }
        let scroll = SurfaceScrollView(surfaceView: ensureNSView())
        _scrollView = scroll
        return scroll
    }

    /// The surface's last frame, taken as it was torn down, for the animated
    /// split layout to slide out in its place (`AnimatedSplitView` ghosts).
    /// Only the model can take it: by the time SwiftUI sees the pane leave the
    /// tree the view is gone. Captured only while `Preferences.animatedSplits`
    /// is on, so the default path pays nothing. Set with a nil image when the
    /// surface never drew, which still marks the pane as closed rather than
    /// merely moved to another tab.
    @ObservationIgnored
    private(set) var closingSnapshot: PanePreview?

    /// Take `closingSnapshot` now, for a pane that leaves the tree whose
    /// surface is torn down later. `destroy` calls it too.
    func captureClosingSnapshot() {
        if Preferences.shared.animatedSplits, closingSnapshot == nil, _nsView != nil {
            closingSnapshot = PanePreviewCapture.capture(self, longEdge: nil, fillsBackground: false)
        }
    }

    /// How long a destroyed surface keeps `closingSnapshot`. The layout reads
    /// it in the SwiftUI update that follows the close, and the ghost then
    /// holds its own reference for the slide. The time is only a margin for
    /// that one update.
    static let closingSnapshotLifetime: TimeInterval = 2

    /// Drop `closingSnapshot`. The snapshot is a copy of the whole frame (68 MB
    /// for a full-screen pane on a 6K display). The registry keeps a
    /// destroyed surface until its next prune, which can be much later, so
    /// `SurfaceRegistry.destroySurfaces` calls this after
    /// `closingSnapshotLifetime`.
    func releaseClosingSnapshot() {
        closingSnapshot = nil
    }

    /// The callbacks that belong to this view alone: search, copy mode, the
    /// hover link and read-only. Every surface of a pane gets them.
    private func connectUICallbacks(_ view: GhosttyTerminalNSView) {
        view.onLead = { [weak self] leader in self?.receiveLead(leader) }
        view.copyMode.onLabelChange = { [weak self] label in self?.copyModeLabel = label }
        view.onSearchStart = { [weak self, weak view] needle in
            guard let self else { return }
            // Cmd+F toggles: if the search bar is already open, a second
            // start_search closes it (and returns focus to the terminal),
            // mirroring the close button rather than re-opening.
            if searchState.isVisible {
                guard let view else { return }
                view.endSearch()
                // Closing the search bar is a reshape — route focus through
                // FocusRestoration, not a bare makeFirstResponder (see onClose).
                FocusRestoration.restoreFocus(to: pane.id, finder: { [weak self] in self?.pane }, in: view.window)
                return
            }
            if let needle, !needle.isEmpty { searchState.needle = needle }
            searchState.isVisible = true
            searchState.startPublishing { [weak self, weak view] q in
                view?.sendSearchQuery(q)
                // The tick scan must run against the needle the core actually
                // searched, not the live (possibly newer) field text.
                self?.scrollView?.noteSearchNeedle(q)
            }
            if !searchState.needle.isEmpty { searchState.pushNeedle() }
        }
        view.onSearchEnd = { [weak self] in
            guard let self else { return }
            searchState.stopPublishing()
            searchState.isVisible = false
            searchState.needle = ""
            searchState.total = nil
            searchState.selected = nil
            scrollView?.clearSearchTicks()
        }
        view.onSearchTotal = { [weak self] total in
            guard let self else { return }
            searchState.total = total
            if total == nil {
                scrollView?.clearSearchTicks()
            } else {
                scrollView?.refreshSearchTicks()
            }
        }
        view.onSearchSelected = { [weak self] sel in
            self?.searchState.selected = sel
            self?.scrollView?.setSearchSelected(sel)
        }
        view.onLinkHover = { [weak self] url in
            self?.hoverURL = url
        }
        view.onReadOnlyChange = { [weak self] isReadOnly in
            self?.isReadOnly = isReadOnly
        }
    }

    /// True after `destroy`. A destroyed surface never gets a view again.
    ///
    /// SwiftUI updates the leaf of a pane one more time after the pane left
    /// the tree. If that update made a new view, the callbacks of the view
    /// (`TerminalSurface.configure`) would hold the pane, and the registry
    /// holds the surface that holds the view. The pane, the surface and its
    /// full-frame `closingSnapshot` then stayed in memory until the app quit.
    /// `TerminalSurface` reads this flag and makes nothing.
    @ObservationIgnored
    private(set) var isDestroyed = false

    /// Tear down the ghostty surface and null out callbacks. Safe to call
    /// more than once.
    func destroy() {
        captureClosingSnapshot()
        isDestroyed = true
        guard let view = _nsView else { return }
        // Null callbacks before destroy so any in-flight ghostty events
        // triggered by destroySurface() itself can't re-enter.
        view.onProcessExit = nil
        view.onTitleChange = nil
        view.onSearchStart = nil
        view.onSearchEnd = nil
        view.onSearchTotal = nil
        view.onSearchSelected = nil
        view.onFocus = nil
        view.onInteraction = nil
        view.onCommandSubmitted = nil
        view.onSplitRequest = nil
        view.onOpenLink = nil
        view.onDesktopNotification = nil
        view.onCommandFinished = nil
        view.onProgressStarted = nil
        view.onProgressFinished = nil
        view.onRunEnded = nil
        view.onTerminalRender = nil
        view.onBackgroundColorChange = nil
        view.onAdaptiveBackgroundChange = nil
        view.onOutputActivity = nil
        view.onSnapshotMark = nil
        view.onRemoteForeground = nil
        view.onRemoteTtyMode = nil
        view.onAttention = nil
        view.onScrollbarUpdate = nil
        view.onLinkHover = nil
        view.onReadOnlyChange = nil
        isReadOnly = false
        view.onLead = nil
        lead = nil
        claimSent = false
        view.onMouseShapeChange = nil
        view.onPromptTitle = nil
        view.onSetTabTitle = nil
        view.titleProvider = nil
        // Release any secure-input scope this view holds (a pane closed
        // mid-password-prompt must not leave the OS state stuck on).
        view.passwordInput = false
        view.detectedPasswordInput = false
        // Drop any prompt, pending save or bubble this view anchors — a
        // captured password must not outlive its pane.
        PasswordPromptMonitor.shared.forget(view)
        view.destroySurface()
        let scroll = _scrollView
        // Disarm the orphan-healing re-attach BEFORE the removal below —
        // otherwise a destroyed pane would climb back into its old container.
        scroll?.reattachHost = nil
        scroll?.onOrphaned = nil
        _scrollView = nil
        _nsView = nil
        // Keep the NSView (and its scroll-view host) alive for a runloop tick so
        // any in-flight ghostty callback (which holds an unretained pointer to
        // the view) can drain before the view is deallocated. Without this,
        // SwiftUI can remove the view from its superview the same turn we
        // destroy the surface, deallocating the NSView before ghostty has
        // finished unwinding.
        DispatchQueue.main.async {
            _ = view
            // Detach the scroll view from whatever still hosts it — notably the
            // SurfaceIncubator's hidden window, which never removes warmed
            // views itself — so the dead view pair can actually deallocate.
            scroll?.removeFromSuperview()
        }
    }
}

/// What draws a surface. A pane has at most one surface for each host.
enum SurfaceHost: Hashable {
    /// A main window, by its `WindowState.id`.
    case window(UUID)
    /// No host yet: the hidden incubator window, the CLI and the other callers
    /// with no view of their own. The first host that draws the pane takes
    /// this surface.
    case incubator
    /// The quick terminal's panel.
    case quickTerminal
    /// A desktop widget's panel, by the widget's id.
    case widget(UUID)

    var windowID: UUID? {
        if case let .window(id) = self { return id }
        return nil
    }
}

/// The surfaces of every pane, keyed by host and pane id (design 010 §5).
///
/// The pane is the model record and holds no view. Everything that makes,
/// finds or destroys a libghostty view goes through here, so the record can
/// become a value after the model cut-over.
///
/// Each pane's list is in the order that its surfaces came, and is never
/// empty once asked for. The first one is the feed: its callbacks count
/// titles, runs, bells and notifications for the pane, and its exit ends the
/// pane.
@MainActor
final class SurfaceRegistry {
    static let shared = SurfaceRegistry()

    private struct Entry {
        weak var pane: Pane?
        var surfaces: [PaneSurface] = []
        /// The pane has built a view. `Pane.start` is a first-spawn input
        /// (`PaneStartCommand`): a later build — a reconnect, a second
        /// window — attaches an EXISTING session, so the command would run a
        /// second time.
        var hasBuiltView = false
    }

    private var entries: [UUID: Entry] = [:]

    /// The surfaces of `pane`, the feed first. Makes the incubator surface
    /// when the pane has none, so the list is never empty. Makes no view.
    func surfaces(of pane: Pane) -> [PaneSurface] {
        if let existing = entries[pane.id]?.surfaces, !existing.isEmpty { return existing }
        pruneReleasedPanes()
        let first = PaneSurface(pane: pane, host: .incubator)
        entries[pane.id] = Entry(pane: pane, surfaces: [first])
        return [first]
    }

    /// The surface that `host` draws `pane` with. The incubator gets the feed
    /// surface. Any other host first takes the surface that no host has (the
    /// incubator's, the CLI's), else gets a surface of its own, which is a
    /// second client of the same session.
    ///
    /// Makes only the model object. No view and no client exist until the
    /// surface's `ensureNSView`, so a body may call it.
    func surface(for pane: Pane, in host: SurfaceHost) -> PaneSurface {
        let all = surfaces(of: pane)
        if host == .incubator { return all[0] }
        if let existing = all.first(where: { $0.host == host }) { return existing }
        if let free = all.first(where: { $0.host == .incubator }) {
            free.host = host
            return free
        }
        let surface = PaneSurface(pane: pane, host: host)
        entries[pane.id]?.surfaces.append(surface)
        return surface
    }

    /// The surface of `host`, if the pane has one. Makes nothing.
    func existingSurface(for pane: Pane, in host: SurfaceHost) -> PaneSurface? {
        guard let all = entries[pane.id]?.surfaces else { return nil }
        if host == .incubator { return all.first }
        return all.first { $0.host == host }
    }

    /// The surface for the callers with no host in hand (the CLI, intents,
    /// persistence and previews): the one in the key window, else one in a
    /// visible window, else the first that has a view, else the first.
    func preferredSurface(of pane: Pane) -> PaneSurface {
        let all = surfaces(of: pane)
        let live = all.filter { $0.nsView != nil }
        return live.first { $0.nsView?.window?.isKeyWindow == true }
            ?? live.first { $0.nsView?.window?.isVisible == true }
            ?? live.first
            ?? all[0]
    }

    /// The preferred surface's view, if it has one. Makes nothing.
    func view(of pane: Pane) -> GhosttyTerminalNSView? {
        guard entries[pane.id] != nil else { return nil }
        return preferredSurface(of: pane).nsView
    }

    /// The preferred surface's view, made if it has none.
    func ensureView(of pane: Pane) -> GhosttyTerminalNSView {
        preferredSurface(of: pane).ensureNSView()
    }

    /// The preferred surface's scroll view, made if it has none.
    func ensureScrollView(of pane: Pane) -> SurfaceScrollView {
        preferredSurface(of: pane).ensureScrollView()
    }

    /// Whether `surface` is its pane's feed.
    func isFeed(_ surface: PaneSurface) -> Bool {
        entries[surface.pane.id]?.surfaces.first === surface
    }

    /// A new libghostty view for one of the pane's surfaces.
    func makeView(for pane: Pane) -> GhosttyTerminalNSView {
        _ = surfaces(of: pane)
        let hasBuilt = entries[pane.id]?.hasBuiltView ?? false
        // Every pane's shell learns its own restart-stable address so
        // `macterm` invoked inside it can self-target (`MACTERM_SESSION`).
        // Injected at spawn, which means a reattached shell keeps the
        // value from its original spawn — correct, because the session name
        // is persisted verbatim and survives restarts (pane UUIDs don't).
        // Our value wins over a layout-declared duplicate: this is identity,
        // not configuration.
        var mergedEnv = pane.env ?? [:]
        mergedEnv[ControlProtocol.sessionEnvVar] = pane.sessionName
        let view = GhosttyTerminalNSView(
            paneID: pane.id,
            workingDirectory: pane.projectPath,
            sessionName: pane.sessionName,
            start: hasBuilt ? nil : pane.start,
            shell: pane.shell,
            env: mergedEnv,
            remoteSpec: pane.remoteSpec
        )
        entries[pane.id]?.hasBuiltView = true
        return view
    }

    /// Give up every surface of window `windowID`. A pane keeps its last
    /// surface, which goes back to the incubator, so a warm view survives a
    /// closed window.
    func releaseSurfaces(ofWindow windowID: UUID) {
        for entry in entries.values where entry.pane != nil {
            for surface in entry.surfaces where surface.host == .window(windowID) {
                if entries[surface.pane.id]?.surfaces.count == 1 {
                    surface.host = .incubator
                } else {
                    retire(surface)
                }
            }
        }
        pruneReleasedPanes()
    }

    /// Destroy and drop one surface while another remains. A client that goes
    /// ends only its own channel: the session is the pane's, never the
    /// surface's. When the first surface goes, the next one becomes the feed
    /// and takes over the runtime callbacks.
    func retire(_ surface: PaneSurface) {
        let pane = surface.pane
        guard var all = entries[pane.id]?.surfaces, all.count > 1,
              let index = all.firstIndex(where: { $0 === surface })
        else { return }
        surface.captureClosingSnapshot()
        all.remove(at: index)
        entries[pane.id]?.surfaces = all
        if index == 0 {
            // The old feed may have gone between the two snapshot marks.
            pane.receiveRemoteSnapshot(started: false)
            if let view = all[0].nsView { pane.connectViewCallbacks(view, isFeed: true) }
        }
        // Deferred: a retire can come from inside a SwiftUI update while the
        // view is still in a hierarchy.
        DispatchQueue.main.async { surface.destroy() }
    }

    /// Tear down every surface's view of `pane` and null out its callbacks.
    /// Call when the pane leaves the tree for good, or for a remote reconnect.
    /// Safe to call more than once. The surfaces stay, with no view.
    func destroySurfaces(of pane: Pane) {
        let all = entries[pane.id]?.surfaces ?? []
        pane.surfacesWillTearDown(hadView: all.contains { $0.nsView != nil })
        for surface in all {
            surface.destroy()
        }
        pruneReleasedPanes()
        // The pane is usually still alive here, so the prune above keeps its
        // entry. Come back when the ghost has its snapshot: free the frame
        // copies and drop the entry of a pane that is gone.
        guard !all.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneSurface.closingSnapshotLifetime) { [weak self] in
            for surface in all {
                surface.releaseClosingSnapshot()
            }
            self?.pruneReleasedPanes()
        }
    }

    /// Drop the entries of panes that are gone, with their surfaces and
    /// views. A pane that leaves the tree has its surfaces destroyed first;
    /// this frees what is left, so no view outlives its pane for long. Runs
    /// when an entry is made, and after each teardown and window release.
    private func pruneReleasedPanes() {
        let released = entries.filter { $0.value.pane == nil }
        guard !released.isEmpty else { return }
        for entry in released.values {
            entry.surfaces.forEach { $0.destroy() }
        }
        entries = entries.filter { $0.value.pane != nil }
    }
}

extension Pane {
    /// Whether closing this pane must be confirmed first because a foreground
    /// program is running. This is the single signal every busy-close guard
    /// reads (pane/tab close, project removal, the CLI's `busy` error,
    /// the quit dialog rows).
    ///
    /// The verdict itself is `ForegroundPolicy.needsConfirmClose` — a pure
    /// function over the pane's sample, so the local/remote asymmetry lives
    /// in exactly one tested place. This wrapper just feeds it the live
    /// surface signal.
    var needsConfirmClose: Bool {
        let view = SurfaceRegistry.shared.view(of: self)
        return ForegroundPolicy.needsConfirmClose(
            sample: foregroundSample,
            executionState: executionState,
            isRemote: isRemote,
            hasSurface: view != nil,
            surfaceBusy: view?.needsConfirmQuit() == true
        )
    }

    /// Returns a local pane's cwd. Remote cwd values omit the host, so remote
    /// panes return nil.
    func liveLocalWorkingDirectory() -> String? {
        guard !isRemote else { return nil }
        return SurfaceRegistry.shared.view(of: self)?.currentPwd
            ?? ProcessInspector.foregroundWorkingDirectory(forPane: self)
    }
}
