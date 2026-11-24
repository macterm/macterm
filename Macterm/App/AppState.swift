import AppKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState")

/// Thread-safe ownership for block-based notification observers. `AppState`
/// installs observers on the main actor, while Swift deinitializers are
/// nonisolated; keeping the non-Sendable tokens behind this lock lets teardown
/// drain them without unsafe actor annotations on observable state.
private final class ObserverTokenStore: @unchecked Sendable {
    private typealias Entry = (center: NotificationCenter, token: NSObjectProtocol)

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(center: NotificationCenter, token: NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((center, token))
    }

    func append(contentsOf newEntries: [(center: NotificationCenter, token: NSObjectProtocol)]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(contentsOf: newEntries)
    }

    func removeAllObservers() {
        lock.lock()
        let drained = entries
        entries.removeAll()
        lock.unlock()

        for entry in drained {
            entry.center.removeObserver(entry.token)
        }
    }
}

@MainActor @Observable
final class AppState {
    var activeProjectID: UUID? {
        didSet {
            Preferences.shared.activeProjectID = activeProjectID
            // Push into the key window too (#345). Most callers still set this
            // directly — CLI `project select`, notification navigation, a
            // cross-project tab move — and the window the user is looking at
            // has to follow, or it would keep rendering the old project while
            // everything else moved on.
            if let keyWindowID, let key = windows.first(where: { $0.id == keyWindowID }),
               key.activeProjectID != activeProjectID
            {
                key.activeProjectID = activeProjectID
                alignKeyWindowTab()
                persistWindows()
            }
        }
    }

    // MARK: - Windows (#345)

    /// Every open terminal window's own state, in creation order.
    ///
    /// `activeProjectID` above is the KEY window's project — a mirror, kept in
    /// step by `noteKeyWindow`. Views that render one specific window read
    /// that window's `WindowState` instead, or a background window would
    /// redraw itself as whatever the frontmost one is showing.
    var windows: [WindowState] { windowRegistry.windows }

    /// The window the user is in. Nil before the first window reports itself,
    /// and briefly while macOS has no key window (every window hidden).
    var keyWindowID: WindowState.ID? { windowRegistry.keyWindowID }

    /// The table of open windows (`WindowRegistry`).
    let windowRegistry = WindowRegistry()

    /// The real `AppDelegate`, handed over by the scene at launch.
    ///
    /// NOT `NSApp.delegate as? AppDelegate`: SwiftUI installs its OWN delegate
    /// — an internal class that happens to be called `AppDelegate` too — which
    /// forwards to ours, so that cast silently returns nil forever. It is
    /// silent because every use is an optional chain, which just no-ops.
    /// `@NSApplicationDelegateAdaptor` gives the scene the genuine instance,
    /// so pass it in rather than trying to find it.
    weak var appDelegate: AppDelegate?

    /// Opens another terminal window.
    ///
    /// Installed by the scene, because opening a `WindowGroup` window needs
    /// SwiftUI's `openWindow` environment action and command handlers are not
    /// views. Nil until the first window's view tree appears — a New Window
    /// invoked before then is dropped rather than crashing, and by then the
    /// app has a window anyway.
    var openNewWindow: (() -> Void)?

    /// Opens the Settings window, or fronts it when it is open.
    ///
    /// Installed by `MainWindow` for the same reason as `openNewWindow`: the
    /// `Settings` scene opens only through SwiftUI's `openSettings`
    /// environment action. Nil until the first window's view tree appears —
    /// a Settings invoked before then is dropped, as for `openNewWindow`.
    var openSettings: (() -> Void)?

    /// Windows the snapshot says were open, minus the one the scene opens for
    /// itself — a FIFO that `registerWindow` pops as each restored window
    /// arrives, so every window adopts its own entry in order. This used to be
    /// a single "next window" slot refilled by a timer per window, and the
    /// slot raced: a window the user opened during the restore burst took the
    /// entry meant for a restored one, and that one then opened on whatever
    /// was frontmost.
    private var pendingWindowRestores: [WindowSnapshot] = []

    /// What the snapshot said, held until `restoreWindows` runs. Kept apart
    /// from the FIFO because the scene's own window can register BEFORE the
    /// launch task — if the loaded list were the FIFO, that window would pop
    /// the first entry early and every later window would be off by one. It
    /// can also register after; see `windowAdoptedBeforeRegistration`.
    private var savedWindowSnapshots: [WindowSnapshot] = []

    /// The scene's own window, when `restoreWindows` adopted the first saved
    /// entry before that window attached and registered. The launch task can
    /// run first. `registerWindow` then found no pending entry after the
    /// restore and took the window for one the user opened: it reset the
    /// saved sidebar width and visibility to the defaults, and the next save
    /// wrote the defaults over the snapshot (#552). The window already has
    /// its state, so `registerWindow` must not touch it.
    private weak var windowAdoptedBeforeRegistration: WindowState?

    /// Creation-order index of the window that was key at quit, fronted once
    /// the last restored window has registered. Every restored window opens
    /// key, so without this the LAST one to open ended up key and the
    /// app-wide project followed it rather than the one the user was in.
    private var pendingKeyWindowIndex: Int?

    /// Reopen the windows a previous run had, and point the first one at the
    /// project it was showing.
    ///
    /// Called by the first `MainWindow` to appear: the scene always opens one
    /// window by itself, so that one adopts the first saved entry and only the
    /// REST are opened. Opening all of them would leave a spare window on
    /// every launch.
    /// Set once `restoreWindows` has run — the moment a window's saved
    /// sidebar state is known. `WindowAppearance`'s restore waits for it.
    private(set) var hasRestoredWindows = false

    /// Work parked by `performWhenRestored` until the launch restore is done.
    /// Ignored for observation: appending here is bookkeeping, not state a
    /// view renders.
    @ObservationIgnored private var deferredUntilRestored: [@MainActor () -> Void] = []

    /// Run `work` now if the launch restore has finished, else right after it
    /// does. For a request that reaches the app from outside during launch — a
    /// Finder service that launched it, say — acting immediately would have
    /// `restoreSelection` overwrite whatever the request selected a beat
    /// later; acting after `restoreWindows` is the first moment the request's
    /// effect sticks.
    func performWhenRestored(_ work: @escaping @MainActor () -> Void) {
        if hasRestoredWindows {
            work()
        } else {
            deferredUntilRestored.append(work)
        }
    }

    private func runDeferredUntilRestored() {
        let work = deferredUntilRestored
        deferredUntilRestored = []
        for item in work {
            item()
        }
    }

    func restoreWindows(adopting first: WindowState) {
        defer {
            // The adopted window is in `renderingWindows` from here on.
            settleWindowSelections()
            hasRestoredWindows = true
            runDeferredUntilRestored()
        }
        let saved = savedWindowSnapshots
        savedWindowSnapshots = []
        if !windows.contains(where: { $0.id == first.id }) {
            windowAdoptedBeforeRegistration = first
        }
        // This runs after `restoreSelection`, which is the first moment the
        // app knows which project to show — the window registered before that
        // and so still has none.
        if first.activeProjectID == nil { first.activeProjectID = activeProjectID }
        guard !saved.isEmpty else { return }
        first.activeProjectID = saved[0].activeProjectID ?? first.activeProjectID
        // After the project: a change of project clears the flag.
        first.showsProjectScreen = saved[0].showsProjectScreen ?? false
        if let width = saved[0].sidebarWidth { first.sidebarWidth = width }
        if let visible = saved[0].sidebarVisible { first.sidebarVisible = visible }
        if let visible = saved[0].projectMemoryPanelVisible { first.projectMemoryPanelVisible = visible }
        // After the project: making a project active opens its section, and
        // the saved set must win over that.
        if let expanded = saved[0].expandedProjectIDs { first.expandedRows = Set(expanded) }
        if let frame = saved[0].frame {
            first.frame = frame
            applyRestoredFrame(of: first)
        }
        recordRestoredTab(saved[0].activeTabID, in: first)
        if keyWindowID == first.id {
            activeProjectID = first.activeProjectID
            alignKeyWindowTab()
        }
        guard saved.count > 1 else { return }
        pendingKeyWindowIndex = saved.firstIndex { $0.isKey == true }
        pendingWindowRestores = Array(saved.dropFirst())
        logger.info("restoreWindows: reopening \(saved.count - 1, privacy: .public) extra window(s)")
        // Deferred, and spaced. This runs inside the launch task, and AppKit
        // ignores an open-untitled request made while it is still handling
        // launch — asking immediately opened nothing at all. Spacing keeps
        // registration order equal to request order, which is what lets the
        // FIFO hand each window its own entry.
        for offset in 0 ..< (saved.count - 1) {
            let delay = Self.windowRestoreDelay * Double(offset + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.requestNewWindow()
            }
        }
        // An entry still queued well after the last request belongs to a
        // window AppKit never opened. Drop it, or a window the user opens
        // later would adopt a stale project and width.
        let cutoff = Self.windowRestoreDelay * Double(saved.count) + 3
        DispatchQueue.main.asyncAfter(deadline: .now() + cutoff) { [weak self] in
            guard let self, !pendingWindowRestores.isEmpty else { return }
            logger.warning(
                "restoreWindows: \(self.pendingWindowRestores.count, privacy: .public) window(s) never opened"
            )
            pendingWindowRestores = []
            pendingKeyWindowIndex = nil
        }
    }

    /// Spacing between restored window opens (see `restoreWindows`).
    private static let windowRestoreDelay: TimeInterval = 0.6

    /// Once the last restored window is in, front the one that was key at
    /// quit. Deferred a turn: the window that just registered is mid-attach
    /// and about to become key itself, and this has to land after that.
    private func frontRestoredKeyWindowIfNeeded() {
        guard pendingWindowRestores.isEmpty, let index = pendingKeyWindowIndex else { return }
        pendingKeyWindowIndex = nil
        guard windows.indices.contains(index), let nsWindow = nsWindow(for: windows[index]) else { return }
        DispatchQueue.main.async { nsWindow.makeKeyAndOrderFront(nil) }
    }

    func requestNewWindow() {
        guard let openNewWindow else {
            logger.warning("requestNewWindow: no scene handler installed yet")
            return
        }
        openNewWindow()
    }

    func requestSettings() {
        guard let openSettings else {
            logger.warning("requestSettings: no scene handler installed yet")
            return
        }
        openSettings()
    }

    /// One `WindowState` per real window, keyed by its `NSWindow`.
    ///
    /// SwiftUI instantiates a view — and its `@State` — more than once per
    /// window, so a view cannot own this identity: two instances would each
    /// bring their own `WindowState` for a single window. The `NSWindow` is
    /// the only thing that is genuinely one-per-window, so the first proposal
    /// for a given one wins and later instances adopt it (`WindowRegistry`).
    func canonicalWindowState(for nsWindow: NSWindow, proposed: WindowState) -> WindowState {
        let (state, isNew) = windowRegistry.adopt(proposed, for: nsWindow)
        if isNew { registerWindow(state) }
        return state
    }

    func forgetWindowState(for nsWindow: NSWindow) {
        guard let state = windowRegistry.forget(nsWindow) else { return }
        unregisterWindow(state)
    }

    /// The `NSWindow` a `WindowState` belongs to, if it has attached.
    func nsWindow(for window: WindowState) -> NSWindow? {
        windowRegistry.nsWindow(for: window)
    }

    /// The window the user is in, as a `WindowState`.
    var keyWindow: WindowState? { windowRegistry.keyWindow }

    /// The window an app-wide action should land in: the key one, else the
    /// first (a dialog or a toggle with no key window still has to go
    /// somewhere — see `dialogWindowID`).
    private var keyOrFirstWindow: WindowState? { windowRegistry.keyOrFirstWindow }

    /// A terminal window's view tree went away. The ONE teardown entry every
    /// per-window table hangs off — the state registry here, the delegate's
    /// window list, the adaptive tint, the sidebar-restore records — so a new
    /// table cannot be added without also being torn down here.
    func windowDidClose(_ nsWindow: NSWindow) {
        WindowAppearance.forgetSidebarWidthRestore(for: nsWindow)
        forgetWindowState(for: nsWindow)
        appDelegate?.forgetTerminalWindow(nsWindow)
    }

    /// Make `window` key — what a click on it does. Goes through AppKit AND
    /// `noteKeyWindow` directly: an inactive app (a CLI caller from another
    /// terminal, the e2e harness) posts no key notification, and the model
    /// has to follow either way.
    func focusWindow(_ window: WindowState) {
        if let nsWindow = nsWindow(for: window) {
            nsWindow.makeKeyAndOrderFront(nil)
        }
        // An accessory app (`macos-hidden`) has neither a Dock tile nor a
        // ⌘-Tab entry, so ordering the window front is only half the request:
        // without activation nothing can be typed into it and there is no way
        // for the user to finish the job by hand.
        MacosHidden.activateForWindowRequest()
        noteKeyWindow(window)
    }

    /// Close a window — the named one, else the focused one. The last visible
    /// window hides instead; see `AppDelegate.closeTerminalWindow`.
    func closeWindow(_ window: WindowState?) {
        guard let appDelegate else { return }
        if let target = (window ?? keyWindow).flatMap({ nsWindow(for: $0) }) {
            appDelegate.closeTerminalWindow(target)
        } else {
            appDelegate.closeFocusedTerminalWindow()
        }
    }

    /// Bring a project on screen for something that happened TO it — a
    /// notification click, a CLI `pane focus` — rather than a selection the
    /// user made in a window.
    ///
    /// Prefers a window already showing the project and fronts that one.
    /// Setting `activeProjectID` alone would repoint the KEY window, tearing
    /// the user's own view away from what it was showing while an identical
    /// view sits one Space over. Only when no window shows the project does
    /// the key window take it.
    func revealProject(_ projectID: UUID) {
        guard let showing = windows.first(where: { $0.activeProjectID == projectID }) else {
            activeProjectID = projectID
            return
        }
        if keyWindowID != showing.id, let nsWindow = nsWindow(for: showing) {
            nsWindow.makeKeyAndOrderFront(nil)
            // See `focusWindow`: an accessory app can't be reached any other way.
            MacosHidden.activateForWindowRequest()
        }
        // Becoming key mirrors the project; do it directly as well, for the
        // common caller that runs while the app is inactive and whose key
        // notification only lands once activation completes.
        noteKeyWindow(showing)
    }

    /// Seed a restored window's tab record from its snapshot entry. The pinned
    /// workspace is skipped: its selection is the workspace's own (restored
    /// via `pinnedActiveTabID`), and a per-window entry for it is read by
    /// nothing and maintained by nothing — see `selectedTab(for:in:)`.
    private func recordRestoredTab(_ tabID: UUID?, in window: WindowState) {
        guard let project = window.activeProjectID, project != PinnedTabs.workspaceID, let tabID else { return }
        window.activeTabIDs[project] = tabID
    }

    func registerWindow(_ window: WindowState) {
        guard !windows.contains(where: { $0.id == window.id }) else { return }
        if window === windowAdoptedBeforeRegistration {
            // `restoreWindows` already gave it entry 0. Never a pending entry,
            // and never the defaults of a new window.
            windowAdoptedBeforeRegistration = nil
        } else if !pendingWindowRestores.isEmpty {
            // Consumed HERE, not at the request: a window registers a beat
            // after it is asked for (its NSWindow has to attach first), which
            // is why the request cannot hand it a payload directly.
            let restoring = pendingWindowRestores.removeFirst()
            if let project = restoring.activeProjectID {
                window.activeProjectID = project
                window.showsProjectScreen = restoring.showsProjectScreen ?? false
                recordRestoredTab(restoring.activeTabID, in: window)
            }
            if let width = restoring.sidebarWidth { window.sidebarWidth = width }
            if let visible = restoring.sidebarVisible { window.sidebarVisible = visible }
            if let visible = restoring.projectMemoryPanelVisible { window.projectMemoryPanelVisible = visible }
            if let expanded = restoring.expandedProjectIDs { window.expandedRows = Set(expanded) }
            if let frame = restoring.frame { window.frame = frame }
        } else if hasRestoredWindows {
            // A window the user opened, not one being restored: the sidebar
            // comes up at the app's defaults — shown, at the default width.
            // `WindowState.init` seeds the width from `Preferences.sidebarWidth`,
            // which is whatever was LAST dragged in any window (a since-closed
            // one included); that suits the first window's launch fallback,
            // not a fresh window.
            window.sidebarWidth = Preferences.defaultSidebarWidth
            window.sidebarVisible = true
        }
        // A new window opens on whatever the user was last looking at, which
        // is both the useful default and what a single-window build did.
        // The project screen too, when the key window shows it.
        if window.activeProjectID == nil {
            window.activeProjectID = activeProjectID
            window.showsProjectScreen = keyWindow.map { $0.activeProjectID == activeProjectID && $0.showsProjectScreen } ?? false
        }
        // Listed before the frame moves: `setFrame` lays the window out at
        // once.
        windowRegistry.append(window)
        // A restored window, or the scene's own window when `restoreWindows`
        // handed it the first saved entry before it attached.
        applyRestoredFrame(of: window)
        settleWindowSelections()
        logger.debug("registerWindow: \(window.id, privacy: .public) count=\(self.windows.count)")
        frontRestoredKeyWindowIfNeeded()
        persistWindows()
    }

    /// Put a restored window at the frame it was saved with. A no-op until
    /// the window has attached (and so always under tests); both callers run
    /// again once it has — `registerWindow` is called at attachment, and
    /// `restoreWindows` for a window that attached first.
    private func applyRestoredFrame(of window: WindowState) {
        guard let frame = window.frame, let nsWindow = nsWindow(for: window) else { return }
        WindowAppearance.restoreFrame(frame, window: nsWindow)
    }

    /// A terminal window moved or resized: record the frame the next launch
    /// reopens it at. Full screen is skipped, so the windowed frame survives
    /// a quit made while full screen (macOS restores no full-screen state
    /// here, and a screen-sized frame is not one the user chose).
    func windowFrameDidChange(_ nsWindow: NSWindow) {
        guard !nsWindow.styleMask.contains(.fullScreen),
              let window = windowRegistry.state(for: nsWindow)
        else { return }
        let frame = nsWindow.frameDescriptor
        guard window.frame != frame else { return }
        window.frame = frame
        persistWindows()
    }

    func unregisterWindow(_ window: WindowState) {
        // Quit closes every window; each teardown used to unregister and
        // save, so the snapshot written by `persistForTermination` was
        // rewritten with one window fewer per close and a relaunch brought
        // back only one. During termination the list is frozen as the record
        // of what was open.
        guard !AppTerminationState.isTerminating else { return }
        windowRegistry.remove(window)
        if keyWindowID == window.id {
            // The user is always "in" some window while one exists. AppKit
            // usually makes another window key and reports it, but not while
            // the app is inactive — a headless harness never sees that report,
            // and every window then read as unfocused with the app-wide
            // mirrors stranded. Promote the first; the next real key event
            // corrects it.
            windowRegistry.setKeyWindowID(windows.first?.id)
            alignKeyWindowTab()
        }
        SurfaceRegistry.shared.releaseSurfaces(ofWindow: window.id)
        settleWindowSelections()
        logger.debug("unregisterWindow: \(window.id, privacy: .public) count=\(self.windows.count)")
        persistWindows()
    }

    /// Which window should present a confirmation dialog.
    ///
    /// The window the user is in, so a busy-close warning appears where they
    /// clicked rather than in every open window — each window's scene carries
    /// its own copy of those alerts, and an ungated binding presents in all of
    /// them (#345). Same failure the `DialogHost.settings` gate already
    /// prevents for the Settings window.
    ///
    /// Falls back to the first window when nothing is key, so a dialog is
    /// never staged with nowhere to appear — silently swallowing a
    /// confirmation would leave the action unfinished with no explanation.
    var dialogWindowID: WindowState.ID? {
        keyWindowID ?? windows.first?.id
    }

    /// Point the app-wide "frontmost project" at this window's.
    ///
    /// Everything that asks `activeProjectID` outside a specific window's view
    /// tree means "the one the user is working in" — the poll cadence, the
    /// remote foreground probe's frontmost-only rule, which project gets its
    /// shells warmed. Mirroring here is what keeps all of them right without
    /// threading a window through each.
    func noteKeyWindow(_ window: WindowState) {
        windowRegistry.setKeyWindowID(window.id)
        // A window can become key before it has a project — it registers from
        // `onAppear`, which runs before the launch task restores the
        // selection. Adopt in that direction rather than pushing nil outward,
        // or becoming key would wipe the restored project.
        if window.activeProjectID == nil {
            window.activeProjectID = activeProjectID
        } else if activeProjectID != window.activeProjectID {
            activeProjectID = window.activeProjectID
        }
        // The tab mirror hands over the same way: the workspace's active tab
        // becomes the one THIS window shows.
        alignKeyWindowTab()
    }

    /// Point a window at a project, and the app with it when that window is
    /// the one the user is in.
    func selectProject(_ projectID: UUID?, in window: WindowState) {
        window.activeProjectID = projectID
        if keyWindowID == window.id {
            activeProjectID = projectID
            alignKeyWindowTab()
        } else {
            settleWindowSelections()
        }
        persistWindows()
    }

    // MARK: - Per-window tab selection (#345)

    /// The tab `window` has selected in `projectID`: its own record when that
    /// tab still exists, else the workspace's active tab. Two windows may
    /// select the same tab: each draws the same panes with a surface of its
    /// own (`SurfaceRegistry.surface(for:in:)`).
    ///
    /// The pinned workspace has no per-window selection: every window on it
    /// shows its active tab. Nothing maintains a map entry for it — the
    /// workspace hook, `settleWindowSelections` and `alignKeyWindowTab` all skip
    /// the sentinel, and `selectTab(_:projectID:in:)` routes it through the
    /// workspace — so a record there could only ever be stale. One was: the
    /// restore paths seeded it from the snapshot, and this then rendered that
    /// tab no matter which pinned tab was active, so Cmd+T on a pinned tab
    /// created a tab the sidebar selected while the window kept showing the
    /// old one.
    ///
    /// A window that shows the project screen of `projectID` selects no tab.
    func selectedTab(for projectID: UUID, in window: WindowState) -> TerminalTab? {
        guard let ws = workspaces[projectID] else { return nil }
        if showsProjectScreen(projectID, in: window, ws: ws) { return nil }
        if ws.kind != .pinned,
           let id = window.activeTabIDs[projectID],
           let tab = ws.tabs.first(where: { $0.id == id })
        {
            return tab
        }
        return ws.activeTab
    }

    /// Whether `window` shows the project screen of `projectID`. Only a
    /// `.project` workspace has one: a flag restored over a pinned or scratch
    /// selection is ignored.
    private func showsProjectScreen(_ projectID: UUID, in window: WindowState, ws: Workspace) -> Bool {
        window.showsProjectScreen && window.activeProjectID == projectID && ws.kind == .project
    }

    /// Show the project screen of `project` in `window` (the key window when
    /// nil), also when the project has tabs: what a click on a project row,
    /// a palette project row and CLI `project select` do. The project's tabs
    /// stay; a selection of one of them shows it.
    func showProjectScreen(_ project: Project, in window: WindowState?) {
        selectProject(project, in: window)
        guard let target = window ?? keyWindow, target.activeProjectID == project.id,
              workspaces[project.id]?.kind == .project, !target.showsProjectScreen
        else { return }
        target.showsProjectScreen = true
        settleWindowSelections()
        persistWindows()
    }

    /// Whether the key window shows the project screen. A command that acts on
    /// the shown tab or pane (`AppCommand.actsOnShownTab`) then does nothing,
    /// as in a project with no tabs: the workspace's active tab is not on
    /// screen.
    var keyWindowShowsProjectScreen: Bool {
        guard let key = keyWindow, let projectID = key.activeProjectID, let ws = workspaces[projectID] else { return false }
        return showsProjectScreen(projectID, in: key, ws: ws)
    }

    /// A tab of the window's project is selected: the window shows it.
    private func endProjectScreen(in window: WindowState) {
        guard window.showsProjectScreen else { return }
        window.showsProjectScreen = false
        persistWindows()
    }

    /// The windows that draw tabs, in creation order: the registered windows,
    /// plus the scene's own window from the moment `restoreWindows` adopts it,
    /// not only once it registers. The launch task can give that window its
    /// project before the window attaches, and it draws its tab in that gap.
    private var renderingWindows: [WindowState] {
        var candidates = windows
        if let adopted = windowAdoptedBeforeRegistration, !candidates.contains(where: { $0.id == adopted.id }) {
            candidates.append(adopted)
        }
        return candidates
    }

    /// Pin every window's tab selection, and let go of the surfaces that no
    /// window draws any more.
    ///
    /// A window with no record of its own for its project falls back to
    /// `ws.activeTab` — the KEY window's tab — so it silently followed the key
    /// window's every tab switch. A window that has landed on a tab keeps it
    /// until it selects another.
    ///
    /// Several windows may draw one pane. Each has its own surface, which is
    /// its own client of the session, so a surface that its window does not
    /// draw any more is a stray client: it is retired here. A pane keeps its
    /// last surface (a warm view), shown or not. Idempotent and cheap: run it
    /// where a window's selection changes.
    private func settleWindowSelections() {
        var shown: [UUID: Set<UUID>] = [:]
        for window in renderingWindows {
            guard let projectID = window.activeProjectID, let ws = workspaces[projectID] else { continue }
            if ws.kind != .pinned {
                let valid = window.activeTabIDs[projectID].map { id in ws.tabs.contains { $0.id == id } } ?? false
                if !valid, let current = ws.activeTabID {
                    window.activeTabIDs[projectID] = current
                }
            }
            for pane in selectedTab(for: projectID, in: window)?.splitRoot.allPanes() ?? [] {
                shown[window.id, default: []].insert(pane.id)
            }
        }
        let registry = SurfaceRegistry.shared
        for pane in allLivePanes() where registry.surfaces(of: pane).count > 1 {
            for surface in registry.surfaces(of: pane) where registry.surfaces(of: pane).count > 1 {
                guard let windowID = surface.windowID else { continue }
                if shown[windowID]?.contains(pane.id) != true { registry.retire(surface) }
            }
        }
    }

    /// Whether a window opened before `window` shows the tab that `window`
    /// shows. Two windows on one tab draw the same panes; this marks the later
    /// one, for `window list`.
    func showsTabOfEarlierWindow(_ window: WindowState) -> Bool {
        guard let projectID = window.activeProjectID,
              let tab = selectedTab(for: projectID, in: window)
        else { return false }
        for other in windows {
            if other.id == window.id { return false }
            if other.activeProjectID == projectID, selectedTab(for: projectID, in: other)?.id == tab.id {
                return true
            }
        }
        return false
    }

    /// Whether `window` draws tabs now. A window that closed can keep its
    /// SwiftUI view alive; it must draw nothing, or each pane would make a
    /// surface and a client of the session for it.
    func windowDraws(_ window: WindowState) -> Bool {
        renderingWindows.contains { $0.id == window.id }
    }

    /// The size `pane` is drawn at in the window the user is working in: the
    /// view in the key window, else a visible one, else any.
    func displayedSize(of pane: Pane) -> CGSize {
        SurfaceRegistry.shared.preferredSurface(of: pane).nsView?.bounds.size ?? .zero
    }

    /// Select a tab in a specific window.
    ///
    /// The key window's selection is the workspace's `activeTabID` (the
    /// workspace hook then records it in the window's own map); any other
    /// window records its choice directly. Selecting a tab another window
    /// shows is fine — this window draws the same panes with surfaces of its
    /// own.
    func selectTab(_ tabID: UUID, projectID: UUID, in window: WindowState) {
        if keyWindowID == window.id || projectID == PinnedTabs.workspaceID {
            selectTab(tabID, projectID: projectID)
            return
        }
        guard let ws = workspaces[projectID], ws.tabs.contains(where: { $0.id == tabID }) else { return }
        if window.activeProjectID == projectID { endProjectScreen(in: window) }
        window.activeTabIDs[projectID] = tabID
        settleWindowSelections()
        persistWindows()
    }

    /// Make the workspace's active tab the one the key window has selected.
    ///
    /// Called whenever the key window or its project changes. The window's
    /// own recorded choice wins when it still exists; a window with no record
    /// adopts the workspace's current tab. Either way the two agree afterwards,
    /// so keyboard actions land in the tab on screen in the key window.
    ///
    /// The settle and the claim run on EVERY key change, also for a key
    /// window on the pinned workspace, which has no selection of its own to
    /// align.
    ///
    /// A key window on the project screen keeps its record too: the
    /// workspace's active tab is then the tab that the screen replaced, which
    /// Recent Tab and the CLI act on. The window draws no tab
    /// (`selectedTab(for:in:)`).
    private func alignKeyWindowTab() {
        if let key = keyWindow, let projectID = key.activeProjectID,
           let ws = workspaces[projectID], ws.kind != .pinned
        {
            if let chosen = key.activeTabIDs[projectID], ws.tabs.contains(where: { $0.id == chosen }) {
                if ws.activeTabID != chosen { ModelWriter.tabPeek(chosen, in: ws) }
            } else if let current = ws.activeTabID {
                key.activeTabIDs[projectID] = current
            }
        }
        settleWindowSelections()
        claimLeadershipForKeyWindow()
    }

    /// Leadership follows the KEY WINDOW's tab, all of it (#345).
    ///
    /// The session decides who leads and says so in its `lead` message
    /// (`PaneSurface.lead`). The app keeps one rule: the key window's surfaces
    /// claim. Bringing a window to the front is the user saying "this is the
    /// view I'm working in", so every session of the tab it shows is claimed
    /// at once. Runs on every key-window and key-tab change, when a surface
    /// gets its first size (a surface with no size refuses the claim), and
    /// when the session tells a client of ours its first `lead` after an
    /// attach, or that it leads (`.terminalSessionLead`). A client from
    /// outside the model that takes leadership by typing keeps it until one
    /// of these.
    func claimLeadershipForKeyWindow() {
        guard let key = keyWindow, let projectID = key.activeProjectID,
              let tab = selectedTab(for: projectID, in: key)
        else { return }
        claimLeadership(forPanesIn: tab, in: key.id)
    }

    /// Claim for each pane's surface of a tab in window `windowID`. Each
    /// surface claims its own session.
    private func claimLeadership(forPanesIn tab: TerminalTab, in windowID: UUID?) {
        let host = Self.host(windowID)
        for pane in tab.splitRoot.allPanes() {
            claimSessionLeadership(SurfaceRegistry.shared.surface(for: pane, in: host))
        }
    }

    /// The workspace hook: its active tab changed by any writer — `createTab`,
    /// `closeTab` picking a neighbour, cycling, the CLI — so the window it is
    /// the mirror of records the change. The key window when it is on the
    /// project; otherwise the first window that is, so a `tab select
    /// --project` for a background project still moves the window showing it.
    private func workspaceActiveTabDidChange(_ ws: Workspace) {
        guard ws.kind != .pinned else { return }
        let onProject = windows.filter { $0.activeProjectID == ws.id }
        guard let target = onProject.first(where: { $0.id == keyWindowID }) ?? onProject.first else { return }
        if let tab = ws.activeTabID {
            target.activeTabIDs[ws.id] = tab
            // A selected tab ends the project screen: it is what shows now.
            endProjectScreen(in: target)
        } else {
            target.activeTabIDs.removeValue(forKey: ws.id)
        }
        settleWindowSelections()
        if target.id == keyWindowID { claimLeadershipForKeyWindow() }
    }

    /// Install the hook on every workspace the dictionary holds. Runs from
    /// `workspaces`'s `didSet`, which fires when a workspace object is added
    /// or replaced — the only moments a new one can appear.
    private func attachWorkspaceHooks() {
        for ws in workspaces.values where ws.onActiveTabChanged == nil {
            ws.onActiveTabChanged = { [weak self, weak ws] in
                guard let self, let ws else { return }
                workspaceActiveTabDidChange(ws)
            }
        }
    }

    /// A window's sidebar width, open sections or Project Insights panel
    /// changed; get it into the snapshot.
    func noteWindowChanged() {
        persistWindows()
    }

    /// Presentation state that belongs to one window but is driven from
    /// app-wide code — hotkeys, palette commands, the CLI. Each is a mirror of
    /// the key window's `WindowState`, the same shape as `activeProjectID`:
    /// views render their own window's copy, and these resolve to the window
    /// the user is in. Before any window exists a write is dropped, which is
    /// fine — there is nothing to show it in.
    var sidebarVisible: Bool {
        get { keyOrFirstWindow?.sidebarVisible ?? true }
        set { keyOrFirstWindow?.sidebarVisible = newValue }
    }

    /// The key window's Project Insights panel (Toggle Project Insights,
    /// the CLI). Each window has its own (`WindowState.projectMemoryPanelVisible`).
    var projectMemoryPanelVisible: Bool {
        get { keyOrFirstWindow?.projectMemoryPanelVisible ?? false }
        set { keyOrFirstWindow?.projectMemoryPanelVisible = newValue }
    }

    /// Whether a window shows the panel for `projectID`. The Git read after
    /// a command runs only then (`ProjectMemory.panelShows`).
    func insightsPanelShows(_ projectID: UUID) -> Bool {
        windows.contains { $0.activeProjectID == projectID && ProjectMemory.showsPanel(in: $0) }
    }

    var isCommandPaletteVisible: Bool {
        get { keyOrFirstWindow?.isCommandPaletteVisible ?? false }
        set { keyOrFirstWindow?.isCommandPaletteVisible = newValue }
    }

    /// Show the palette on `scope` alone (nil: the root), whatever stack of
    /// screens was up. A different screen starts from an empty query — text
    /// typed for one search means nothing to another.
    func openCommandPalette(scope: PaletteScopeID?) {
        guard let window = keyOrFirstWindow else { return }
        if window.paletteScope != scope || window.paletteStack.count > 1 {
            commandPaletteQuery = ""
            window.showPaletteScope(scope)
        }
        window.isCommandPaletteVisible = true
    }

    /// An extension's chord (`PaletteHotkeys`): toggles the palette on its
    /// root like a built-in screen's chord.
    func openCustomPalette(id: String) {
        customPalettes.reloadIfChanged()
        guard let target = customPalettes.rootTarget(id: id) else { return }
        toggleCommandPalette(scope: .custom(target))
    }

    /// A screen's own chord: shows the palette on `scope`, or closes it when
    /// that screen is already up — what ⌘P is to the root.
    func toggleCommandPalette(scope: PaletteScopeID) {
        if isCommandPaletteVisible, keyOrFirstWindow?.paletteScope == scope {
            isCommandPaletteVisible = false
        } else {
            openCommandPalette(scope: scope)
        }
    }

    /// Presents the password editor sheet in the window the user is in.
    func presentPasswordEditor(_ request: PasswordEditorRequest) {
        keyOrFirstWindow?.passwordEditor = request
    }

    /// Presents the "New Remote Project" sheet (#104) — set by the palette
    /// command, the sidebar's New Project menu and Settings → Projects,
    /// consumed by `MainWindow`.
    var isNewRemoteProjectSheetPresented: Bool {
        get { keyOrFirstWindow?.isNewRemoteProjectSheetPresented ?? false }
        set { keyOrFirstWindow?.isNewRemoteProjectSheetPresented = newValue }
    }

    /// Presents the sheet with a host and a folder that the palette parsed
    /// (0358): the sheet checks the folder at once.
    func presentNewRemoteProject(_ draft: NewRemoteProjectDraft) {
        keyOrFirstWindow?.newRemoteProjectDraft = draft
        keyOrFirstWindow?.isNewRemoteProjectSheetPresented = true
    }

    private var windowPersistTask: Task<Void, Never>?

    /// Persist the window list after it changes.
    ///
    /// Opening, closing or repointing a window is not otherwise a workspace
    /// mutation, so nothing else would write it — the list only reached disk
    /// when some unrelated change happened to save. Gated on the launch
    /// restore having run, or the windows registering during startup would
    /// save over the very list they are about to be restored from.
    ///
    /// Debounced, because one caller is a geometry hook that fires on every
    /// frame of a sidebar drag, and another is the `activeProjectID` mirror,
    /// which runs on every project switch — each save is a synchronous JSON
    /// encode and atomic file write on the main thread. Quit does not depend
    /// on this: `persistForTermination` saves synchronously.
    private func persistWindows() {
        guard hasRestoredSelection else { return }
        windowPersistTask?.cancel()
        windowPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveWorkspaces()
        }
    }

    /// The tab model (`ModelState`). Replaced as one unit, the hooks follow.
    var model = ModelState() {
        didSet { attachWorkspaceHooks() }
    }

    var workspaces: [WorkspaceID: Workspace] {
        get { model.workspaces }
        set {
            model.workspaces = newValue
            attachWorkspaceHooks()
        }
    }

    /// Ordered pinned-tab records — the sidebar's pinned section. A record
    /// whose id matches a live tab in the pinned workspace
    /// (`workspaces[PinnedTabs.workspaceID]`) is loaded; the rest are unloaded
    /// (their sessions died) and rebuild from their declaration on selection.
    /// All mutation goes through `AppState+PinnedTabs.swift`.
    var pinnedRecords: [PinnedTabRecord] = []

    /// The shadow stage of design/010 §9 (`ModelShadow`): nil in a build
    /// that does not run it.
    @ObservationIgnored
    var modelShadow: ModelShadow?

    /// `pinned.yaml` I/O. Shares the project-file directory, so a test's
    /// injected `ProjectFileStore` tempdir isolates this file too.
    @ObservationIgnored
    var pinnedLayoutStore: PinnedLayoutStore

    /// The exact text of our own last `pinned.yaml` write — the baseline that
    /// detects external edits at the next write (see
    /// `writePinnedLayout`). nil = never written this run.
    @ObservationIgnored
    var pinnedLayoutLastWrittenText: String?

    /// Membership (record ids, in order) as of the last `pinned.yaml` write,
    /// so `saveWorkspaces` only rewrites the file when the pinned SET changed
    /// — not on every workspace save. nil = no baseline yet, which also stops
    /// a pre-restore save from clobbering the user's file with an empty list.
    @ObservationIgnored
    var pinnedMembershipStamp: [UUID]?

    /// Auto-writes to `pinned.yaml` are paused because the on-disk file is
    /// unparseable (or lost its `path: <pinned>` marker) — overwriting would
    /// destroy the user's mid-edit work. Cleared when a later read parses.
    var pinnedLayoutSuspended = false

    /// Live tab snapshots restored from the workspace file but not yet
    /// materialized: `materializeRestoredPinnedTabs()` first asks zmx which
    /// sessions actually survived, so a dead pinned tab restores from its
    /// declaration (re-running its `run:`) instead of upserting a bare shell.
    @ObservationIgnored
    var pendingPinnedLiveRestores: [UUID: TabSnapshot] = [:]

    /// The pinned tab that was selected at last quit, applied once by
    /// `materializeRestoredPinnedTabs` (the sentinel workspace is excluded
    /// from the ordinary snapshots, which is where every other workspace
    /// keeps its selection).
    @ObservationIgnored
    var pendingPinnedActiveTabID: UUID?

    /// Each pinned pane's last-seen foreground name, so the poll can tell
    /// when a pinned tab started or stopped a process — the trigger that
    /// re-captures its declaration (and rewrites `pinned.yaml`, debounced)
    /// so the respawn recipe tracks what's actually running, not just what
    /// ran at pin time.
    @ObservationIgnored
    var pinnedForegroundStamp: [UUID: String?] = [:]

    /// The debounced declaration-refresh write (see
    /// `notePinnedForegroundChangesIfNeeded`).
    @ObservationIgnored
    var pinnedDeclarationPersistWork: DispatchWorkItem?

    /// Starts a background pane's shell off-screen (the incubator). A seam so
    /// unit tests of the eager pinned-tab launch never create real ghostty
    /// surfaces (and thus never spawn shells) inside the test host.
    @ObservationIgnored
    var incubatePane: (Pane) -> Void = { SurfaceIncubator.shared.warm($0) }
    /// The one dialog awaiting the user — a staged confirmation or a notice.
    /// Set through `present`, cleared through `confirmPendingDialog` /
    /// `dismissPendingDialog` (see `AppState+Dialogs`); presented by the one
    /// `PendingDialogAlert` per scene.
    var pendingDialog: PendingDialog?
    /// The command palette's search text, kept on `AppState` so it survives the
    /// panel's view lifecycle — closing and reopening the palette preserves what
    /// was typed.
    var commandPaletteQuery = ""
    var postPaletteAction: (() -> Void)?
    var renamingTabID: UUID?
    var renamingProjectID: UUID?
    private(set) var hasRestoredSelection = false

    /// Most-recent-first stack of project IDs. Persisted to UserDefaults.
    @ObservationIgnored
    private var projectRecency = RecencyStack<UUID>(limit: 50)
    private let recencyKey = "macterm.projectRecency"

    /// See `LayoutFileService.version`.
    var layoutFilesVersion: Int { layoutFiles.version }

    func noteLayoutFilesChanged() {
        layoutFiles.noteChanged()
    }

    /// The transient confirmation showing in `ToastOverlay`, if any. Only for
    /// outcomes that leave no visible trace — a success, or a keybind that
    /// had nothing to act on (`AppCommand.unavailableNotice`) — failures
    /// still raise a dialog, which a toast must never replace. The one
    /// exception is the updater: a failed update check or download is a toast
    /// (`UpdateToast`), because it asks for no decision.
    private(set) var activeToast: Toast?

    /// Settings → Projects → Install Server on Host…, after the user declined
    /// the server on that host (0057). The consent sheet asks again, on a
    /// terminal window, which comes to the front first: Settings would cover
    /// it. New panes there then get sessions.
    func installRemoteServer(on destination: String) {
        appDelegate?.showWindow()
        Task {
            do {
                try await RemoteHosts.shared.installServer(destination)
                presentToast(
                    String(localized: "Macterm installed its server on \(destination)"),
                    subtitle: String(localized: "Sessions in new panes keep running when the connection stops.")
                )
            } catch {
                presentToast(
                    String(localized: "Macterm cannot install its server on \(destination)"),
                    subtitle: String(describing: error)
                )
            }
        }
    }

    /// Show `toast`, replacing any toast already up (the newest outcome is the
    /// one worth reading).
    func presentToast(_ title: String, subtitle: String? = nil) {
        activeToast = Toast(title: title, subtitle: subtitle)
    }

    /// Dismiss the toast with `id` — a no-op if it was already replaced by a
    /// newer one, so a stale auto-dismiss can't cut the new toast short.
    func dismissToast(_ id: UUID) {
        guard activeToast?.id == id else { return }
        activeToast = nil
    }

    /// The Recent Tab cycle and the switcher's previews (#344).
    let tabCycler = TabCycler()

    var isTabCycling: Bool { tabCycler.isCycling }

    /// The tab IDs the current cycle walks, most-recent-first, and where in
    /// that list the gesture currently sits — what the tab switcher overlay
    /// (#344) renders. Empty when no cycle is in flight.
    var tabCycleTabIDs: [UUID] { tabCycler.order }
    var tabCycleSelection: Int { tabCycler.index }
    var panePreviews: [UUID: PanePreview] { tabCycler.panePreviews }
    var paneContainerAspect: CGFloat? { tabCycler.paneContainerAspect }
    var isLivePreviewing: Bool { tabCycler.isLivePreviewing }

    private let workspaceStore: WorkspaceStore

    /// Whether the snapshot came back unreadable — the store stays private,
    /// but its fail-closed verdict is needed outside this file (the first-run
    /// seed must not mistake an unread snapshot for a fresh install).
    var snapshotLoadFailed: Bool { workspaceStore.loadFailed }

    /// A `.retry` sweep is planned (`scheduleReconnectRetry`).
    @ObservationIgnored
    private var reconnectRetryPlanned = false
    /// See `endV1SessionsOnce`.
    @ObservationIgnored
    var v1SessionsEnded = OnceFlag.preferences
    private var autoTileObserver: Any?

    /// Re-reads each pane's foreground process so tab names track the running
    /// command (`hx`, `btop`, …). This polls like tmux's `automatic-rename`,
    /// rather than relying on terminal title escapes: with shell integration
    /// (Starship/ghostty) the OSC title is prompt/cwd churn, not the command,
    /// and a program may never emit a usable title at all (a layout-spawned or
    /// eager-warmed pane, a process that sets no title). A poll catches every
    /// case — manual launches, layout restores, quits — within one interval,
    /// regardless of titles.
    ///
    /// The cadence is adaptive (`PollCadence`): 250ms only while something is
    /// moving (recent tab switch / keystroke / OSC title / execution
    /// transition, or a running command with the app frontmost), 1s when the
    /// app is active but idle, 2s when inactive with a window still visible,
    /// and fully stopped when nothing is on screen. Each interesting moment
    /// fires `notePollEvent()`, which resumes instantly — so title liveness is
    /// event-bounded, not interval-bounded, and an idle app costs nothing.
    @ObservationIgnored
    private var pollTimer: Timer?
    /// The delay `pollTimer` was scheduled with, so `reschedulePoll` can skip
    /// tearing down and rebuilding an identical timer — `.terminalPollEvent`
    /// fires often under a busy workload (every keystroke, output transition,
    /// OSC title), and each fire recomputed the same cadence and churned a new
    /// `Timer` + RunLoop registration for no behavior change.
    @ObservationIgnored
    private var pollTimerDelay: TimeInterval?

    @ObservationIgnored
    private var pollCadence = PollCadence()

    /// Whether the previous tick saw any `.running` pane; feeds
    /// `PollCadence.Context.isAnyPaneBusy` so a running command holds the
    /// fast cadence while the app is frontmost.
    @ObservationIgnored
    private var lastPollSawBusyPane = false

    @ObservationIgnored
    private var pollEventObservers: [Any] = []

    /// Every block-based observer token paired with the center it was added to,
    /// so `deinit` can remove them from the correct center.
    private let observerTokens = ObserverTokenStore()

    /// Injectable for tests (`PollCadence.Context` inputs). `NSApp` is nil
    /// while the SwiftUI `App` struct (and thus AppState) is constructed —
    /// before `NSApplicationMain` — so both closures must not force-unwrap:
    /// "no app yet" reads as inactive/invisible, which parks the poll until
    /// the first activation/occlusion event fires.
    @ObservationIgnored
    var isAppActive: () -> Bool = { NSApp?.isActive ?? false }

    /// Whether the key window draws a view of the pane now. Only the selected
    /// tab of a window is in the view tree, so a background tab's pane is in
    /// no window. This is a fact of the views, not of the model: when the
    /// terminal window is not key, a tab selection changes only the window's
    /// own choice, and the workspace's `activeTab` can name a tab that is not
    /// on screen.
    @ObservationIgnored
    var paneIsInKeyWindow: (Pane) -> Bool = { SurfaceRegistry.shared.view(of: $0)?.window?.isKeyWindow == true }

    /// The two seams of the Dock badge (`AppState+BellBadge.swift`), injectable
    /// so tests can drive the feature set and read the label without the
    /// developer's real ghostty config or the hosting app's Dock tile. The
    /// default writer is the ONE AppKit write, `BellBadge.apply`.
    @ObservationIgnored
    var bellFeatures: () -> GhosttyApp.BellFeatures = { GhosttyApp.shared.bellFeatures }

    /// Whether a new tab / split starts in the focused pane's cwd rather than
    /// the project directory — the user's `tab-inherit-working-directory` and
    /// `split-inherit-working-directory`, read live so a config reload takes
    /// effect on the next tab. Injectable so tests drive both answers without
    /// a loaded ghostty config.
    @ObservationIgnored
    var newTabInheritsWorkingDirectory: () -> Bool = { GhosttyApp.shared.tabInheritsWorkingDirectory }
    @ObservationIgnored
    var newSplitInheritsWorkingDirectory: () -> Bool = { GhosttyApp.shared.splitInheritsWorkingDirectory }
    /// Settings → General → Opening Text Files, read when a file opens. Injectable
    /// so tests drive both placements without touching shared preferences.
    @ObservationIgnored
    var textFilePlacement: () -> TextFilePlacement = { Preferences.shared.textFilePlacement }

    /// Whether Launch Services opens a clicked file with this app — the one
    /// case a click keeps its line. Injectable for the same reason.
    @ObservationIgnored
    var opensTextFileHere: (URL) -> Bool = { TextFileOpening.isDefaultApp(for: $0) }
    @ObservationIgnored
    var dockBadgeWriter: (String?) -> Void = { BellBadge.apply($0) }
    /// The label last handed to `dockBadgeWriter`, so a sync that changes
    /// nothing costs no AppKit round-trip (the badge is re-derived on every
    /// structural save). Written only by `syncDockBadge`.
    @ObservationIgnored
    var dockBadgeLabel: String?

    /// Any on-screen window counts — including the quick terminal's
    /// non-activating panel. The surface incubator's window is ordered out and
    /// never becomes visible, so it never keeps polling alive.
    @ObservationIgnored
    var isAnyWindowVisible: () -> Bool = {
        (NSApp?.windows ?? []).contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// The session paths of the panes. Injectable so tests can observe
    /// session kills without a real server.
    @ObservationIgnored
    var sessionClient: SessionClient = .live

    /// The quick terminal's split state once this AppState has adopted it
    /// (`adoptQuickTerminal`) — the one whose tab the snapshot carries and
    /// whose sessions the reaper spares. Resolved lazily to the panel's
    /// singleton, or handed in at init by tests so a restore never writes
    /// into the shared one. See `AppState+QuickTerminal.swift`.
    @ObservationIgnored
    var adoptedQuickTerminal: QuickTerminalSplitState?

    /// Terminals on the desktop, in creation order. See
    /// `AppState+DesktopWidgets.swift`.
    var desktopWidgets: [DesktopWidget] = []

    /// The one desktop widget unlocked for editing, if any. In memory only:
    /// every widget launches locked.
    var editingDesktopWidgetID: UUID?

    /// The windows that draw `desktopWidgets`; nil under tests, which assert
    /// on the model alone.
    @ObservationIgnored
    weak var desktopWidgetPresenter: (any DesktopWidgetPresenting)?

    /// The screens widgets may sit on, the primary display (the one with
    /// the menu bar, `NSScreen.screens[0]`) first — where new widgets go and
    /// what `widgets.yaml` means by no `display:`. Injectable so placement
    /// tests don't depend on the machine's displays.
    @ObservationIgnored
    var desktopScreens: () -> [DesktopScreen] = {
        NSScreen.screens.map {
            DesktopScreen(name: $0.localizedName, visibleFrame: $0.visibleFrame, resolution: $0.frame.size)
        }
    }

    /// Where the system's own desktop widgets are, so ours line up with and
    /// never cover them (`NativeDesktopWidgets`). Injectable: tests must not
    /// see the machine's real widgets.
    @ObservationIgnored
    var nativeDesktopWidgetFrames: () -> [CGRect] = { NativeDesktopWidgets.frames() }

    /// `~/.config/macterm/widgets.yaml` (`AppState+DesktopWidgets`).
    @ObservationIgnored
    let widgetLayoutStore: WidgetLayoutStore
    /// The installed extensions and their palettes
    /// (`~/.config/macterm/extensions/`). Macterm reads them again when the
    /// palette opens.
    let customPalettes: CustomPaletteStore
    /// The palettes anyone can install, read from Macterm's repository for
    /// Settings → Extensions (`PaletteRegistry`); here so its hourly cache
    /// outlives the Settings window.
    let paletteRegistry = PaletteRegistry()
    /// Applies the extension updates that need no question. The app starts
    /// it after the launch restore. Tests and benchmarks never do.
    @ObservationIgnored
    private(set) lazy var extensionAutoUpdater = ExtensionAutoUpdater(
        registry: paletteRegistry,
        store: customPalettes
    ) { [weak self] names in
        let title = names.count == 1 ? String(localized: "Extension updated") : String(localized: "Extensions updated")
        self?.presentToast(title, subtitle: names.joined(separator: ", "))
    }

    /// The exact text of our last `widgets.yaml` write — anything else on
    /// disk is an edit to absorb before the next write.
    @ObservationIgnored
    var widgetLayoutLastWrittenText: String?

    /// Auto-writes paused because `widgets.yaml` doesn't parse.
    @ObservationIgnored
    var widgetLayoutSuspended = false

    /// The widgets our last `widgets.yaml` write listed — the only ones an
    /// entry can have been removed FROM. A widget created since that write
    /// is unknown to the file on disk, not removed by the user.
    @ObservationIgnored
    var widgetLayoutLastWrittenIDs: Set<UUID> = []

    /// Widgets whose `widgets.yaml` entry the user removed while Macterm ran:
    /// still alive — a half-saved file must never kill a shell — but left out
    /// of every write, so the next launch removes them as the file says.
    @ObservationIgnored
    var unlistedDesktopWidgetIDs: Set<UUID> = []

    /// Restored widgets not drawn yet: they wait for zmx to say whether their
    /// sessions survived, so a dead one respawns from its recipe instead of
    /// a surface reattaching to an empty shell first.
    @ObservationIgnored
    var pendingDesktopWidgetMaterialize: Set<UUID> = []

    /// Refresh policy for the session listing behind `outdatedSessions`:
    /// refresh on session lifecycle events plus a 30s reconcile TTL — never
    /// per tick.
    @ObservationIgnored
    private var zmxRefreshGate = ZmxRefreshGate()

    /// Drops overlapping session listings so a slow one can't pile up
    /// behind the poll.
    @ObservationIgnored
    private var zmxRefreshInFlight = false

    /// The local sessions that run an older build than the app
    /// (`SessionBuild`), from the last listing. A tab with one shows a
    /// badge, and Restart Session ends them (`AppState+SessionRestart`).
    var outdatedSessions: Set<String> = []

    /// Central project-file store (`~/.config/macterm/projects`). Injectable
    /// so tests never read or write the user's real directory.
    /// The project layout files.
    @ObservationIgnored
    let layoutFiles: LayoutFileService

    /// The retired app-wide panel value, read once at the restore
    /// (`Preferences.takeLegacyProjectMemoryPanelVisible`). Injectable so a
    /// test does not share the preference with tests that run beside it.
    @ObservationIgnored
    private let legacyPanelVisible: () -> Bool
    var projectFiles: ProjectFileStore { layoutFiles.projectFiles }

    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        projectFiles: ProjectFileStore = ProjectFileStore(),
        paletteHotkeys: PaletteHotkeys = .shared,
        quickTerminal: QuickTerminalSplitState? = nil,
        legacyPanelVisible: @escaping () -> Bool = { Preferences.shared.takeLegacyProjectMemoryPanelVisible() }
    ) {
        self.workspaceStore = workspaceStore
        self.legacyPanelVisible = legacyPanelVisible
        layoutFiles = LayoutFileService(projectFiles: projectFiles)
        pinnedLayoutStore = PinnedLayoutStore(directoryURL: projectFiles.configDirectoryURL)
        widgetLayoutStore = WidgetLayoutStore(directoryURL: projectFiles.configDirectoryURL)
        customPalettes = CustomPaletteStore(configDirectoryURL: projectFiles.configDirectoryURL, hotkeys: paletteHotkeys)
        if let quickTerminal { adoptQuickTerminal(quickTerminal) }
        let autoTileToken = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllWorkspacesIfEnabled() }
        }
        autoTileObserver = autoTileToken
        observerTokens.append(center: NotificationCenter.default, token: autoTileToken)
        let restored = (Preferences.defaults.stringArray(forKey: recencyKey) ?? [])
            .compactMap { UUID(uuidString: $0) }
        projectRecency = RecencyStack<UUID>(limit: 50, items: restored)

        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let onEvent: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.notePollEvent() }
        }
        let onQuietSettleDeadline: @Sendable (Notification) -> Void = { [weak self] _ in
            // Do not route through notePollEvent: if another poll ran within
            // 250ms, coalescing plus a fully occluded window would pause with
            // no timer and never retry this deadline.
            MainActor.assumeIsolated { self?.pollNow() }
        }
        let tokens: [(NotificationCenter, NSObjectProtocol)] = [
            (center, center.addObserver(forName: .terminalPollEvent, object: nil, queue: .main, using: onEvent)),
            (center, center.addObserver(forName: .terminalSurfaceSized, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimLeadershipForKeyWindow() }
            }),
            (center, center.addObserver(forName: .terminalSessionLead, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimLeadershipForKeyWindow() }
            }),
            (center, center.addObserver(
                forName: .terminalQuietSettleDeadline,
                object: nil,
                queue: .main,
                using: onQuietSettleDeadline
            )),
            (center, center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Coming to the front is both a poll event and the user
                    // looking at whatever tab is showing (`AppState+BellBadge`).
                    self?.markActiveTabSeenOnActivation()
                    self?.notePollEvent()
                }
            }),
            (center, center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: onEvent
            )),
            (center, center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main, using: onEvent
            )),
            // Wake is on NSWorkspace's own center, not the default one. A
            // timer whose fire date passed during sleep also fires once on
            // wake; `noteEvent` coalescing absorbs the double tick.
            (workspaceCenter, workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onEvent
            )),
            (center, center.addObserver(
                forName: .zmxSessionsChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.zmxRefreshGate.noteSessionLifecycle()
                    self?.notePollEvent()
                }
            }),
            // The Dock badge (`BellBadge`) is derived state: derived again when
            // a pane's attention flags change, and when a config reload may
            // have brought the `attention` feature in or taken it out.
            (center, center.addObserver(
                forName: .paneAttentionDidChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let paneID = note.object as? UUID else { return }
                MainActor.assumeIsolated { self?.paneAttentionDidChange(paneID: paneID) }
            }),
            (center, center.addObserver(forName: .mactermConfigDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncDockBadge() }
            }),
        ]
        pollEventObservers = tokens.map(\.1)
        observerTokens.append(contentsOf: tokens.map { (center: $0.0, token: $0.1) })
        pollNow()
    }

    deinit {
        // Remove every block-based observer from the center each was added to.
        // Production runs one app-lifetime instance, but tests build fresh
        // AppStates — without this, their observers accumulate on the shared
        // centers and dead instances' blocks keep firing into a nil weak self.
        // The poll timer self-cleans: it's non-repeating with a `[weak self]`
        // closure, so a dead instance's timer fires once into nil and stops.
        observerTokens.removeAllObservers()
    }

    // MARK: - Poll scheduling

    /// An instant-resume trigger for the poll (see `PollCadence.noteEvent`).
    func notePollEvent() {
        if pollCadence.noteEvent(at: Date()) {
            pollNow()
        } else {
            // Coalesced — but the mode may still have shortened (idle → fast
            // right after a tick), so re-arm at the new cadence.
            reschedulePoll()
        }
    }

    private func pollNow() {
        // Before the work: the refresh publishes execution-state transitions
        // that fire `notePollEvent`, and the fresh poll timestamp turns those
        // into coalesced no-ops instead of recursive polls.
        pollCadence.notePolled(at: Date())
        refreshOutdatedSessionsIfDue()
        settleAllPanes()
        reschedulePoll()
    }

    /// List the sessions when the gate says so (session lifecycle event, or
    /// the 30s reconcile TTL), and keep the ones of an older build. A failed
    /// listing keeps the last answer: nothing is known.
    private func refreshOutdatedSessionsIfDue() {
        guard !zmxRefreshInFlight, sessionClient.isBundled() else { return }
        guard zmxRefreshGate.shouldRefresh(now: Date()) else { return }
        zmxRefreshInFlight = true
        Task { [weak self, sessionClient] in
            let sessions = await sessionClient.listSessions()
            let outdated = sessions.map { SessionBuild.outdatedNames(in: $0, appKey: ServerBuilds.bundledKey) }
            await MainActor.run {
                self?.zmxRefreshInFlight = false
                if let outdated, self?.outdatedSessions != outdated { self?.outdatedSessions = outdated }
            }
        }
    }

    private func reschedulePoll() {
        let context = PollCadence.Context(
            isAppActive: isAppActive(),
            isAnyWindowVisible: isAnyWindowVisible(),
            isAnyPaneBusy: lastPollSawBusyPane
        )
        guard let delay = pollCadence.nextDelay(at: Date(), context: context) else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerDelay = nil
            return
        }
        // A running timer with the same cadence needs no change — rebuilding it
        // (invalidate + new Timer + RunLoop.add) on every `.terminalPollEvent`
        // is pure churn under a busy workload. Only rebuild when the delay
        // actually changed (or no timer is scheduled). The one-shot timer
        // clears `pollTimer` when it fires, so a nil timer here always rebuilds.
        if let existing = pollTimer, existing.isValid, pollTimerDelay == delay { return }
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        timer.tolerance = delay * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTimerDelay = delay
    }

    /// Settle the quiet runs of every pane, and mark seen what the key window
    /// shows. The foreground needs no poll: each pane's session reports it
    /// (`Pane.applyForeground`).
    func settleAllPanes() {
        var sawBusyPane = false
        for (projectID, ws) in workspaces {
            for tab in ws.tabs {
                for pane in tab.splitRoot.allPanes() {
                    // An activity-sourced run whose output has been quiet past
                    // the window settles to `.done`. The output heartbeat is
                    // occlusion-independent, so silence is meaningful whether or
                    // not the pane is on screen — no occlusion special-casing.
                    pane.settleTerminalActivityIfQuiet()
                    if pane.executionState == .running { sawBusyPane = true }
                    markSeenIfActive(paneID: pane.id, projectID: projectID)
                }
            }
        }
        lastPollSawBusyPane = sawBusyPane
        // A pinned pane's foreground changing (a command started or ended) is
        // the cue to re-capture its tab's declaration, so the respawn recipe
        // tracks what the tab is actually doing — not just what it did at pin
        // time. Cheap in steady state: a name compare per pinned pane.
        notePinnedForegroundChangesIfNeeded()
    }

    private func recordProjectVisit(_ projectID: UUID) {
        projectRecency.push(projectID)
        Preferences.defaults.set(projectRecency.items.map(\.uuidString), forKey: recencyKey)
    }

    /// Recently-visited projects, filtered to only those still present in the store.
    func recentProjects(from projects: [Project], limit: Int = 5) -> [Project] {
        let valid = Set(projects.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return projectRecency.top(limit, in: valid).compactMap { byID[$0] }
    }

    private func rebalanceAllWorkspacesIfEnabled() {
        guard Preferences.shared.autoTilingEnabled else { return }
        for ws in workspaces.values {
            for tab in ws.tabs {
                ModelWriter.splitRebalance(tab)
            }
        }
        saveWorkspaces()
    }

    // MARK: - Restore / Save

    func restoreSelection(projects: [Project]) {
        logger.info("restoreSelection: \(projects.count, privacy: .public) projects")
        hasRestoredSelection = true
        // The scratch workspace restores like a project's (#665): its only
        // record is the snapshot, and its sessions must be claims before the
        // orphan sweep below.
        let valid = Set(projects.map(\.id)).union([ScratchTabs.workspaceID])
        // One pane is one session, across workspaces, pinned tabs, the quick
        // terminal and widgets.
        let loaded = WorkspaceSerializer.withoutRepeatedSessions(workspaceStore.load(), validIDs: valid)
        // Restore every project's snapshot — including layout-file projects.
        // The snapshot carries each pane's persisted zmx session identity, so
        // panes REATTACH their still-running shells; applying the project
        // file's declared layout here would silently destroy them on every
        // launch. A declared layout is only ever applied by an explicit Apply
        // Layout; a project with no snapshot gets the default workspace.
        for ws in WorkspaceSerializer.restore(from: loaded.workspaces, validIDs: valid) {
            workspaces[ws.id] = ws
        }
        // Pinned tabs: records first, then the launch reconcile against
        // `pinned.yaml` (the file is authoritative for membership — see
        // AppState+PinnedTabs). Live tabs materialize async, after zmx says
        // which sessions actually survived.
        // The retired value is read (and removed) only when a window can
        // take it.
        savedWindowSnapshots = loaded.windows.isEmpty
            ? []
            : WindowSnapshot.adoptingLegacyPanelVisibility(loaded.windows, legacyVisible: legacyPanelVisible())
        restorePinnedState(loaded.pinned, activeTabID: loaded.pinnedActiveTabID)
        reconcilePinnedLayoutAtLaunch(projects: projects)
        // The quick terminal's tab reattaches like any workspace tab. Before
        // the orphan sweep below, which spares only what a pane claims.
        restoreQuickTerminal(loaded.quickTerminal)
        // Widgets too: their sessions must be claimed before the sweep, and
        // `widgets.yaml` decides which exist before either.
        let restoredWidgets = restoreDesktopWidgets(loaded.desktopWidgets)
        reconcileWidgetLayoutAtLaunch()
        Task { await materializeRestoredDesktopWidgets(restoredWidgets) }
        if let id = Preferences.shared.activeProjectID {
            if id == PinnedTabs.workspaceID {
                if !pinnedRecords.isEmpty {
                    ensurePinnedWorkspace()
                    activeProjectID = id
                }
            } else if id == ScratchTabs.workspaceID {
                // Only with tabs: an empty scratch workspace has no row in the
                // sidebar, so a launch on it would show an empty detail view
                // with nothing selected.
                if hasScratchTabs {
                    activeProjectID = id
                    markActiveTabSeen(projectID: id)
                    warmFocusedProject()
                }
            } else if let project = projects.first(where: { $0.id == id }) {
                activeProjectID = id
                recordProjectVisit(id)
                ensureWorkspace(projectID: id, path: project.path)
                markActiveTabSeen(projectID: id)
                warmFocusedProject()
            }
        }
        // Pinned live tabs materialize async, after the server says which
        // sessions survived (#285) — ahead of the loadFailed gate, since
        // pinned records come from pinned.yaml, not the snapshot.
        Task { await materializeRestoredPinnedTabs() }
        // A failed snapshot LOAD gives no names: nothing is ended (an empty
        // claim set would mark every live session an orphan).
        guard !workspaceStore.loadFailed else { return }
        endV1SessionsOnce(names: localSessionNames())
        sweepLocalOrphans()
    }

    func saveWorkspaces() {
        // Every structural mutation ends here, so it is also where the
        // windows' surfaces follow the workspace.
        settleWindowSelections()
        // Any mutation can have created a tab inside the pinned workspace
        // (CLI `tab new`, a pane separated into it, a merge) — make sure it
        // has a record before the snapshot serializes.
        syncPinnedRecordsWithWorkspace()
        let ordinary = workspaces.filter { $0.value.kind != .pinned }
        let ordinarySnapshots = WorkspaceSerializer.snapshot(ordinary)
        let pinnedSnapshots = WorkspaceSerializer.snapshotPinned(
            records: pinnedRecords,
            workspace: workspaces[PinnedTabs.workspaceID]
        )
        workspaceStore.save(
            ordinarySnapshots,
            pinned: pinnedSnapshots,
            // The pinned workspace is excluded from `ordinary`, so it loses
            // the WorkspaceSnapshot.activeTabID every other workspace keeps —
            // carry the selection separately or a relaunch always lands on
            // the first pinned row.
            pinnedActiveTabID: workspaces[PinnedTabs.workspaceID]?.activeTabID,
            // Every open window, so a relaunch brings them all back (#345).
            // Empty is never written as an empty list: windows register as
            // their views appear, so a save during launch would otherwise
            // persist "no windows" over a real multi-window setup.
            windows: windows.isEmpty
                ? nil
                : windows.map { window in
                    WindowSnapshot(
                        activeProjectID: window.activeProjectID,
                        sidebarWidth: window.sidebarWidth,
                        isKey: window.id == keyWindowID,
                        // On the project screen: the tab that the screen replaced.
                        activeTabID: window.activeProjectID.flatMap {
                            selectedTab(for: $0, in: window)?.id ?? window.activeTabIDs[$0]
                        },
                        sidebarVisible: window.sidebarVisible,
                        projectMemoryPanelVisible: window.projectMemoryPanelVisible,
                        frame: window.frame,
                        expandedProjectIDs: window.expandedRows.sorted { $0.uuidString < $1.uuidString },
                        showsProjectScreen: window.showsProjectScreen ? true : nil
                    )
                },
            quickTerminal: quickTerminalSnapshot(),
            desktopWidgets: desktopWidgetSnapshots()
        )
        shadowModel(ordinary: ordinarySnapshots, pinned: pinnedSnapshots)
        // A closed or unloaded tab takes its bell out of the count with it.
        syncDockBadge()
    }

    /// Gives `modelShadow` the snapshots that a save wrote, with the pinned
    /// tabs in the order of their workspace.
    private func shadowModel(ordinary: [WorkspaceSnapshot], pinned: [PinnedTabSnapshot]) {
        // `save` refuses to write over a file that did not load: the copy
        // would be as empty as the state.
        guard let modelShadow, !workspaceStore.loadFailed else { return }
        var inputs = ordinary.map { snapshot in
            ModelConversion.WorkspaceInput(
                id: snapshot.projectID,
                kind: WorkspaceKind(id: snapshot.projectID),
                tabs: snapshot.tabs,
                activeTabID: snapshot.activeTabID
            )
        }
        if let pinnedWorkspace = workspaces[PinnedTabs.workspaceID] {
            let live = Dictionary(
                pinned.compactMap { record in record.live.map { (record.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            inputs.append(.init(
                id: pinnedWorkspace.id,
                kind: .pinned,
                tabs: pinnedWorkspace.tabs.compactMap { live[$0.id] },
                activeTabID: pinnedWorkspace.activeTabID
            ))
        }
        // The pinned and the scratch rows are not projects of the model.
        let selected = activeProjectID.flatMap { Project.isSynthetic($0) ? nil : $0 }
        modelShadow.workspacesDidSave(inputs, activeProjectID: selected)
    }

    // MARK: - Project

    /// Select a project in a specific window (#345). Everything after the
    /// selection itself is app-wide — warming shells, sweeping orphans,
    /// reconnecting remote panes — because those follow the project the user
    /// is now in, whichever window that is.
    func selectProject(_ project: Project, in window: WindowState?) {
        // Only the key window moves the app-wide mirror; a selection made in a
        // background window must not repoint polling at it.
        if window == nil || keyWindowID == window?.id {
            // The didSet of `activeProjectID` moves the key window to the
            // project, aligns its tab and settles the windows' surfaces.
            selectProject(project)
        } else {
            window?.activeProjectID = project.id
            recordProjectVisit(project.id)
            ensureWorkspace(projectID: project.id, path: project.path)
            // The window now selects a tab of this project.
            settleWindowSelections()
        }
    }

    func selectProject(_ project: Project) {
        logger.debug("selectProject: \(project.name, privacy: .public)")
        activeProjectID = project.id
        recordProjectVisit(project.id)
        ensureWorkspace(projectID: project.id, path: project.path)
        markActiveTabSeen(projectID: project.id)
        reconnectDroppedRemotePanes(trigger: .projectSelected)
        warmFocusedProject()
        // Creating a workspace doesn't change any tab selection (the poll's
        // usual wake signal), so bump it directly.
        notePollEvent()
    }

    /// Start the shells for every tab of the focused project, not just the
    /// active one — so a multi-tab project (e.g. from a declarative layout) has
    /// all its processes running on open. Other projects stay lazy. The active
    /// tab is created by SwiftUI as usual; the rest are warmed off-screen via
    /// `SurfaceIncubator`.
    func warmFocusedProject() {
        guard let projectID = activeProjectID, let ws = workspaces[projectID] else { return }
        warmStaggered(Self.panesToWarm(in: ws))
    }

    /// Every incubated pane gets the rendered pane's exit classifier, whether
    /// warmed at project selection, pinned restore, or CLI creation. Read its
    /// project at exit time: a tab may have moved since it was warmed.
    private func warmPane(_ pane: Pane) {
        incubatePane(pane)
        SurfaceRegistry.shared.surfaces(of: pane)[0].nsView?.onProcessExit = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.handleProcessExit(pane.id, projectID: pane.projectID)
        }
    }

    /// Start panes' shells off-screen, staggered 125ms apart: each warm is a
    /// login shell (PAM, rc files) and — when restoring — a `zmx attach`
    /// reattaching a daemon, and firing them all in one tick multiplies
    /// launch pressure with pane count (cmux hit a relaunch memory/PAM storm
    /// doing exactly this). The warm is idempotent, so a pane the user views
    /// before its slot just spawns early via SwiftUI and the delayed warm
    /// no-ops. All paths use `warmPane` so never-viewed shells still close
    /// their panes (or unload pinned tabs) when they exit.
    func warmStaggered(_ panes: [Pane]) {
        for (index, pane) in panes.enumerated() {
            if index == 0 {
                warmPane(pane)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.125 * Double(index)) { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.warmPane(pane)
            }
        }
    }

    /// Let SwiftUI start visible children at their actual split size, not the
    /// incubator's oversized grid. An ordered-out owner's SwiftUI tree still
    /// mounts new children (covered by the hidden-window E2E). Zoom is different:
    /// the recursive split view does not mount the hidden child at all.
    func warmIfUnrendered(_ pane: Pane, in tab: TerminalTab) {
        let hiddenByZoom = tab.zoomedPaneID.map { $0 != pane.id } ?? false
        if hiddenByZoom || !isShown(tab, in: pane.projectID) {
            warmPane(pane)
        }
    }

    /// Whether a window draws `tab` now.
    private func isShown(_ tab: TerminalTab, in projectID: UUID) -> Bool {
        renderingWindows.contains {
            $0.activeProjectID == projectID && selectedTab(for: projectID, in: $0)?.id == tab.id
        }
    }

    /// Panes whose shells should be eagerly started: every pane in every tab
    /// except the active tab (SwiftUI starts the active tab's panes when it
    /// renders them). Pure, so it's unit-testable without surfaces.
    static func panesToWarm(in workspace: Workspace) -> [Pane] {
        workspace.tabs
            .filter { $0.id != workspace.activeTabID }
            .flatMap { $0.splitRoot.allPanes() }
    }

    // MARK: - Remote reconnect (#281)

    /// What woke the reconnect sweep. The host's backoff gates every
    /// trigger, except `.hostAnswered`, which clears it.
    enum ReconnectTrigger: String {
        case wake
        case activate
        case projectSelected
        case network
        /// A login brought a host's link back (`.remoteHostDidConnect`).
        case hostConnected
        /// A roaming link heard its host after a gap
        /// (`.remoteHostDidAnswer`). The host's lost panes try now, with no
        /// backoff (`RemoteReconnectPolicy.clear`).
        case hostAnswered
        /// A pane became lost: its link stopped, or a try failed
        /// (`.remoteLinkDidStop`).
        case linkStopped
        /// The next sweep while lost panes remain (`reconnectRetryInterval`).
        case retry
    }

    /// How often the sweep runs again while the active project has a lost
    /// pane and the app is active. Each host's backoff gates its tries.
    static let reconnectRetryInterval: TimeInterval = 5

    /// Let the active project's lost remote panes connect again: panes whose
    /// connection stopped while their session lives on the host. Each host
    /// (`RemoteHost.reconnect`) wakes its lost panes after its backoff, and
    /// the attach replays the session's screen. These tries never ask the
    /// user anything: a login that needs an answer waits for a key in the
    /// pane.
    ///
    /// The triggers (system wake, a network change, app activation, project
    /// selection, a pane that became lost) run a sweep, and while a lost pane
    /// remains, the sweep runs again every `reconnectRetryInterval` while the
    /// app is active. The host's backoff (`RemoteReconnectPolicy`, one for
    /// each host) tries an unreachable host at most once a minute. Active
    /// project only; other projects reconnect via `.projectSelected` when
    /// opened. A key in a lost pane connects at once, with no backoff.
    /// `destination`: only the panes of this host (`.hostConnected`,
    /// `.hostAnswered`). A host that answers again (`.hostAnswered`) clears
    /// its backoff: it is one event for each heal, so it adds no load while
    /// the host is down.
    func reconnectDroppedRemotePanes(trigger: ReconnectTrigger, destination: String? = nil) {
        guard Preferences.shared.reconnectRemotePanes else { return }
        guard !AppTerminationState.isTerminating else { return }
        // A login may ask, and its sheet brings the app to the front. A wake
        // or a network change while the user is in another app waits for the
        // activation, which is a trigger too.
        // A host's own event (a login, a roaming link that hears the host after a gap) is
        // about that host and asks nothing more: it runs at once.
        let runsWhileInactive: Set<ReconnectTrigger> = [.activate, .projectSelected, .hostConnected, .hostAnswered]
        guard runsWhileInactive.contains(trigger) || NSApp.isActive else { return }
        guard let projectID = activeProjectID, let ws = workspaces[projectID] else { return }
        let lost = Self.lostDestinations(ws.tabs.flatMap { $0.splitRoot.allPanes() }, destination: destination)
        guard !lost.isEmpty else { return }
        scheduleReconnectRetry()
        logger.info("reconnect(\(trigger.rawValue, privacy: .public)): \(lost.count, privacy: .public) host(s) with lost panes")
        RemoteHosts.shared.reconnect(lost, answered: trigger == .hostAnswered)
    }

    /// The hosts of the lost panes. `destination`: only this host. Pure.
    static func lostDestinations(_ panes: [Pane], destination: String?) -> Set<String> {
        var destinations: Set<String> = []
        for pane in panes where pane.isDisconnected {
            guard let host = pane.remoteDestination else { continue }
            if let destination, host != destination { continue }
            destinations.insert(host)
        }
        return destinations
    }

    /// One sweep later, unless one is already planned.
    private func scheduleReconnectRetry() {
        guard !reconnectRetryPlanned else { return }
        reconnectRetryPlanned = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectRetryInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.reconnectRetryPlanned = false
                self?.reconnectDroppedRemotePanes(trigger: .retry)
            }
        }
    }

    // MARK: - The v1 sessions

    /// Ends the v1 local zmx sessions that the restored panes name, at the
    /// first v2 launch (design/008 §4, Q3 A). v2 cannot attach to them: each
    /// pane opened a new v2 session of the same name, with a new shell in
    /// its saved folder, so a v1 session left running would be a hidden
    /// shell until a reboot. Only these names: a v1 session that no pane
    /// names is not ours to judge. Remote sessions stay: `localSessionNames`
    /// leaves them out. The flag is set only when every one of them is gone;
    /// otherwise the next launch tries again.
    private func endV1SessionsOnce(names: Set<String>) {
        guard !v1SessionsEnded.read() else { return }
        let flag = v1SessionsEnded
        Task { [sessionClient] in
            guard await sessionClient.endV1Sessions(names.sorted()) else { return }
            await MainActor.run { flag.write() }
        }
    }

    /// Ends the local sessions that no pane claims and no client shows, once
    /// at launch: the leftovers of a crash, or of a close whose kill did not
    /// reach the server (`ZmxReaper.localOrphans`). The claims are read after
    /// the listing, so a pane made in between is never judged against an
    /// older set. A failed listing ends nothing.
    private func sweepLocalOrphans() {
        Task { [sessionClient, weak self] in
            guard let sessions = await sessionClient.listSessions() else { return }
            guard let known = await MainActor.run(body: { self?.claimedSessionNames() }) else { return }
            let orphans = ZmxReaper.localOrphans(in: sessions, known: known)
            guard !orphans.isEmpty else { return }
            logger.info("Ending \(orphans.count, privacy: .public) orphan local session(s)")
            for name in orphans {
                await sessionClient.killSession(name)
            }
        }
    }

    /// The once-flag of `endV1SessionsOnce`: `Preferences.endedV1Sessions`.
    /// Tests hand in their own, so that two tests never share it.
    struct OnceFlag {
        var read: @MainActor () -> Bool
        var write: @MainActor () -> Void

        /// A hermetic run (tests, the benchmark, e2e, the smoke check)
        /// shares the real defaults domain, because cfprefsd ignores `HOME`.
        /// It reads the flag as set and never writes it, so it ends no v1
        /// session and cannot stop the real first launch from ending them.
        static let preferences = OnceFlag(
            read: { PasswordVault.isHermetic || Preferences.shared.endedV1Sessions },
            write: { if !PasswordVault.isHermetic { Preferences.shared.endedV1Sessions = true } }
        )
    }

    // MARK: - Session claims

    /// Every session name a live or restored pane claims, across ALL
    /// workspaces: pinned live snapshots that haven't materialized yet
    /// (#285), the quick terminal's panes (attached only when the panel is
    /// first shown) and desktop widgets' sessions included. The names that
    /// `endV1SessionsOnce` ends in v1's folder.
    private func claimedSessionNames() -> Set<String> {
        Set(allLivePanes().map(\.sessionName))
            .union(pendingPinnedSessionNames())
            .union(quickTerminalSessionNames())
            .union(desktopWidgetSessionNames())
    }

    /// The claimed names of LOCAL sessions: `claimedSessionNames` without the
    /// panes of remote projects. A remote project whose host is this Mac
    /// runs its daemon here too, and `endV1SessionsOnce` must not end it.
    private func localSessionNames() -> Set<String> {
        Set(allLivePanes().filter { !$0.isRemote }.map(\.sessionName))
            .union(pendingPinnedLocalSessionNames())
            .union(quickTerminalSessionNames())
            .union(desktopWidgetSessionNames())
    }

    /// Every pane attached to a session, across ALL workspaces (pinned
    /// included). Workspace panes only: a window's extra surfaces are not
    /// panes.
    private func allLivePanes() -> [Pane] {
        workspaces.values
            .flatMap(\.tabs)
            .flatMap { $0.splitRoot.allPanes() }
    }

    /// The remote pane that shows `session` (`RemoteHosts`, 0057). Its
    /// surfaces are its clients.
    func remotePane(session: String) -> Pane? {
        allLivePanes().first { $0.isRemote && $0.sessionName == session }
    }

    /// Every client of a session that Macterm knows of: the surfaces of the
    /// live panes, a second window's surfaces included. The first surfaces
    /// come first. A count of what the model knows, never of what the session has.
    private func allClients() -> [PaneSurface] {
        let panes = allLivePanes()
        let all = panes.map { SurfaceRegistry.shared.surfaces(of: $0) }
        return all.map { $0[0] } + all.flatMap { $0.dropFirst() }
    }

    /// Kill these panes' sessions, except a session that a pinned record that
    /// waits to load names.
    ///
    /// Callers still destroy the surfaces (`SurfaceRegistry.destroySurfaces`) themselves; this decides only the kill.
    func releaseSessions(_ panes: [Pane]) {
        let retained = pendingPinnedSessionNames()
        for pane in panes where !retained.contains(pane.sessionName) {
            pane.killPersistentSession(using: sessionClient)
        }
    }

    // MARK: - Clients of a session and leadership (#345)

    /// Every client of `sessionName`, first surfaces first.
    func clients(of sessionName: String) -> [PaneSurface] {
        allClients().filter { $0.pane.sessionName == sessionName }
    }

    /// Whether another client of Macterm shows this pane's session.
    func isMirrored(_ pane: Pane) -> Bool {
        clients(of: pane.sessionName).count > 1
    }

    /// Whether another window of Macterm leads `pane`'s session while this
    /// window's surface does not: the pane is in use there, at its size. A
    /// client outside Macterm does not count.
    /// A pane that this window never drew has no surface here, and a check
    /// for the notice must not make one.
    func isLedFromAnotherWindow(_ pane: Pane, window windowID: UUID) -> Bool {
        if let own = SurfaceRegistry.shared.existingSurface(for: pane, in: .window(windowID)), own.isLeader {
            return false
        }
        return clients(of: pane.sessionName).contains {
            $0.windowID != nil && $0.windowID != windowID && $0.isLeader
        }
    }

    /// The surface that stands for a pane where one answer is needed (the CLI):
    /// the one in the window opened first, else the first surface. The same
    /// answer however the key window changes.
    private func referenceSurface(of pane: Pane) -> PaneSurface {
        for window in windows {
            if let surface = SurfaceRegistry.shared.existingSurface(for: pane, in: .window(window.id)) {
                return surface
            }
        }
        return SurfaceRegistry.shared.surfaces(of: pane)[0]
    }

    /// Whether `pane` drives its session's pty size, as its reference surface
    /// does.
    func isLeader(_ pane: Pane) -> Bool {
        referenceSurface(of: pane).isLeader
    }

    /// Every client grouped by session name, from ONE traversal.
    func sessionAttachments() -> [String: [PaneSurface]] {
        var attachments: [String: [PaneSurface]] = [:]
        for surface in allClients() {
            attachments[surface.pane.sessionName, default: []].append(surface)
        }
        return attachments
    }

    /// Ask the session to make `surface` its leader, because the user moved
    /// to it. The session moves leadership by itself only on typed input, so
    /// it would leave the pty sized for the view the user just left.
    ///
    /// **Sent only while the session has not said that this client leads,**
    /// and once until the session answers (`PaneSurface.claimSent`). The
    /// claim is a message on the pane's channel, never input, so it clears
    /// no selection. A surface that has no size yet (an off-screen tab, the
    /// incubator) refuses it; its first size claims again
    /// (`.terminalSurfaceSized`).
    ///
    /// **Synchronous, not debounced.** The session drops a non-leader's mouse
    /// reports and control keys (it forwards a non-leader's input only on
    /// `isUserInput`), and `mouseDown` reports focus BEFORE it forwards the
    /// click, so the claim reaches the session ahead of the click.
    func claimSessionLeadership(_ surface: PaneSurface) {
        guard surface.lead != true, !surface.claimSent else { return }
        // Set first: an answer that comes before `sendClaim` returns clears it.
        surface.claimSent = true
        let delivered = sendClaim(surface)
        if !delivered { surface.claimSent = false }
        logger.debug(
            "claim \(surface.pane.sessionName, privacy: .public) by \(surface.id, privacy: .public) delivered=\(delivered, privacy: .public)"
        )
    }

    /// `claimSessionLeadership` for the callers with no window in hand.
    func claimSessionLeadership(_ pane: Pane) {
        claimSessionLeadership(SurfaceRegistry.shared.preferredSurface(of: pane))
    }

    /// Sends the leadership claim on the surface's channel, reporting whether
    /// it could. A seam so tests observe claims without a live surface.
    @ObservationIgnored
    var sendClaim: (PaneSurface) -> Bool = { $0.nsView?.sendLeadershipClaim() ?? false }

    /// The host of a window id, for the callers that pass nil for the
    /// surface that no window draws.
    static func host(_ windowID: UUID?) -> SurfaceHost {
        windowID.map(SurfaceHost.window) ?? .incubator
    }

    /// The panes of `tab` whose surface in window `windowID` is not driving
    /// its session's size, by the session's `lead`: the ones the UI blurs in
    /// that window. Without a window it reads each pane's first surface.
    func nonLeaderPaneIDs(in tab: TerminalTab, window windowID: UUID? = nil) -> Set<UUID> {
        let host = Self.host(windowID)
        return Set(tab.splitRoot.allPanes().filter { !SurfaceRegistry.shared.surface(for: $0, in: host).isLeader }.map(\.id))
    }

    /// Whether closing `closing` is worth stopping the user over: a pane
    /// that closes kills its session and whatever runs in it. It uses the
    /// retention rule of `releaseSessions`, so the warning and the kill
    /// agree.
    ///
    /// This is the ONE busy-close predicate. Every path that ends sessions —
    /// pane close, tab close, project remove, the sidebar's bulk
    /// remove, the CLI's `busy` refusal and the Close Tab intent — asks one
    /// of the overloads below. The raw `allPanes().contains(where:
    /// \.needsConfirmClose)` ignores the retention, so it would warn about a
    /// kill that the close does not do.
    func closeNeedsConfirmation(_ closing: [Pane]) -> Bool {
        let retained = pendingPinnedSessionNames()
        return closing.contains { paneNeedsConfirmClose($0) && !retained.contains($0.sessionName) }
    }

    /// Whether closing (or, for a pinned tab, unloading) `tab` needs
    /// confirmation. Closing a tab ends every session its panes hold alone.
    func closeNeedsConfirmation(tab: TerminalTab) -> Bool {
        closeNeedsConfirmation(tab.splitRoot.allPanes())
    }

    /// Whether removing the whole of project `projectID` needs
    /// confirmation. Unknown or empty projects need none.
    func closeNeedsConfirmation(projectID: UUID) -> Bool {
        closeNeedsConfirmation(panes(inProject: projectID))
    }

    /// Every pane of the given projects (removed whole) and tabs.
    func closeNeedsConfirmation(projectIDs: [UUID], tabs: [(tabID: UUID, projectID: UUID)]) -> Bool {
        var closing = projectIDs.flatMap(panes(inProject:))
        for tab in tabs {
            guard let tab = workspaces[tab.projectID]?.tabs.first(where: { $0.id == tab.tabID }) else { continue }
            closing += tab.splitRoot.allPanes()
        }
        return closeNeedsConfirmation(closing)
    }

    private func panes(inProject projectID: UUID) -> [Pane] {
        workspaces[projectID]?.tabs.flatMap { $0.splitRoot.allPanes() } ?? []
    }

    /// The per-pane half of the verdict — `Pane.needsConfirmClose` in
    /// production. A seam because that property short-circuits on
    /// `hasSurface`, and no pane in a windowless test ever builds one, so
    /// without it the tab- and project-level guards could only be tested
    /// against an always-idle pane.
    @ObservationIgnored
    var paneNeedsConfirmClose: (Pane) -> Bool = { $0.needsConfirmClose }

    /// Shows an open panel, adds or finds the selected directory as a project,
    /// and selects it. Returns the selected project, nil if cancelled. With
    /// `parent` (New Project Inside), the panel starts in the folder of
    /// `parent` when it is a local folder, and the new project goes at the
    /// end of the projects inside `parent`.
    @discardableResult
    func openProject(store: ProjectStore, inside parent: Project? = nil) -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a project folder")
        if let parent, parent.hasFolder, !parent.isRemote {
            panel.directoryURL = URL(filePath: parent.path, directoryHint: .isDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Always create: picking a folder that already backs a project makes a
        // second, independent project for it, not a jump to the existing one.
        let project = store.create(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            parent: parent?.id
        )
        selectProject(project)
        return project
    }

    /// A project per directory, in order, with the last one selected in
    /// `window` (the key window's selection when nil) — what the Finder
    /// service, Open With and a folder dropped on the sidebar all do. Always
    /// creates, like the folder picker: a directory is not an identity, and a
    /// second project on the same folder is a legitimate ask.
    @discardableResult
    func openProjects(atPaths paths: [String], store: ProjectStore, in window: WindowState? = nil) -> Project? {
        var selected: Project?
        for path in paths {
            selected = store.create(name: (path as NSString).lastPathComponent, path: path)
        }
        if let selected { selectProject(selected, in: window) }
        return selected
    }

    /// Rename a project from its sidebar row (the inline edit, which Rename
    /// Current Project opens too). A name the pinned workspace reserves is
    /// refused with a notice and the old name stays — as `project rename`
    /// refuses it with a `bad_request`. The field has closed by the time the
    /// name arrives, so the notice is the one place left to say why.
    func renameProject(_ projectID: UUID, to name: String, store: ProjectStore) {
        if let message = Project.reservedNameMessage(for: name) {
            present(.notice(
                .reservedProjectName,
                title: String(localized: "Cannot rename project"),
                message: message,
                host: .mainWindow
            ))
            return
        }
        store.rename(id: projectID, to: name)
    }

    /// Update the active project's path to wherever the focused pane currently
    /// sits (via OSC 7 — `SurfaceRegistry.shared.view(of: pane).currentPwd`). Useful when a project
    /// started in one directory but the user has settled into a subdirectory
    /// and wants new tabs / persisted state to start there.
    ///
    /// No-op when there's no active project or no resolvable pwd. We don't
    /// touch open panes or workspaces. They keep their current cwd. Future tabs
    /// use the new directory when "New tab directory" is set to Project.
    func replaceProjectPathWithCurrentDir(projectStore: ProjectStore) {
        guard let projectID = activeProjectID,
              let project = projectStore.projects.first(where: { $0.id == projectID }),
              // Remote projects (#104): the reported pwd is a REMOTE
              // directory — adopting it would corrupt the project's identity.
              !project.isRemote,
              let pane = focusedPane(for: projectID),
              let pwd = SurfaceRegistry.shared.view(of: pane)?.currentPwd,
              !pwd.isEmpty
        else { return }
        projectStore.setPath(id: projectID, to: pwd)
    }

    /// Point every window showing `projectID` at nothing.
    ///
    /// Removal tears the project's shells down. A window left showing it
    /// would render a workspace that no longer exists, or respawn shells
    /// through its live `TerminalSurface`. The key window
    /// follows through the `activeProjectID` mirror like any other.
    private func vacateWindows(showing projectID: UUID) {
        for window in windows where window.activeProjectID == projectID {
            window.activeProjectID = nil
        }
        if activeProjectID == projectID { activeProjectID = nil }
        settleWindowSelections()
    }

    /// The teardown half of `removeProject`, without the workspace save — so
    /// a bulk removal can persist once for the whole batch instead of
    /// re-serializing the snapshot per item.
    private func removeProjectWithoutSaving(_ projectID: UUID) {
        // Unreachable through the UI (a sentinel is not a Project) — hard
        // guard so no future caller can tear the pinned or the scratch
        // workspace down.
        guard !Project.isSynthetic(projectID) else { return }
        logger.debug("removeProject: \(projectID, privacy: .public)")
        if let ws = workspaces[projectID] {
            // Project removed for good → its sessions die with it.
            let removing = ws.tabs.flatMap { $0.splitRoot.allPanes() }
            releaseSessions(removing)
            for pane in removing {
                SurfaceRegistry.shared.destroySurfaces(of: pane)
            }
        }
        workspaces.removeValue(forKey: projectID)
        for window in windows {
            window.expandedRows.remove(projectID)
        }
        vacateWindows(showing: projectID)
        // Every removal path comes through here, so a removed project's
        // memory never outlives it.
        if ProjectMemory.isSupported { ProjectMemory.shared.forget(projectID) }
    }

    func removeProject(_ projectID: UUID) {
        removeProjectWithoutSaving(projectID)
        saveWorkspaces()
    }

    /// Remove several projects' workspaces at once — the bulk sidebar delete.
    /// The caller is responsible for pruning the matching `ProjectStore`
    /// entries (that store lives outside AppState). Saves once for the batch.
    func removeProjects(_ projectIDs: [UUID]) {
        guard !projectIDs.isEmpty else { return }
        for id in projectIDs {
            removeProjectWithoutSaving(id)
        }
        saveWorkspaces()
    }

    /// Remove the project `projectID` (design 013 §3). With no projects
    /// inside, it goes at once, or after one question when a process runs
    /// in it. With projects inside, one dialog always asks: Remove All, or
    /// Keep Inside Projects. Each choice reads the tree again at the answer.
    func requestRemoveProject(_ projectID: UUID, store: ProjectStore, host: DialogHost = .mainWindow) {
        guard let project = store.row(projectID) else { return }
        let inside = store.descendants(of: projectID).map(\.id)
        guard !inside.isEmpty else {
            let removal: @MainActor () -> Void = { [weak self] in
                self?.removeProject(projectID, keepingInside: true, store: store)
            }
            guard closeNeedsConfirmation(projectID: projectID) else {
                removal()
                return
            }
            present(PendingDialog(
                kind: .removeProject(projectID),
                title: String(localized: "Remove project with running processes?"),
                message: String(localized: "A process is still running in this project. Removing it ends every process in its tabs."),
                confirmTitle: String(localized: "Remove"),
                host: host,
                onConfirm: removal
            ))
            return
        }
        let count = inside.count
        let message = closeNeedsConfirmation(projectIDs: [projectID] + inside, tabs: [])
            ? String(localized: """
            This project contains \(count) projects, and a process is still running. Remove All also removes \
            them. Keep Inside Projects moves them to the place of this project.
            """)
            : String(localized: """
            This project contains \(count) projects. Remove All also removes them. Keep Inside Projects moves \
            them to the place of this project.
            """)
        present(PendingDialog(
            kind: .removeProject(projectID),
            title: String(localized: "Remove the project “\(project.name)”?"),
            message: message,
            confirmTitle: String(localized: "Remove All"),
            host: host,
            onConfirm: { [weak self] in self?.removeProject(projectID, keepingInside: false, store: store) },
            alternative: PendingDialog.Alternative(
                title: String(localized: "Keep Inside Projects"),
                action: { [weak self] in self?.removeProject(projectID, keepingInside: true, store: store) }
            )
        ))
    }

    /// Remove the project `projectID`: its workspace, its sessions and its
    /// row. With `keepingInside`, the projects inside it move to its place
    /// in its parent; without it, they are removed too.
    func removeProject(_ projectID: UUID, keepingInside: Bool, store: ProjectStore) {
        let removed = keepingInside ? [projectID] : [projectID] + store.descendants(of: projectID).map(\.id)
        removeProjects(removed)
        if keepingInside {
            store.removeKeepingChildren(projectID)
        } else {
            store.removeWithDescendants(projectID)
        }
    }

    /// A bulk sidebar delete (multi-selection): run `removal` now, or stage
    /// it when one or more affected panes has a running foreground program —
    /// a single dialog for the whole selection instead of one per item.
    /// Run `removal` (the caller's full bulk close/remove) immediately when no
    /// affected pane is busy; otherwise stage it behind one confirmation alert.
    /// Mirrors `requestRemoveProject`/`requestCloseTab`, but for a whole
    /// multi-selection so the user confirms once rather than per item.
    func requestRemoveSelection(
        projectIDs: [UUID],
        tabs: [(tabID: UUID, projectID: UUID)],
        removal: @escaping @MainActor () -> Void
    ) {
        guard closeNeedsConfirmation(projectIDs: projectIDs, tabs: tabs) else {
            removal()
            return
        }
        present(PendingDialog(
            kind: .removeSelection,
            title: String(localized: "Remove items with running processes?"),
            message: String(localized: """
            A process is still running in one of the selected items. \
            Removing them ends every process in their tabs.
            """),
            confirmTitle: String(localized: "Remove"),
            host: .mainWindow,
            onConfirm: removal
        ))
    }

    // MARK: - Tabs

    /// A `command` starts in the new tab's pane (`PaneStartCommand`).
    /// Returns the new tab's ID, nil when the project has no live workspace.
    /// `focus: false` preserves any existing selection and history, and warms
    /// unrendered panes so their shells start without a visit.
    @discardableResult
    func createTab(
        projectID: UUID,
        projectPath: String,
        sessionSlug: String? = nil,
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let ws = workspaces[projectID] else { return nil }
        let tab = ModelWriter.tabCreate(
            in: ws,
            projectPath: projectPath, sessionSlug: sessionSlug,
            command: command, env: env, focus: focus
        )
        if !focus {
            for pane in tab.splitRoot.allPanes() {
                warmIfUnrendered(pane, in: tab)
            }
        }
        logger.debug("createTab: project=\(projectID, privacy: .public) tabs=\(ws.tabs.count, privacy: .public)")
        saveWorkspaces()
        return tab.id
    }

    /// Creates a tab in the directory `tab-inherit-working-directory` selects.
    /// Active pane falls back to the project path when no local cwd is available.
    /// The pinned workspace falls back to home.
    @discardableResult
    func createTab(
        projectID: UUID,
        projects: [Project],
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects) else {
            return nil
        }
        let activePaneDirectory = focusedPane(for: projectID)?.liveLocalWorkingDirectory()
        // A brand-new tab has no source pane to inherit from, so an
        // unusable active-pane cwd (nil) lands in the project directory.
        let newTabDirectory = NewTerminalWorkingDirectory(inherits: newTabInheritsWorkingDirectory()).resolveNewTerminalDirectory(
            projectDirectory: projectDirectory,
            activePaneDirectory: activePaneDirectory
        ) ?? projectDirectory
        return createTab(
            projectID: projectID,
            projects: projects,
            workingDirectory: newTabDirectory,
            command: command,
            env: env,
            focus: focus
        )
    }

    /// Creates a tab in an explicit `workingDirectory` — one of the project's
    /// git worktrees, from the sidebar's Worktrees menu.
    @discardableResult
    func createTab(
        projectID: UUID,
        projects: [Project],
        workingDirectory: String,
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects) else {
            return nil
        }
        // The cwd is user-selectable, but zmx session grouping remains project-scoped.
        let projectSessionSlug = (projectDirectory as NSString).lastPathComponent
        return createTab(
            projectID: projectID,
            projectPath: workingDirectory,
            sessionSlug: projectSessionSlug,
            command: command,
            env: env,
            focus: focus
        )
    }

    /// Returns the configured project root. A sentinel workspace (pinned,
    /// scratch) has none, and its synthetic project names home.
    func configuredProjectDirectory(projectID: UUID, projects: [Project]) -> String? {
        if let synthetic = Project.synthetic(for: projectID) { return synthetic.path }
        return projects.first(where: { $0.id == projectID })?.path
    }

    /// The teardown half of `closeTab`, without the workspace save — so a
    /// bulk close can persist once for the whole batch.
    private func closeTabWithoutSaving(_ tabID: UUID, projectID: UUID) {
        // Closing a PINNED tab is an unload, not a removal: sessions end, the
        // record (and its pinned.yaml entry) stays as a dimmed row, and the
        // next launch eager-starts it again. Unpin is the removal path.
        if projectID == PinnedTabs.workspaceID {
            unloadPinnedTab(tabID)
            return
        }
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        logger.debug("closeTab: \(tabID, privacy: .public) project=\(projectID, privacy: .public)")
        // Tab closed for good → its panes' zmx sessions die with it.
        let closing = tab.splitRoot.allPanes()
        releaseSessions(closing)
        for pane in closing {
            SurfaceRegistry.shared.destroySurfaces(of: pane)
        }
        ModelWriter.tabClose(tabID, in: ws)
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        closeTabWithoutSaving(tabID, projectID: projectID)
        saveWorkspaces()
    }

    /// Close several tabs at once — the bulk sidebar delete for tabs. Each is
    /// identified by its owning project since a multi-selection can span
    /// projects. Saves once for the batch.
    func closeTabs(_ tabs: [(tabID: UUID, projectID: UUID)]) {
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            closeTabWithoutSaving(tab.tabID, projectID: tab.projectID)
        }
        saveWorkspaces()
    }

    /// Close a tab, confirming first when any of its panes has a running
    /// foreground program — closing kills the panes' zmx sessions, so the
    /// destructive-confirmation lives here (quit will detach, not kill).
    func requestCloseTab(_ tabID: UUID, projectID: UUID) {
        let tab = workspaces[projectID]?.tabs.first { $0.id == tabID }
        guard let tab, closeNeedsConfirmation(tab: tab) else {
            closeTab(tabID, projectID: projectID)
            return
        }
        present(PendingDialog(
            kind: .closeTab(tabID: tabID, projectID: projectID),
            title: String(localized: "Close running processes?"),
            message: String(localized: "A process is still running in this tab. Closing the tab ends it."),
            confirmTitle: String(localized: "Close"),
            host: .mainWindow
        ) { [weak self] in self?.closeTab(tabID, projectID: projectID) })
    }

    func selectTab(_ tabID: UUID, projectID: UUID) {
        // The single selection seam: a pinned row may be UNLOADED (no live
        // tab), so pinned selection routes through the record-aware path —
        // every caller (sidebar, toolbar switcher, CLI) gets it for free.
        if projectID == PinnedTabs.workspaceID {
            selectPinnedTab(tabID)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        ModelWriter.tabSelect(tabID, in: ws)
        if ws.activeTabID != before {
            saveWorkspaces()
        } else if ws.tabs.contains(where: { $0.id == tabID }) {
            // The tab that a project screen replaced: no change for the hook
            // to see, so end the screen of the window that the hook targets.
            let onProject = windows.filter { $0.activeProjectID == projectID }
            if let target = onProject.first(where: { $0.id == keyWindowID }) ?? onProject.first {
                endProjectScreen(in: target)
            }
        }
    }

    /// Move a tab — with its live panes and running shells intact — from one
    /// project's workspace into another's. The `TerminalTab` object is reused
    /// as-is, so its surfaces stay valid (both workspaces live in the same
    /// window). The destination becomes the active project with the moved tab
    /// selected, so the user lands where they meant to be. `toIndex` positions
    /// the tab within the destination (a sidebar drop lands at a slot); nil
    /// appends. No-op for a same-project move or an unknown source/tab.
    func moveTab(
        _ tabID: UUID,
        from sourceProjectID: UUID,
        to destProjectID: UUID,
        destPath: String,
        toIndex: Int? = nil
    ) {
        guard sourceProjectID != destProjectID else { return }
        // A move INTO the pinned workspace is a pin — route through `pinTab`
        // so the declaration is captured and the record inserted. This keeps
        // every drag/menu path a plain `moveTab` call.
        if destProjectID == PinnedTabs.workspaceID {
            pinTab(tabID, fromProject: sourceProjectID, toRecordIndex: toIndex)
            return
        }
        // An UNLOADED pinned record has no live tab for the guard below to
        // find; dragging its dimmed row into a project is still an unpin —
        // the drop names where it should spawn. Checked BEFORE the live-tab
        // guard, which would otherwise bail first.
        if sourceProjectID == PinnedTabs.workspaceID,
           workspaces[sourceProjectID]?.tabs.contains(where: { $0.id == tabID }) != true,
           let record = pinnedRecord(tabID)
        {
            unpinUnloadedRecord(record, toProject: destProjectID, toIndex: toIndex)
            return
        }
        guard let source = workspaces[sourceProjectID],
              let tab = source.tabs.first(where: { $0.id == tabID })
        else { return }
        logger.debug(
            "moveTab: \(tabID, privacy: .public) from=\(sourceProjectID, privacy: .public) to=\(destProjectID, privacy: .public)"
        )
        ensureWorkspace(projectID: destProjectID, path: destPath)
        guard let dest = workspaces[destProjectID] else { return }
        ModelWriter.tabClose(tabID, in: source)
        ModelWriter.tabInsert(tab, into: dest, at: toIndex)
        // Restamp the moved panes' routing identity to the destination project.
        // Without this they keep the SOURCE projectID, so a later
        // notification-click navigates to the old project and can't find the
        // tab. Only the routing key changes — session identity (name/host)
        // stays put, so a moved remote pane still tears down over ssh.
        for pane in tab.splitRoot.allPanes() {
            pane.rebind(projectID: destProjectID)
        }
        // A move OUT of the pinned workspace is the unpin: the record (and
        // its `pinned.yaml` entry) goes with it.
        if sourceProjectID == PinnedTabs.workspaceID {
            removePinnedRecord(forTab: tabID)
        }
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Merge a tab into the destination project's ACTIVE tab at a resolved
    /// workspace drop target (#227 — dragging a sidebar tab into the
    /// workspace, where the cursor picks a level: whole-edge, divider, or
    /// local pane split). No-op when the active tab IS the dragged tab.
    func mergeTab(
        _ tabID: UUID,
        from sourceProjectID: UUID,
        at target: TabDropResolution.Target,
        inProject destProjectID: UUID
    ) {
        guard let destTab = workspaces[destProjectID]?.activeTab,
              destTab.id != tabID,
              let sourceTab = detachTabForMerge(tabID, from: sourceProjectID, to: destProjectID)
        else { return }
        guard ModelWriter.tabMerge(destTab, tree: sourceTab.splitRoot, at: target) else {
            // The target pane vanished mid-drag: put the detached tab back
            // (identity restored) instead of losing its live shells.
            if sourceProjectID != destProjectID {
                for pane in sourceTab.splitRoot.allPanes() {
                    pane.rebind(projectID: sourceProjectID)
                }
            }
            if let source = workspaces[sourceProjectID] { ModelWriter.tabInsert(sourceTab, into: source) }
            saveWorkspaces()
            return
        }
        finishMerge(intoTab: destTab.id, inProject: destProjectID)
    }

    /// Pull a tab out of its workspace for a merge, keeping its panes (and
    /// their surfaces) alive, and restamp their routing identity when the merge
    /// crosses projects — the same rebind `moveTab` does, for the same reason.
    private func detachTabForMerge(_ tabID: UUID, from sourceProjectID: UUID, to destProjectID: UUID) -> TerminalTab? {
        guard let source = workspaces[sourceProjectID],
              let tab = source.tabs.first(where: { $0.id == tabID })
        else { return nil }
        ModelWriter.tabClose(tabID, in: source)
        if sourceProjectID != destProjectID {
            for pane in tab.splitRoot.allPanes() {
                pane.rebind(projectID: destProjectID)
            }
            // Merging a pinned tab's tree into another project's tab unpins
            // it — the tab object dissolves into the destination.
            if sourceProjectID == PinnedTabs.workspaceID {
                removePinnedRecord(forTab: tabID)
            }
        }
        return tab
    }

    /// Land the user on the merged tab, mirroring `moveTab`'s selection.
    private func finishMerge(intoTab destTabID: UUID, inProject destProjectID: UUID) {
        if let dest = workspaces[destProjectID] { ModelWriter.tabSelect(destTabID, in: dest) }
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Split a tab apart (#227 — "Separate Panes"): every pane after the first
    /// (in tree order) moves into its own fresh tab inserted right after the
    /// source tab, and the source keeps only its first pane. The `Pane`
    /// objects are reused as-is, so surfaces and running shells survive.
    /// No-op for a single-pane tab.
    func separateTabPanes(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID }),
              tab.splitRoot.allPanes().count > 1
        else { return }
        logger.debug("separateTabPanes: \(tabID, privacy: .public) panes=\(tab.splitRoot.allPanes().count, privacy: .public)")
        ModelWriter.paneSeparateAll(tab, in: ws)
        saveWorkspaces()
    }

    /// Split a single pane out of its tab into its own fresh tab — the
    /// per-pane sibling of `separateTabPanes` ("Separate Current Pane"). The
    /// `Pane` object is reused as-is, so its surface and running shell
    /// survive; the source tab keeps its remaining panes. `index` is the
    /// slot in the destination project's tab list (nil appends). Crossing
    /// projects rebinds the pane's routing identity, mirroring `moveTab`.
    /// No-op when the pane isn't in any workspace or is its tab's only pane
    /// (already its own tab).
    func separatePane(_ paneID: UUID, toProject destProjectID: UUID, destPath: String, at index: Int? = nil) {
        guard let (sourceProjectID, sourceTab) = locatePane(paneID),
              sourceTab.splitRoot.allPanes().count > 1,
              let pane = sourceTab.splitRoot.findPane(id: paneID)
        else { return }
        // Resolve the destination before detaching, so a failure can't leave
        // the pane belonging to no tab.
        ensureWorkspace(projectID: destProjectID, path: destPath)
        guard let dest = workspaces[destProjectID],
              ModelWriter.paneDetach(sourceTab, paneID: paneID) != nil
        else { return }
        logger.debug(
            "separatePane: \(paneID, privacy: .public) to=\(destProjectID, privacy: .public) index=\(index ?? -1, privacy: .public)"
        )

        if sourceProjectID != destProjectID {
            pane.rebind(projectID: destProjectID)
        }
        let newTab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        ModelWriter.tabInsert(newTab, into: dest, at: index)
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Find the workspace tab currently holding a pane. Scans every loaded
    /// workspace — a sidebar pane drop only carries the pane's id, and the
    /// quick terminal's tab (not in `workspaces`) correctly misses.
    private func locatePane(_ paneID: UUID) -> (projectID: UUID, tab: TerminalTab)? {
        for (projectID, ws) in workspaces {
            if let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
                return (projectID, tab)
            }
        }
        return nil
    }

    /// Reorder a tab within its own project to an absolute drop index (the
    /// offset a sidebar drag-and-drop reports). Persists on a real move.
    func reorderTab(_ tabID: UUID, inProject projectID: UUID, toIndex destination: Int) {
        // A pinned reorder must move the RECORD (the sidebar rows and
        // pinned.yaml follow records, not the live-tab array) — the offset
        // arrives in live-tab space here, so translate it.
        if projectID == PinnedTabs.workspaceID {
            reorderPinnedLiveTab(tabID, toLiveIndex: destination)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.tabs.map(\.id)
        ModelWriter.tabReorder(tabID, in: ws, toIndex: destination)
        if ws.tabs.map(\.id) != before { saveWorkspaces() }
    }

    /// Where Move Tab Up (`step` -1) or Move Tab Down (`step` 1) would put
    /// the active tab, as a drop offset for `reorderTab`, or nil when it is
    /// already at that end. The pinned workspace steps through its RECORDS —
    /// the sidebar rows, unloaded ones included — so one keystroke moves the
    /// tab past exactly one row.
    func activeTabMoveOffset(step: Int, projectID: UUID) -> Int? {
        guard let ws = workspaces[projectID], let tabID = ws.activeTabID else { return nil }
        let ids = ws.kind == .pinned ? pinnedRecords.map(\.id) : ws.tabs.map(\.id)
        guard let from = ids.firstIndex(of: tabID) else { return nil }
        let to = from + step
        guard ids.indices.contains(to) else { return nil }
        // A drop offset is in pre-removal space: one past the target slot
        // when the tab moves toward the end.
        return step > 0 ? to + 1 : to
    }

    /// Move the active tab one place up or down in its project's tab list
    /// (Move Tab Up / Move Tab Down). Selection and the tab's sessions stay;
    /// only its position changes. A no-op at either end.
    func moveActiveTab(step: Int, projectID: UUID) {
        guard let offset = activeTabMoveOffset(step: step, projectID: projectID),
              let tabID = workspaces[projectID]?.activeTabID
        else { return }
        if projectID == PinnedTabs.workspaceID {
            reorderPinnedTab(tabID, toIndex: offset)
        } else {
            reorderTab(tabID, inProject: projectID, toIndex: offset)
        }
    }

    func selectNextTab(projectID: UUID) {
        // The pinned workspace cycles in RECORD order — unloaded rows
        // included, restored on landing — so the keyboard walks exactly what
        // the sidebar shows, not just the loaded subset.
        if projectID == PinnedTabs.workspaceID {
            cyclePinnedTab(step: 1)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        ModelWriter.tabSelectNext(in: ws)
        if ws.activeTabID != before {
            saveWorkspaces()
        }
    }

    func selectPreviousTab(projectID: UUID) {
        if projectID == PinnedTabs.workspaceID {
            cyclePinnedTab(step: -1)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        ModelWriter.tabSelectPrevious(in: ws)
        if ws.activeTabID != before {
            saveWorkspaces()
        }
    }

    /// The modifiers the Recent Tab binding is held with, whatever the user
    /// bound it to — the gesture both the switcher and the deferred commit
    /// hang off. Read live rather than assumed: `ctrl+tab` is only the
    /// default, and the commit used to hardcode Control, so rebinding the
    /// action to `cmd+tab` left a cycle that never committed.
    ///
    /// Empty for a bare key, which cannot be *held*: there is no release to
    /// commit on, so cycling degrades to switching straight away (below).
    var recentTabHoldModifiers: NSEvent.ModifierFlags {
        HotkeyRegistry.selectedShortcut(for: .recentTab)?.modifiers ?? []
    }

    func cycleRecentTab(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        // The project screen has no current tab to cycle away from: Recent
        // Tab shows the tab that the screen replaced, with no switcher.
        if let key = keyWindow, key.activeProjectID == projectID, key.showsProjectScreen,
           let current = ws.activeTabID
        {
            selectTab(current, projectID: projectID)
            return
        }
        tabCycler.startIfNeeded(recency: ws.recencyOrder(), in: ws) {
            Set(workspaces.values.flatMap { $0.tabs.flatMap { $0.splitRoot.allPanes().map(\.id) } })
        }
        guard tabCycler.advance() else { return }
        // A binding with no modifier has no release to commit on, so there is
        // no hold gesture to preview: switch now and end the cycle.
        if recentTabHoldModifiers.isEmpty {
            commitTabCycle(projectID: projectID)
            return
        }
        // With the switcher up, a repeat moves the SELECTION only: the tab
        // behind it — and the pane holding focus — stays put until the
        // modifier is released and `commitTabCycle` runs. That is the whole
        // point of showing the candidates (#344), and it also keeps a long
        // hold from dragging focus through every tab on the way past.
        //
        // Without the switcher there is nothing else to look at, so the
        // original behavior stands: each press peeks the tab for real.
        guard !Preferences.shared.showTabSwitcherOverlay, let selected = tabCycler.selectedTabID else { return }
        ModelWriter.tabPeek(selected, in: ws)
    }

    /// Point the in-flight cycle at `index` without committing — what hovering
    /// a card in the switcher does.
    func focusTabCycle(at index: Int) {
        tabCycler.focus(at: index)
    }

    /// Commit the cycle straight to `index` — what clicking a card does. The
    /// modifier may still be held afterwards; the cycle is over either way, so
    /// its eventual release finds nothing to commit.
    func commitTabCycle(projectID: UUID, at index: Int) {
        focusTabCycle(at: index)
        commitTabCycle(projectID: projectID)
    }

    func commitTabCycle(projectID: UUID) {
        guard let selectedID = tabCycler.finish(), let ws = workspaces[projectID] else { return }
        ModelWriter.tabSelect(selectedID, in: ws)
        saveWorkspaces()
    }

    enum GlobalTabDirection { case next, previous }

    func selectGlobalTab(_ direction: GlobalTabDirection, projects: [Project]) {
        // Pinned rows cycle first (they sit at the top of the sidebar), in
        // RECORD order — unloaded records included, so keyboard cycling can
        // land on (and restore) a dead pinned tab exactly like clicking it.
        let pinnedEntries: [(projectID: UUID, tabID: UUID)] = pinnedRecords.map { (PinnedTabs.workspaceID, $0.id) }
        let projectEntries: [(projectID: UUID, tabID: UUID)] = projects.flatMap { p in
            (workspaces[p.id]?.tabs ?? []).map { (p.id, $0.id) }
        }
        // Scratch tabs cycle last: the sidebar draws their section below the
        // projects.
        let scratchEntries: [(projectID: UUID, tabID: UUID)] = (scratchWorkspace?.tabs ?? []).map {
            (ScratchTabs.workspaceID, $0.id)
        }
        let allTabs = pinnedEntries + projectEntries + scratchEntries
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { pid in workspaces[pid]?.activeTabID }
        let currentIndex =
            allTabs.firstIndex { $0.projectID == activeProjectID && $0.tabID == currentTabID } ?? 0
        let newIndex: Int =
            switch direction {
            case .next: (currentIndex + 1) % allTabs.count
            case .previous: (currentIndex - 1 + allTabs.count) % allTabs.count
            }
        let entry = allTabs[newIndex]
        if entry.projectID == PinnedTabs.workspaceID {
            // Loads an unloaded record and persists on its own.
            selectPinnedTab(entry.tabID)
            return
        }
        if entry.projectID == ScratchTabs.workspaceID {
            selectScratchTab(entry.tabID)
            return
        }
        guard let project = projects.first(where: { $0.id == entry.projectID }) else { return }
        let beforeProjectID = activeProjectID
        let beforeTabID = workspaces[project.id]?.activeTabID

        activeProjectID = project.id
        ensureWorkspace(projectID: project.id, path: project.path)
        if let ws = workspaces[project.id] { ModelWriter.tabSelect(entry.tabID, in: ws) }
        if activeProjectID != beforeProjectID
            || workspaces[project.id]?.activeTabID != beforeTabID
        {
            saveWorkspaces()
        }
    }

    /// Tab slots addressable by Cmd+digit — sidebar ROWS in the pinned
    /// workspace (records, unloaded included) and live tabs elsewhere, the
    /// same two sources `selectTabByIndex` selects from. It is what bounds
    /// digit accumulation, so the two must keep counting the same things.
    func selectableTabCount(projectID: UUID) -> Int {
        if projectID == PinnedTabs.workspaceID { return pinnedRecords.count }
        return workspaces[projectID]?.tabs.count ?? 0
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        // Cmd+digit in the pinned workspace counts SIDEBAR rows (records,
        // unloaded included), matching what the user sees.
        if projectID == PinnedTabs.workspaceID {
            guard pinnedRecords.indices.contains(index) else { return }
            selectPinnedTab(pinnedRecords[index].id)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        ModelWriter.tabSelect(index: index, in: ws)
        if ws.activeTabID != before {
            saveWorkspaces()
        }
    }

    // MARK: - Splits

    /// Splits the focused pane using the user's new split directory preference.
    func splitPane(direction: SplitDirection, projectID: UUID, projects: [Project]) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID,
              let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects)
        else { return }
        splitPane(
            paneID,
            direction: direction,
            projectID: projectID,
            projectDirectory: projectDirectory
        )
    }

    /// Splits a specific pane using the user's new split directory preference.
    @discardableResult
    func splitPane(
        _ paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition = .second,
        projectID: UUID,
        projectDirectory: String,
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }),
              let pane = tab.splitRoot.findPane(id: paneID)
        else { return nil }
        // nil = inherit (the source pane's live cwd, else its own
        // `projectPath`) — never coerced to the project root, which would
        // turn a remote pane's split into a local shell.
        let newPaneDirectory = NewTerminalWorkingDirectory(inherits: newSplitInheritsWorkingDirectory()).resolveNewTerminalDirectory(
            projectDirectory: projectDirectory,
            activePaneDirectory: pane.liveLocalWorkingDirectory()
        )
        logger.debug("splitPane: \(String(describing: direction), privacy: .public) pane=\(paneID, privacy: .public)")
        return splitPane(
            paneID,
            direction: direction,
            position: position,
            projectID: projectID,
            command: command,
            env: env,
            newPaneWorkingDirectory: newPaneDirectory,
            focus: focus
        )
    }

    /// Split a SPECIFIC pane — found in whichever of the project's tabs holds
    /// it, unlike the focused-pane overload above — optionally spawning
    /// `command` in the new pane. The control CLI's split path. Returns the
    /// new pane's ID. `focus: false` preserves focus/history/zoom and warms
    /// the new pane, including when its tab or project isn't being displayed.
    @discardableResult
    func splitPane(
        _ paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition = .second,
        projectID: UUID,
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil,
        newPaneWorkingDirectory: String? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil })
        else { return nil }
        let newID = ModelWriter.paneSplit(
            tab,
            paneID: paneID,
            direction: direction,
            position: position,
            command: command,
            env: env,
            newPaneWorkingDirectory: newPaneWorkingDirectory,
            focus: focus
        )
        if !focus, let newID, let pane = tab.splitRoot.findPane(id: newID) {
            warmIfUnrendered(pane, in: tab)
        }
        saveWorkspaces()
        return newID
    }

    /// Split a pane into an equal `rows`×`columns` grid (see
    /// `ModelWriter.paneGrid`), spawning `command` in each new pane. Every
    /// cell honors the new split directory preference, so a grid and a
    /// `Cmd+D` split off the same pane can't disagree about it. Returns the
    /// new pane IDs.
    @discardableResult
    func makeGrid(
        _ paneID: UUID,
        rows: Int,
        columns: Int,
        projectID: UUID,
        projectDirectory: String,
        command: PaneStartCommand? = nil
    ) -> [UUID] {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }),
              let pane = tab.splitRoot.findPane(id: paneID)
        else { return [] }
        let newPaneDirectory = NewTerminalWorkingDirectory(inherits: newSplitInheritsWorkingDirectory()).resolveNewTerminalDirectory(
            projectDirectory: projectDirectory,
            activePaneDirectory: pane.liveLocalWorkingDirectory()
        )
        let created = ModelWriter.paneGrid(
            tab,
            paneID: paneID,
            rows: rows,
            columns: columns,
            command: command,
            newPaneWorkingDirectory: newPaneDirectory
        )
        if !created.isEmpty { saveWorkspaces() }
        return created
    }

    /// Split the focused pane along its longer on-screen axis (Ghostty's
    /// `new_split` / BSP behavior), measured where the user sees it
    /// (`displayedSize`).
    func autoSplitPane(projectID: UUID, projects: [Project]) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID,
              let pane = tab.focusedPane,
              let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects)
        else { return }
        let newPaneDirectory = NewTerminalWorkingDirectory(inherits: newSplitInheritsWorkingDirectory()).resolveNewTerminalDirectory(
            projectDirectory: projectDirectory,
            activePaneDirectory: pane.liveLocalWorkingDirectory()
        )
        ModelWriter.paneSplit(
            tab,
            paneID: paneID,
            direction: SplitDirection.auto(for: displayedSize(of: pane)),
            newPaneWorkingDirectory: newPaneDirectory
        )
        saveWorkspaces()
    }

    func resizePane(_ direction: PaneFocusDirection, projectID: UUID, delta: CGFloat = 0.03) {
        if let tab = workspaces[projectID]?.activeTab {
            ModelWriter.splitResize(tab, direction: direction, delta: delta)
        }
        saveWorkspaces()
    }

    func toggleZoom(projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        ModelWriter.paneZoom(tab, toggling: paneID)
    }

    func closePane(_ paneID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        // Find the tab that actually contains this pane (not just the active tab)
        guard let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) else {
            return
        }
        // Closing a pinned tab's LAST pane closes the tab, which for a pinned
        // tab is an unload (record kept). Route it whole through closeTab so
        // the unload path tears the pane down itself — falling through to
        // removePane would destroy the surface first and leave unloadPinnedTab
        // double-tearing it (harmless but pointless).
        if projectID == PinnedTabs.workspaceID, tab.splitRoot.allPanes().count <= 1 {
            closeTab(tab.id, projectID: projectID)
            return
        }
        logger.debug("closePane: \(paneID, privacy: .public) project=\(projectID, privacy: .public)")
        // Pane closed for good → its session dies with it. (The onlyPaneLeft
        // path below re-releases via closeTab; killSession is a no-op on a
        // missing session, so the overlap is harmless.)
        if let closing = tab.splitRoot.findPane(id: paneID) {
            releaseSessions([closing])
        }
        switch ModelWriter.paneClose(tab, paneID: paneID) {
        case .onlyPaneLeft:
            closeTab(tab.id, projectID: projectID)
        case .removed:
            saveWorkspaces()
        case .notFound:
            break
        }
    }

    /// A pane's child process ended (libghostty's `close_surface`, routed
    /// through `onProcessExit`). Local panes close, as always — via
    /// `paneProcessExited`, so a pinned tab's last pane unloads its tab
    /// instead (#285). A REMOTE pane's child is its client
    /// (`macterm remote-pane`, 0057), which survives a dropped connection
    /// and waits on the tty (#281). So it exits only when the session's shell
    /// ended: the pane closes with no confirmation (nothing runs in it), and
    /// the close ends the exited session on the host.
    func handleProcessExit(_ paneID: UUID, projectID: UUID) {
        let pane = workspaces[projectID]?.tabs
            .compactMap { $0.splitRoot.findPane(id: paneID) }
            .first
        guard let pane, pane.isRemote, projectID != PinnedTabs.workspaceID else {
            paneProcessExited(paneID, projectID: projectID)
            return
        }
        logger.info("remote pane client ended — closing the pane")
        closePane(paneID, projectID: projectID)
    }

    func requestClosePane(_ paneID: UUID, projectID: UUID) {
        let pane = workspaces[projectID]?.tabs
            .compactMap { $0.splitRoot.findPane(id: paneID) }
            .first
        guard let pane, closeNeedsConfirmation([pane]) else {
            closePane(paneID, projectID: projectID)
            return
        }
        present(PendingDialog(
            kind: .closePane(paneID: paneID, projectID: projectID),
            title: String(localized: "Close running process?"),
            message: String(localized: "A process is still running in this pane. Close the pane anyway?"),
            confirmTitle: String(localized: "Close"),
            host: .mainWindow
        ) { [weak self] in self?.closePane(paneID, projectID: projectID) })
    }

    // MARK: - Layout files

    /// Apply the central project file matching `project.path` to its live
    /// workspace, reconciling with minimal destruction (see
    /// `LayoutReconciler`). A non-destructive reconcile (only spawns +
    /// resizes) runs immediately; one that would terminate panes/tabs is
    /// staged as a `pendingDialog` for confirmation. Returns an error to
    /// surface when no file matches, the file is unparseable, or it declares
    /// no tabs (an empty declaration must never plan "close every tab").
    @discardableResult
    func applyLayout(project: Project, host: DialogHost = .mainWindow) -> Error? {
        logger.info("applyLayout: project=\(project.name, privacy: .public)")
        let layout: LayoutFile
        do {
            layout = try layoutFiles.layout(for: project)
        } catch {
            logger.error("applyLayout failed to load: \(error, privacy: .public)")
            return error
        }
        let plan = LayoutReconciler.plan(
            layout: layout,
            workspace: workspaces[project.id],
            projectRoot: project.path,
            projectID: project.id
        )
        let planDesc = "tabs=\(plan.tabs.count) destroy=\(plan.panesToDestroy.count) closeTabs=\(plan.tabsToClose.count)"
        logger.info("applyLayout plan: \(planDesc, privacy: .public)")
        if plan.isDestructive {
            logger.info("applyLayout: staged for confirmation")
            let projectID = project.id
            present(PendingDialog(
                kind: .applyLayout(projectID: projectID),
                title: String(localized: "Apply layout?"),
                message: String(localized: "If you apply this layout, Macterm closes some panes and ends the processes in them."),
                confirmTitle: String(localized: "Apply"),
                host: host
            ) { [weak self] in
                guard let self else { return }
                executeLayoutPlan(plan, projectID: projectID)
                // Always user-invoked: reaching here means they clicked through
                // the destructive-apply confirmation.
                presentToast(String(localized: "Layout applied"))
            })
        } else {
            executeLayoutPlan(plan, projectID: project.id)
        }
        return nil
    }

    /// `applyLayout` + error presentation: failures land in
    /// `pendingDialog` as a layout notice. The shared entry
    /// point for the palette/menu command and the Settings row menu — every
    /// caller is user-invoked, so a clean apply gets a success toast.
    func applyLayoutPresentingError(_ project: Project, host: DialogHost = .mainWindow) {
        if let error = applyLayout(project: project, host: host) {
            presentLayoutError(verb: .apply, message: error.localizedDescription, host: host)
            return
        }
        // A destructive plan is staged, not applied — its confirmation dialog is
        // up, and the toast belongs to whatever the user chooses there
        // (`confirmPendingDialog`), not to merely opening the prompt.
        if !isLayoutApplyPending {
            presentToast(String(localized: "Layout applied"))
        }
    }

    /// Save the project's live workspace as its central project file — one of
    /// the two ways a project file ever changes (the other is the user's own
    /// editor). Creates the file when none declares this path yet; realigns
    /// the filename to the current name slug when it drifted.
    /// `siblingProjects` is the full project list, used only to detect another
    /// project that shares this directory and filename slug (and would thus
    /// share the same layout file). AppState doesn't own the `ProjectStore`, so
    /// callers pass it; the default empty list keeps the shared-path check
    /// inert for callers that don't have it (and for tests that don't care).
    @discardableResult
    func saveLayout(project: Project, siblingProjects: [Project] = [], host: DialogHost = .mainWindow) -> Error? {
        logger.info("saveLayout: project=\(project.name, privacy: .public)")
        guard let ws = workspaces[project.id] else { return nil }
        do {
            let layout = LayoutSerializer.layout(for: ws, projectName: project.name, projectRoot: project.path)
            let saved = try layoutFiles.save(layout, for: project, siblingProjects: siblingProjects)
            logger.info("saveLayout succeeded: tabs=\(ws.tabs.count, privacy: .public)")
            if let conflict = saved.conflict {
                presentLayoutSaveConflict(conflict, savedTo: saved.target, host: host)
            }
            // Confirm the clean save only. A conflict raises a dialog that
            // says the file landed *and* what's wrong with it — a cheerful
            // "Layout saved" stacked on top would undercut it.
            //
            // The subtitle is the full path, home-contracted: the projects
            // directory isn't somewhere the user necessarily has in mind, so a
            // bare filename doesn't tell them where to go look. `~` keeps it
            // readable (and keeps the username out of a screenshot).
            if pendingDialog == nil {
                presentToast(String(localized: "Layout saved"), subtitle: ProjectPath.homeContracted(saved.target.path))
            }
            return nil
        } catch {
            logger.error("saveLayout failed: \(error, privacy: .public)")
            return error
        }
    }

    private func presentLayoutSaveConflict(
        _ conflict: LayoutFileService.SaveConflict,
        savedTo target: URL,
        host: DialogHost
    ) {
        switch conflict {
        case let .strayFiles(names):
            presentLayoutError(
                verb: .save,
                message: String(localized: """
                Macterm saved the layout to “\(target.lastPathComponent)”. These other files also \
                declare the path of this project, and Macterm ignores them: \(names). \
                Remove them or merge them in the projects folder.
                """),
                title: String(localized: "Layout saved with a conflict"),
                host: host
            )
        case let .sharedFile(names):
            presentLayoutError(
                verb: .save,
                message: String(localized: """
                \(names) share this folder and the layout file “\(target.lastPathComponent)” with this project. \
                Your save replaced their layout. Each save replaces the one before. \
                Give the projects different names to keep separate layout files.
                """),
                title: String(localized: "Layout file shared with another project"),
                host: host
            )
        }
    }

    /// `saveLayout` + error presentation, mirroring `applyLayoutPresentingError`.
    func saveLayoutPresentingError(
        _ project: Project,
        siblingProjects: [Project] = [],
        host: DialogHost = .mainWindow
    ) {
        if let error = saveLayout(project: project, siblingProjects: siblingProjects, host: host) {
            presentLayoutError(verb: .save, message: error.localizedDescription, host: host)
        }
    }

    /// Swap each tab's tree to the reconciled shape, reusing the live `Pane`
    /// objects the plan kept (surfaces preserved) and destroying the rest.
    private func executeLayoutPlan(_ plan: LayoutReconciler.Plan, projectID: UUID) {
        logger
            .info("executeLayoutPlan: tabs=\(plan.tabs.count, privacy: .public) destroying=\(plan.panesToDestroy.count, privacy: .public)")
        let existing = workspaces[projectID]?.tabs ?? []
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var newTabs: [TerminalTab] = []
        for planned in plan.tabs {
            if let id = planned.existingTabID, let tab = byID[id] {
                // Reuse the tab object (preserves its id/history); swap the tree.
                ModelWriter.tabSetTree(tab, root: planned.root, focusedPaneID: planned.focusedPaneID)
                ModelWriter.tabSet(tab, title: planned.title)
                newTabs.append(tab)
            } else {
                newTabs.append(TerminalTab(
                    id: UUID(),
                    splitRoot: planned.root,
                    focusedPaneID: planned.focusedPaneID,
                    customTitle: planned.title
                ))
            }
        }

        // Destroy surfaces only AFTER the new trees no longer reference them.
        // A layout-dropped pane is gone for good (no declared node claims it),
        // so its zmx session dies too — otherwise it would linger as a
        // clients==0 daemon.
        releaseSessions(plan.panesToDestroy)
        for pane in plan.panesToDestroy {
            SurfaceRegistry.shared.destroySurfaces(of: pane)
        }

        let activeTabID = newTabs.first?.id
        if let ws = workspaces[projectID] {
            ModelWriter.tabReplaceAll(in: ws, with: newTabs, activeTabID: activeTabID)
        } else {
            workspaces[projectID] = Workspace(id: projectID, tabs: newTabs, activeTabID: activeTabID)
        }
        activeProjectID = projectID
        saveWorkspaces()

        // Focus the declared/active pane once its surface attaches to a window.
        if let tab = newTabs.first, let paneID = tab.focusedPaneID {
            FocusRestoration.restoreFocus(
                to: paneID,
                in: tab.splitRoot,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        // Start the non-active tabs' processes too, so an applied multi-tab
        // layout runs everything it declares, not just the active tab.
        warmFocusedProject()
    }

    /// Focus a pane. `windowID` is the window the click came from: the claim
    /// goes to that window's surface. Without one (the CLI) it goes to the
    /// pane's preferred surface.
    func focusPane(_ paneID: UUID, projectID: UUID, windowID: UUID? = nil) {
        // The tab CONTAINING the pane, not the workspace's active tab: with
        // several windows a click can land in a window whose tab is not the
        // key window's, and focusing a foreign id on the active tab would
        // leave it pointing at a pane it does not have.
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil })
        else { return }
        ModelWriter.paneFocus(tab, paneID: paneID)
        // Focusing a view is how the user says "drive the size from here",
        // so tell zmx as well as ourselves — its daemon only switches leader
        // on real keystrokes, and the user has not typed anything yet.
        if let pane = tab.splitRoot.findPane(id: paneID) {
            claimSessionLeadership(
                windowID.map { SurfaceRegistry.shared.surface(for: pane, in: .window($0)) }
                    ?? SurfaceRegistry.shared.preferredSurface(of: pane)
            )
        }
    }

    /// Publish presentation-only renderer state for one window's view of a
    /// pane. The color is transient and therefore does not trigger
    /// persistence.
    func setAdaptiveBackgroundColor(_ color: CGColor?, paneID: UUID, projectID: UUID, windowID: UUID? = nil) {
        guard let pane = workspaces[projectID]?.tabs
            .lazy
            .compactMap({ $0.splitRoot.findPane(id: paneID) })
            .first
        else { return }
        let surface = SurfaceRegistry.shared.surface(for: pane, in: Self.host(windowID))
        guard surface.adaptiveBackgroundColor != color else { return }
        surface.adaptiveBackgroundColor = color
    }

    /// Begin the sidebar rename flow for the tab containing `paneID` — the
    /// ghostty `prompt_surface_title` keybind's Macterm mapping (titles live
    /// on tabs here, not surfaces). No-op for panes outside any workspace
    /// (the quick terminal has no tab UI to rename).
    func renameTab(containing paneID: UUID, projectID: UUID) {
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.contains(paneID: paneID) })
        else { return }
        sidebarVisible = true
        let tabID = tab.id
        // Defer a tick so the sidebar row's TextField exists before it's asked
        // to begin editing — same reason as the Rename Tab command.
        DispatchQueue.main.async { self.renamingTabID = tabID }
    }

    /// Set (or, with nil, clear) the custom title of the tab containing
    /// `paneID` — the ghostty `set_tab_title` keybind's Macterm mapping,
    /// writing the same field the sidebar rename edits.
    func setTabTitle(containing paneID: UUID, projectID: UUID, title: String?) {
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.contains(paneID: paneID) })
        else { return }
        ModelWriter.tabSet(tab, title: title)
        saveWorkspaces()
    }

    func navigateToPane(_ paneID: UUID, projectID: UUID) {
        guard workspaces[projectID] != nil else {
            NSApp.activate()
            appDelegate?.reopenIfNeeded()
            return
        }
        revealProject(projectID)
        recordProjectVisit(projectID)
        if let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
            let beforeTabID = workspaces[projectID]?.activeTabID
            let beforeFocusedPaneID = tab.focusedPaneID
            if let ws = workspaces[projectID] { ModelWriter.tabSelect(tab.id, in: ws) }
            ModelWriter.paneFocus(tab, paneID: paneID)
            if workspaces[projectID]?.activeTabID != beforeTabID
                || tab.focusedPaneID != beforeFocusedPaneID
            {
                saveWorkspaces()
            }
        }
        appDelegate?.reopenIfNeeded()
        NSApp.activate()
        if let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
            // Resolve the target window INSIDE the deferred continuation:
            // `NSApp.activate()` is asynchronous, so reading keyWindow/mainWindow
            // synchronously here (the common caller is a notification click while
            // Macterm is inactive) returns nil and makes restoreFocus no-op. Fall
            // back to the AppDelegate's cached terminal window when both are still
            // nil (an ordered-out/unfocused SwiftUI window reports neither).
            // The window SHOWING the project comes first (#345): the pane's
            // NSView lives in that window's hierarchy, and `revealProject`
            // fronted it — the key window can still be the one the user was
            // in a moment ago while activation is in flight.
            DispatchQueue.main.async {
                let showing = self.windows.first { $0.activeProjectID == projectID }
                    .flatMap { self.nsWindow(for: $0) }
                let window = showing
                    ?? NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? self.appDelegate?.mainWindow
                FocusRestoration.restoreFocus(to: paneID, in: tab.splitRoot, window: window)
            }
        }
    }

    func focusedPane(for projectID: UUID) -> Pane? {
        workspaces[projectID]?.activeTab?.focusedPane
    }

    // MARK: - Pane focus navigation

    func focusPaneInDirection(_ direction: PaneFocusDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let focusedID = tab.focusedPaneID
        else { return }
        if let bestID = tab.splitRoot.nearestPane(from: focusedID, direction: direction) {
            ModelWriter.paneFocus(tab, paneID: bestID)
        }
    }

    /// Swap the focused pane with its neighbor in `direction` (Move Pane
    /// Left/Right/Up/Down). The neighbor is the pane that Focus in the same
    /// direction would go to. Shells and focus stay with their panes.
    func moveFocusedPane(_ direction: PaneFocusDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab, ModelWriter.paneSwap(tab, direction: direction) else { return }
        saveWorkspaces()
    }

    /// Whether Move Pane in `direction` has a pane to swap with.
    func canMoveFocusedPane(_ direction: PaneFocusDirection, projectID: UUID) -> Bool {
        guard let tab = workspaces[projectID]?.activeTab, let paneID = tab.focusedPaneID else { return false }
        return tab.splitRoot.nearestPane(from: paneID, direction: direction) != nil
    }

    /// Cycle focus through the active tab's panes in tree order, wrapping at
    /// the ends. `forward` moves to the next pane; otherwise the previous.
    func cyclePane(forward: Bool, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab else { return }
        let panes = tab.splitRoot.allPanes()
        guard panes.count > 1 else { return }
        let current = tab.focusedPaneID.flatMap { id in panes.firstIndex(where: { $0.id == id }) } ?? 0
        let step = forward ? 1 : -1
        let next = panes[(current + step + panes.count) % panes.count]
        ModelWriter.paneFocus(tab, paneID: next.id)
    }

    // MARK: - Project navigation

    func selectNextProject(projects: [Project]) {
        stepProject(1, projects: projects)
    }

    func selectPreviousProject(projects: [Project]) {
        stepProject(-1, projects: projects)
    }

    /// Project cycling treats the pinned workspace as a slot ABOVE the first
    /// project and the scratch workspace as a slot BELOW the last (where the
    /// sidebar draws them) — without it, the keyboard could enter a section
    /// but never leave it. `projects` is in tree order, so every project,
    /// with a folder or not, is a slot in the order of the sidebar.
    private func stepProject(_ step: Int, projects: [Project]) {
        var slots = projects.map(\.id)
        if !pinnedRecords.isEmpty {
            slots.insert(PinnedTabs.workspaceID, at: 0)
        }
        if hasScratchTabs {
            slots.append(ScratchTabs.workspaceID)
        }
        guard slots.count > 1, let current = activeProjectID,
              let i = slots.firstIndex(of: current)
        else { return }
        let target = slots[(i + step + slots.count) % slots.count]
        if target == PinnedTabs.workspaceID {
            selectPinnedProject()
        } else if target == ScratchTabs.workspaceID {
            selectScratchTabs()
        } else if let project = projects.first(where: { $0.id == target }) {
            selectProject(project)
        }
    }

    // MARK: - Focus

    /// Hand first responder back to the pane the user is working in — the
    /// palette closing, a sidebar rename ending, the overlay sidebar
    /// collapsing.
    ///
    /// Only for a window that is actually KEY. "The pane the user is working
    /// in" is otherwise a guess, and the fallback below is what every caller
    /// has always got: with the quick terminal up, the panel holds key and its
    /// own restore paths own the focus.
    func restoreFocusToActivePane() {
        guard let projectID = activeProjectID else { return }
        if let window = keyOrFirstWindow,
           let nsWindow = nsWindow(for: window), nsWindow.isKeyWindow,
           let tab = selectedTab(for: projectID, in: window),
           let paneID = tab.focusedPaneID
        {
            FocusRestoration.restoreFocus(to: paneID, in: tab.splitRoot, window: nsWindow)
            return
        }
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        FocusRestoration.restoreFocus(
            to: paneID,
            in: tab.splitRoot,
            window: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func markActiveTabSeen(projectID: UUID) {
        guard projectID == activeProjectID else { return }
        workspaces[projectID]?.activeTab?.markSeen()
    }

    /// Marks the active tab seen when it holds `paneID`, the app is active,
    /// and the key window draws the pane (`paneIsInKeyWindow`). Reads
    /// `isAppActive`, not `NSApp.isActive`: NSApp is nil during init
    /// (`pollNow`) and in tests.
    func markSeenIfActive(paneID: UUID, projectID: UUID) {
        guard isAppActive(),
              projectID == activeProjectID,
              let tab = workspaces[projectID]?.activeTab,
              let pane = tab.splitRoot.findPane(id: paneID),
              paneIsInKeyWindow(pane)
        else { return }
        tab.markSeen()
    }

    // MARK: - Private

    private func ensureWorkspace(projectID: UUID, path: String) {
        // The pinned workspace starts EMPTY — the path-taking init spawns an
        // initial tab, which nobody pinned. The scratch workspace too: a tab
        // there is one the user asked for.
        if projectID == PinnedTabs.workspaceID {
            ensurePinnedWorkspace()
            return
        }
        if projectID == ScratchTabs.workspaceID {
            ensureScratchWorkspace()
            return
        }
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(id: projectID, projectPath: path)
        }
    }
}
