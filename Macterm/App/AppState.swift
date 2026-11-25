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
            // The server keeps the key window's selection (`select.set`), so
            // the CLI and a new window find it with no GUI state.
            if activeProjectID != oldValue, let activeProjectID { writer.selectSet(project: activeProjectID) }
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
        guard let project = window.activeProjectID, hasWindowTabSelection(project), let tabID else { return }
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
        guard let project = model.project(projectID) else { return nil }
        if showsProjectScreen(project, in: window) { return nil }
        if hasWindowTabSelection(projectID),
           let id = window.activeTabIDs[projectID],
           let tab = model.tabs(of: projectID).first(where: { $0.id == id })
        {
            return tab
        }
        return model.activeTab(of: projectID)
    }

    /// Whether each window keeps its own tab selection in `projectID`. A
    /// project whose tabs are rows above the tree (`sidebar: top`, Pinned)
    /// has one selection for every window: its active tab.
    func hasWindowTabSelection(_ projectID: UUID) -> Bool {
        model.project(projectID)?.sidebar != .top
    }

    /// Whether `window` shows the project screen of `project`. Only a
    /// project of the tree has one: a flag restored over a pinned or scratch
    /// selection is ignored.
    private func showsProjectScreen(_ project: Project, in window: WindowState) -> Bool {
        window.showsProjectScreen && window.activeProjectID == project.id && project.isTreeProject
    }

    /// Show the project screen of `project` in `window` (the key window when
    /// nil), also when the project has tabs: what a click on a sidebar
    /// project row and CLI `project select` do. The project's tabs stay; a
    /// selection of one of them shows it. A palette project row shows the
    /// last tab (`showLastTab(of:)`).
    func showProjectScreen(_ project: Project, in window: WindowState?) {
        selectProject(project, in: window)
        guard let target = window ?? keyWindow, target.activeProjectID == project.id,
              model.project(project.id)?.isTreeProject == true, !target.showsProjectScreen
        else { return }
        target.showsProjectScreen = true
        settleWindowSelections()
        persistWindows()
    }

    /// Show `project` in the key window at the tab that the window last
    /// showed there (`WindowState.activeTabIDs`), else the workspace's active
    /// tab: what a palette project row does. A project with no tabs shows
    /// `EmptyProjectView`. This is a function of its own and not a Bool
    /// parameter of `showProjectScreen`, because the sidebar row and CLI
    /// `project select` show the project screen.
    func showLastTab(of project: Project) {
        selectProject(project)
        guard let key = keyWindow, key.activeProjectID == project.id else { return }
        endProjectScreen(in: key)
        settleWindowSelections()
        claimLeadershipForKeyWindow()
    }

    /// Whether the key window shows the project screen. A command that acts on
    /// the shown tab or pane (`AppCommand.actsOnShownTab`) then does nothing,
    /// as in a project with no tabs: the workspace's active tab is not on
    /// screen.
    var keyWindowShowsProjectScreen: Bool {
        guard let key = keyWindow, let projectID = key.activeProjectID, let project = model.project(projectID) else { return false }
        return showsProjectScreen(project, in: key)
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
    /// last surface (a warm view), shown or not, and the surface that runs
    /// its plain ssh shell (`Pane.plainShellSurfaceID`). Idempotent and
    /// cheap: run it where a window's selection changes.
    private func settleWindowSelections() {
        var shown: [UUID: Set<UUID>] = [:]
        for window in renderingWindows {
            guard let projectID = window.activeProjectID, model.project(projectID) != nil else { continue }
            if hasWindowTabSelection(projectID) {
                let tabs = model.tabs(of: projectID)
                let valid = window.activeTabIDs[projectID].map { id in tabs.contains { $0.id == id } } ?? false
                if !valid, let current = model.activeTabID(of: projectID) {
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
                // A plain ssh shell is its surface's: only the window, the
                // tab or the pane ends it, not a tab switch.
                if pane.plainShellSurfaceID == surface.id { continue }
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
        if keyWindowID == window.id || !hasWindowTabSelection(projectID) {
            selectTab(tabID, projectID: projectID)
            return
        }
        guard model.tabs(of: projectID).contains(where: { $0.id == tabID }) else { return }
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
           model.project(projectID) != nil, hasWindowTabSelection(projectID)
        {
            if let chosen = key.activeTabIDs[projectID], model.tabs(of: projectID).contains(where: { $0.id == chosen }) {
                if model.activeTabID(of: projectID) != chosen { writer.tabPeek(chosen, in: projectID) }
            } else if let current = model.activeTabID(of: projectID) {
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

    /// The mirror's hook: a project's active tab changed by any writer — `createTab`,
    /// `closeTab` picking a neighbour, cycling, the CLI — so the window it is
    /// the mirror of records the change. The key window when it is on the
    /// project; otherwise the first window that is, so a `tab select
    /// --project` for a background project still moves the window showing it.
    private func projectActiveTabDidChange(_ projectID: UUID) {
        guard hasWindowTabSelection(projectID) else { return }
        let onProject = windows.filter { $0.activeProjectID == projectID }
        guard let target = onProject.first(where: { $0.id == keyWindowID }) ?? onProject.first else { return }
        if let tab = model.activeTabID(of: projectID) {
            target.activeTabIDs[projectID] = tab
            // A selected tab ends the project screen: it is what shows now.
            endProjectScreen(in: target)
        } else {
            target.activeTabIDs.removeValue(forKey: projectID)
        }
        settleWindowSelections()
        if target.id == keyWindowID { claimLeadershipForKeyWindow() }
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

    /// The palette's screen shows a failed listing with Retry, so ⌘R is
    /// Retry (`PaletteResponder`).
    var paletteShowsRetry: Bool {
        keyOrFirstWindow?.paletteStack.last?.scope.failure?.retryable == true
    }

    /// Show the palette on `scope` alone (nil: the root), whatever stack of
    /// screens was up. A different screen starts from its own text
    /// (`PaletteScope.initialQuery`: empty for a search) — text typed for
    /// one search means nothing to another.
    func openCommandPalette(scope: PaletteScopeID?) {
        guard let window = keyOrFirstWindow else { return }
        if window.paletteScope != scope || window.paletteStack.count > 1 {
            window.showPaletteScope(scope)
            commandPaletteQuery = window.paletteStack.last?.scope.initialQuery ?? ""
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
            self?.persistState()
        }
    }

    /// The link to the model on the Mac server (design/010). The views read
    /// `model`, and every change goes through `writer`.
    @ObservationIgnored
    let modelConnection: ModelConnection
    /// The projects, their tabs and their panes, as the server has them.
    var model: ModelMirror { modelConnection.mirror }
    /// The one way to change the model: requests to the server.
    @ObservationIgnored
    let writer: ModelWriter

    /// Ordered pinned-tab records — the sidebar's pinned section. A record
    /// whose id matches a live tab of the pinned project (alias `pinned`)
    /// is loaded; the rest are unloaded (their sessions died) and rebuild
    /// from their declaration on selection. All mutation goes through
    /// `AppState+PinnedTabs.swift`.
    var pinnedRecords: [PinnedTabRecord] = []

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
    /// so `persistState` only rewrites the file when the pinned SET changed
    /// — not on every workspace save. nil = no baseline yet, which also stops
    /// a pre-restore save from clobbering the user's file with an empty list.
    @ObservationIgnored
    var pinnedMembershipStamp: [UUID]?

    /// Auto-writes to `pinned.yaml` are paused because the on-disk file is
    /// unparseable (or lost its `path: <pinned>` marker) — overwriting would
    /// destroy the user's mid-edit work. Cleared when a later read parses.
    var pinnedLayoutSuspended = false

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

    /// The v1 snapshot, `workspaces_v3.json`: read once by the import
    /// (design/010 §8), never written.
    let workspaceStore: WorkspaceStore
    /// v1's `projects.json`: read once by the import, never written.
    @ObservationIgnored
    let v1ProjectsURL: URL
    /// `gui-state.json`: what only a window needs (design/010 §2).
    @ObservationIgnored
    let guiStateStore: GUIStateStore

    /// Whether the model could not be read: the server has no model, or a
    /// model that it cannot write. The first-run seed must not mistake an
    /// unread model for a fresh install, and nothing is ended on it.
    var snapshotLoadFailed: Bool { model.data == nil || model.readonly || guiStateStore.loadFailed }

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
        modelConnection: ModelConnection,
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        guiStateStore: GUIStateStore = GUIStateStore(),
        v1ProjectsURL: URL = FileStorage.fileURL(filename: "projects.json"),
        projectFiles: ProjectFileStore = ProjectFileStore(),
        paletteHotkeys: PaletteHotkeys = .shared,
        quickTerminal: QuickTerminalSplitState? = nil,
        legacyPanelVisible: @escaping () -> Bool = { Preferences.shared.takeLegacyProjectMemoryPanelVisible() }
    ) {
        self.modelConnection = modelConnection
        writer = ModelWriter(connection: modelConnection)
        self.workspaceStore = workspaceStore
        self.guiStateStore = guiStateStore
        self.v1ProjectsURL = v1ProjectsURL
        self.legacyPanelVisible = legacyPanelVisible
        layoutFiles = LayoutFileService(projectFiles: projectFiles)
        pinnedLayoutStore = PinnedLayoutStore(directoryURL: projectFiles.configDirectoryURL)
        widgetLayoutStore = WidgetLayoutStore(directoryURL: projectFiles.configDirectoryURL)
        customPalettes = CustomPaletteStore(configDirectoryURL: projectFiles.configDirectoryURL, hotkeys: paletteHotkeys)
        if let quickTerminal { adoptQuickTerminal(quickTerminal) }
        writer.onError = { [weak self] reason in
            self?.presentToast(String(localized: "The change did not apply"), subtitle: reason)
        }
        model.onActiveTabChanged = { [weak self] projectID in self?.projectActiveTabDidChange(projectID) }
        model.onPanesRemoved = { [weak self] panes, records in self?.panesLeftModel(panes, records: records) }
        modelConnection.onInstall = { [weak self] state in self?.modelDidInstall(state) }
        let autoTileToken = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllTabsIfEnabled() }
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
        let tokens: [(NotificationCenter, NSObjectProtocol)] = [
            (center, center.addObserver(forName: .terminalPollEvent, object: nil, queue: .main, using: onEvent)),
            (center, center.addObserver(forName: .terminalSurfaceSized, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimLeadershipForKeyWindow() }
            }),
            (center, center.addObserver(forName: .terminalSessionLead, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimLeadershipForKeyWindow() }
            }),
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
        for (projectID, tab) in model.allTabs {
            for pane in tab.splitRoot.allPanes() {
                if pane.executionState == .running { sawBusyPane = true }
                markSeenIfActive(paneID: pane.id, projectID: projectID)
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

    /// The auto-tiling preference changed: the server takes it as the
    /// default `rebalance` of a request, and every tab is made even.
    private func rebalanceAllTabsIfEnabled() {
        writer.modelOptions(autoTiling: Preferences.shared.autoTilingEnabled)
        guard Preferences.shared.autoTilingEnabled else { return }
        for (_, tab) in model.allTabs {
            writer.tabRebalance(tab.id)
        }
        persistState()
    }

    // MARK: - The model on the server

    /// After each `state.subscribe`: the first at launch, and the one after
    /// each new connection. The first launch with no import imports v1's
    /// files (design/010 §8).
    private func modelDidInstall(_ state: MactermProtocol.StateSubscribe.Result) {
        writer.modelOptions(autoTiling: Preferences.shared.autoTilingEnabled)
        guard let data = state.model, !state.readonly, !data.importedV1 else { return }
        importV1Files()
    }

    /// The panes that left the model, in any request of any client: their
    /// surfaces go (the closing ghost first), and a remote pane's session
    /// ends over its host's link, because the server has no link to a host
    /// (design/010 §5). The server ends a local pane's session itself.
    private func panesLeftModel(_ panes: [Pane], records: [MactermProtocol.PaneRemoved]) {
        let gone = Dictionary(panes.map { (model.wire($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where record.host != nil {
            gone[record.id]?.killPersistentSession(using: sessionClient)
        }
        for pane in panes {
            SurfaceRegistry.shared.destroySurfaces(of: pane)
        }
    }

    // MARK: - Restore / Save

    func restoreSelection(projects: [Project]) {
        logger.info("restoreSelection: \(projects.count, privacy: .public) projects")
        hasRestoredSelection = true
        let gui = guiStateStore.load()
        // The retired value is read (and removed) only when a window can
        // take it.
        let windows = gui?.windows ?? []
        lastSavedWindows = windows.isEmpty ? nil : windows
        savedWindowSnapshots = windows.isEmpty
            ? []
            : WindowSnapshot.adoptingLegacyPanelVisibility(windows, legacyVisible: legacyPanelVisible())
        // Pinned tabs: records first, then the launch reconcile against
        // `pinned.yaml` (the file is authoritative for membership — see
        // AppState+PinnedTabs). Tabs whose sessions died rebuild from their
        // declaration, async, after the server says which sessions survived.
        restorePinnedState(gui?.pinned ?? [])
        reconcilePinnedLayoutAtLaunch(projects: projects)
        // The quick terminal is a hidden project of the model.
        restoreQuickTerminal()
        // `widgets.yaml` decides which widgets exist.
        let restoredWidgets = restoreDesktopWidgets(gui?.desktopWidgets ?? [])
        reconcileWidgetLayoutAtLaunch()
        Task { await materializeRestoredDesktopWidgets(restoredWidgets) }
        if let id = Preferences.shared.activeProjectID, let project = model.project(id), project.isSelectable {
            // A project of the top or the bottom section shows only while
            // it has a tab or a record: else the window would show an empty
            // detail view with nothing selected.
            let shown = project.isTreeProject || !model.tabs(of: id).isEmpty || (project.sidebar == .top && !pinnedRecords.isEmpty)
            if shown {
                activeProjectID = id
                if project.isTreeProject { recordProjectVisit(id) }
                markActiveTabSeen(projectID: id)
                warmFocusedProject()
            }
        }
        Task { await materializeRestoredPinnedTabs() }
        // A model that did not read gives no names: nothing is ended (an
        // empty claim set would mark every live session an orphan).
        guard !snapshotLoadFailed else { return }
        endV1SessionsOnce(names: localSessionNames())
        sweepLocalOrphans()
    }

    /// The windows of the last save that had any: a save while no window
    /// is registered (launch, quit) keeps them.
    @ObservationIgnored
    private var lastSavedWindows: [WindowSnapshot]?

    /// Writes what only the GUI keeps (`gui-state.json`), and gives the
    /// server the live folder of each pane (`pane.set`), so that a pane
    /// whose session is gone (a restart of the Mac) starts its new shell
    /// where the user was. Every change ends here, so it is also where the
    /// windows' surfaces follow the model.
    func persistState() {
        settleWindowSelections()
        // Any change can have made a tab inside the pinned project (CLI `tab
        // new`, a pane separated into it, a merge): it gets a record.
        syncPinnedRecordsWithModel()
        syncPaneFolders()
        // A closed or unloaded tab takes its bell out of the count with it.
        syncDockBadge()
        // Before the restore, and with no model, the GUI state is not known:
        // a write would lose it.
        guard hasRestoredSelection, model.data != nil else { return }
        let snapshots: [WindowSnapshot]? = windows.isEmpty
            ? lastSavedWindows
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
            }
        if !windows.isEmpty { lastSavedWindows = snapshots }
        guiStateStore.save(GUIStateFile(
            version: GUIStateStore.currentVersion,
            windows: snapshots,
            pinned: pinnedRecords.map { PinnedRecordState(id: $0.id, declaration: $0.declaration, originProjectID: $0.originProjectID) },
            desktopWidgets: desktopWidgetStates()
        ))
    }

    /// Gives the server each pane's folder where it differs from the
    /// model's: the live folder of a local pane (OSC 7, else the kernel's
    /// cwd of its foreground), and the host folder of a remote pane.
    private func syncPaneFolders() {
        for (_, tab) in model.allTabs {
            for pane in tab.splitRoot.allPanes() {
                guard let value = model.paneValue(pane.id) else { continue }
                if pane.isRemote {
                    let live = SurfaceRegistry.shared.view(of: pane)?.currentPwd.flatMap { HostCommands.isSafeHostFolder($0) ? $0 : nil }
                    if let folder = live ?? pane.hostSessionDirectory, folder != value.hostSessionDir {
                        writer.paneSet(pane.id, hostSessionDirectory: folder)
                    }
                } else if let live = SurfaceRegistry.shared.view(of: pane)?.currentPwd ?? ProcessInspector
                    .foregroundWorkingDirectory(forPane: pane),
                    live != value.cwd
                {
                    writer.paneSet(pane.id, cwd: live)
                }
            }
        }
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
            // The window now selects a tab of this project.
            settleWindowSelections()
        }
    }

    /// Show any project that a window can select: the pinned project shows
    /// its records, loaded or not (`selectPinnedProject`); every other
    /// project is a plain selection. Intents use it (design/010 §11).
    func select(project: Project) {
        guard project.isSelectable else { return }
        if project.sidebar == .top {
            selectPinnedProject()
        } else {
            selectProject(project)
        }
    }

    func selectProject(_ project: Project) {
        logger.debug("selectProject: \(project.name, privacy: .public)")
        activeProjectID = project.id
        if project.isTreeProject { recordProjectVisit(project.id) }
        markActiveTabSeen(projectID: project.id)
        reconnectDroppedRemotePanes(trigger: .projectSelected)
        warmFocusedProject()
        // A project selection changes no tab selection (the poll's usual
        // wake signal), so bump it directly.
        notePollEvent()
    }

    /// Start the shells for every tab of the focused project, not just the
    /// active one — so a multi-tab project (e.g. from a declarative layout) has
    /// all its processes running on open. Other projects stay lazy. The active
    /// tab is created by SwiftUI as usual; the rest are warmed off-screen via
    /// `SurfaceIncubator`.
    func warmFocusedProject() {
        guard let projectID = activeProjectID else { return }
        warmStaggered(Self.panesToWarm(tabs: model.tabs(of: projectID), activeTabID: model.activeTabID(of: projectID)))
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
    static func panesToWarm(tabs: [TerminalTab], activeTabID: UUID?) -> [Pane] {
        tabs
            .filter { $0.id != activeTabID }
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
        guard let projectID = activeProjectID else { return }
        let lost = Self.lostDestinations(model.tabs(of: projectID).flatMap { $0.splitRoot.allPanes() }, destination: destination)
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

    /// Every session name a pane of the model claims, in every project: the
    /// pinned tabs, the quick terminal's and the widgets' panes included
    /// (design/010 §11). The orphan sweep spares these.
    private func claimedSessionNames() -> Set<String> {
        Set(allLivePanes().map(\.sessionName))
    }

    /// The claimed names of LOCAL sessions: `claimedSessionNames` without the
    /// panes of remote projects. A remote project whose host is this Mac
    /// runs its daemon here too, and `endV1SessionsOnce` must not end it.
    private func localSessionNames() -> Set<String> {
        Set(allLivePanes().filter { !$0.isRemote }.map(\.sessionName))
    }

    /// Every pane attached to a session, across ALL workspaces (pinned
    /// included). Workspace panes only: a window's extra surfaces are not
    /// panes.
    private func allLivePanes() -> [Pane] {
        model.allTabs.flatMap { $0.tab.splitRoot.allPanes() }
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
    /// that closes leaves the model, and the server ends its session and
    /// whatever runs in it.
    ///
    /// This is the ONE busy-close predicate. Every path that ends sessions —
    /// pane close, tab close, project remove, the sidebar's bulk
    /// remove, the CLI's `busy` refusal and the Close Tab intent — asks
    /// `judgeClose`, which gives this predicate the hosts' answers for plain
    /// shells.
    ///
    /// `plainAnswers` holds the verdicts that the hosts of plain shells gave
    /// (`askPlainShells`), by pane id. They replace the surface's reading.
    func closeNeedsConfirmation(_ closing: [Pane], plainAnswers: [UUID: Bool] = [:]) -> Bool {
        closing.contains { plainAnswers[$0.id] ?? paneNeedsConfirmClose($0) }
    }

    /// Judges the close of `closing` and gives the verdict to `decide`.
    /// With no plain shell (a host with no server, 0494), `decide` runs at
    /// once. Else the verdict waits for the hosts (`askPlainShells`).
    /// `target` names the request: a second request for a target that is
    /// still judged does nothing.
    func judgeClose(_ closing: [Pane], target: String, _ decide: @escaping @MainActor (Bool) -> Void) {
        let plain = plainShellsToAsk(closing)
        guard !plain.isEmpty else {
            decide(closeNeedsConfirmation(closing))
            return
        }
        guard closesBeingJudged.insert(target).inserted else { return }
        askPlainShells(plain, stopAtBusy: true) { [weak self] answers in
            guard let self else { return }
            closesBeingJudged.remove(target)
            decide(closeNeedsConfirmation(closing, plainAnswers: answers))
        }
    }

    /// The verdict of `judgeClose` for a caller that can wait: the CLI and
    /// the Close Tab intent. It never stores a verdict: each call asks the
    /// hosts again.
    func judgeClose(_ closing: [Pane]) async -> Bool {
        let plain = plainShellsToAsk(closing)
        guard !plain.isEmpty else { return closeNeedsConfirmation(closing) }
        let answers = await withCheckedContinuation { continuation in
            askPlainShells(plain, stopAtBusy: true) { continuation.resume(returning: $0) }
        }
        return closeNeedsConfirmation(closing, plainAnswers: answers)
    }

    /// The panes of `panes` that would end a running program, each by the
    /// same verdict as `judgeClose`, without the retention of pinned tabs:
    /// the rows of the quit dialog.
    func panesThatNeedConfirmClose(_ panes: [Pane]) async -> [Pane] {
        let plain = plainShellsToJudge(panes)
        var answers: [UUID: Bool] = [:]
        if !plain.isEmpty {
            answers = await withCheckedContinuation { continuation in
                askPlainShells(plain, stopAtBusy: false) { continuation.resume(returning: $0) }
            }
        }
        return panes.filter { answers[$0.id] ?? paneNeedsConfirmClose($0) }
    }

    /// The plain shells of `closing` whose verdict counts.
    private func plainShellsToAsk(_ closing: [Pane]) -> [Pane] {
        plainShellsToJudge(closing)
    }

    /// The plain shells of `panes` whose host must answer. Only
    /// `confirm-close-surface = true` asks a host: for `false` and `always`
    /// the surface's reading is the verdict (`ConfirmCloseSurface`).
    private func plainShellsToJudge(_ panes: [Pane]) -> [Pane] {
        guard confirmCloseSurface().judgesPaneState else { return [] }
        return panes.filter(paneRunsPlainShell)
    }

    /// Asks the host of each plain shell in `plain` whether the shell is
    /// idle, all at the same time, and gives the answers to `done` once:
    /// after the last answer, after `plainShellAnswerTimeout`, or, with
    /// `stopAtBusy`, at the first busy answer. A pane with no answer is not
    /// in the result, so it gets the surface's reading, which warns.
    private func askPlainShells(
        _ plain: [Pane],
        stopAtBusy: Bool,
        _ done: @escaping @MainActor ([UUID: Bool]) -> Void
    ) {
        let judgement = CloseJudgement(waiting: Set(plain.map(\.id)))
        let finish: @MainActor () -> Void = {
            guard !judgement.isDone else { return }
            judgement.isDone = true
            judgement.deadline?.cancel()
            done(judgement.answers)
        }
        let ask = askPlainShellNeedsConfirmClose
        let timeout = plainShellAnswerTimeout
        for pane in plain {
            Task { @MainActor in
                let answer = await ask(pane, timeout)
                judgement.record(answer, for: pane.id)
                if (stopAtBusy && answer == true) || judgement.waiting.isEmpty { finish() }
            }
        }
        judgement.deadline = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            finish()
        }
    }

    /// The targets of `judgeClose` that wait for a host.
    @ObservationIgnored
    private var closesBeingJudged: Set<String> = []

    private func panes(inProjects projectIDs: [UUID], tabs: [(tabID: UUID, projectID: UUID)]) -> [Pane] {
        var closing = projectIDs.flatMap(panes(inProject:))
        for tab in tabs {
            guard let tab = model.tabs(of: tab.projectID).first(where: { $0.id == tab.tabID }) else { continue }
            closing += tab.splitRoot.allPanes()
        }
        return closing
    }

    /// Every pane of project `projectID`. Empty for an unknown project.
    func panes(inProject projectID: UUID) -> [Pane] {
        model.tabs(of: projectID).flatMap { $0.splitRoot.allPanes() }
    }

    /// The per-pane half of the verdict — `Pane.needsConfirmClose` in
    /// production. A seam because that property short-circuits on a
    /// missing surface, and no pane in a windowless test ever builds one, so
    /// without it the tab- and project-level guards could only be tested
    /// against an always-idle pane.
    @ObservationIgnored
    var paneNeedsConfirmClose: (Pane) -> Bool = { $0.needsConfirmClose }

    /// The user's `confirm-close-surface` (`GhosttyApp.confirmCloseSurface`),
    /// read at each close. A seam, as `paneNeedsConfirmClose`.
    @ObservationIgnored
    var confirmCloseSurface: () -> ConfirmCloseSurface = { GhosttyApp.shared.confirmCloseSurface }

    /// Whether the pane runs a plain shell (`Pane.runsPlainShell`). A seam,
    /// as `paneNeedsConfirmClose`.
    @ObservationIgnored
    var paneRunsPlainShell: (Pane) -> Bool = { $0.runsPlainShell }

    /// The host's verdict for a plain shell's pane
    /// (`Pane.plainShellNeedsConfirmClose`). nil when it runs none. A seam,
    /// as `paneNeedsConfirmClose`.
    @ObservationIgnored
    var askPlainShellNeedsConfirmClose: (Pane, Duration) async -> Bool? = {
        await $0.plainShellNeedsConfirmClose(timeout: $1)
    }

    /// How long a close waits for the hosts of plain shells, in total. Over
    /// a connection that is up, `ps` answers in well under a second.
    @ObservationIgnored
    var plainShellAnswerTimeout: Duration = .seconds(2)

    /// Shows the folder panel, adds the selected directory as a new project,
    /// and selects it: the Select in Finder row of the New Project screen,
    /// the `+` of Settings → Projects and New Project Inside. Returns the
    /// project, nil if cancelled. With `parent` (New Project Inside), the
    /// panel starts in the folder of `parent` when it is a local folder, and
    /// the new project goes at the end of the projects inside `parent`.
    @discardableResult
    func newProjectFromFolderPanel(store: ProjectStore, inside parent: Project? = nil) -> Project? {
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
        guard let project = store.create(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            parent: parent?.id
        )
        else { return nil }
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
            selected = store.create(name: (path as NSString).lastPathComponent, path: path) ?? selected
        }
        if let selected { selectProject(selected, in: window) }
        return selected
    }

    /// Rename a project from its sidebar row (the inline edit). A name that
    /// `Project.nameRefusal` refuses (a slash, a reserved name) gets a notice
    /// and the old name stays, as `project rename` refuses it with a
    /// `bad_request`. The field has closed by the time the name arrives, so
    /// the notice is the one place left to say why.
    func renameProject(_ projectID: UUID, to name: String, store: ProjectStore) {
        if let message = applyProjectRename(projectID, to: name, store: store) {
            present(.notice(
                .refusedProjectName,
                title: String(localized: "Cannot rename project"),
                message: message,
                host: .mainWindow
            ))
        }
    }

    /// The one check and write of a project rename in the GUI (the sidebar
    /// row and the palette's Rename Current Project). Returns why `name` is
    /// refused, and then changes nothing. Returns nil when the rename is
    /// done or when the name does not change. An unchanged name writes
    /// nothing.
    func applyProjectRename(_ projectID: UUID, to name: String, store: ProjectStore) -> String? {
        if let message = Project.nameRefusal(for: name) { return message }
        guard store.projects.first(where: { $0.id == projectID })?.name != name else { return nil }
        store.rename(id: projectID, to: name)
        return nil
    }

    /// Point every window showing `projectID` at nothing.
    ///
    /// Removal ends the project's shells. A window left showing it would
    /// render a project that no longer exists. The key window follows
    /// through the `activeProjectID` mirror like any other.
    private func vacateWindows(showing projectID: UUID) {
        for window in windows where window.activeProjectID == projectID {
            window.activeProjectID = nil
        }
        if activeProjectID == projectID { activeProjectID = nil }
        settleWindowSelections()
    }

    /// `project.remove`, without the GUI save — so a bulk removal can
    /// persist once for the whole batch. The server ends the sessions of the
    /// project's panes, and refuses a project that is not `removable`
    /// (Pinned, Scratch Tabs, the quick terminal).
    private func removeProjectWithoutSaving(_ projectID: UUID) {
        guard let project = model.project(projectID), project.removable else { return }
        logger.debug("removeProject: \(projectID, privacy: .public)")
        guard writer.projectRemove(projectID) else { return }
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
        persistState()
    }

    /// Remove several projects at once — the bulk sidebar delete. The
    /// deepest go first: the server refuses a project that holds projects.
    /// Saves once for the batch.
    func removeProjects(_ projectIDs: [UUID]) {
        guard !projectIDs.isEmpty else { return }
        for id in projectIDs.reversed() {
            removeProjectWithoutSaving(id)
        }
        persistState()
    }

    /// Remove the project `projectID`, its tabs and every project inside
    /// it, at any depth (design 013 §3, Ethan on ui-review 0522). A project
    /// with no tabs and no projects inside goes at once. Any other project
    /// asks one question with the count of tabs and of nested projects:
    /// Cancel or Remove.
    func requestRemoveProject(_ projectID: UUID, store: ProjectStore, host: DialogHost = .mainWindow) {
        guard let project = store.row(projectID) else { return }
        let removed = projectsRemoved(with: [projectID], store: store)
        let tabs = removed.reduce(0) { $0 + model.tabs(of: $1).count }
        let nested = removed.count - 1
        let removal: @MainActor () -> Void = { [weak self] in
            self?.removeProject(projectID, store: store)
        }
        guard tabs > 0 || nested > 0 else {
            removal()
            return
        }
        judgeClose(panes(inProjects: removed, tabs: []), target: "project:\(projectID)") { [weak self] busy in
            guard let self else { return }
            let message = busy
                ? String(localized: "This project contains \(tabs) tabs and \(nested) nested projects. A process is still running.")
                : String(localized: "This project contains \(tabs) tabs and \(nested) nested projects.")
            present(PendingDialog(
                kind: .removeProject(projectID),
                title: String(localized: "Remove the project “\(project.name)”?"),
                message: message,
                confirmTitle: String(localized: "Remove"),
                host: host,
                onConfirm: removal
            ))
        }
    }

    /// Remove the project `projectID` and every project inside it: their
    /// tabs, their sessions and their rows.
    func removeProject(_ projectID: UUID, store: ProjectStore) {
        guard store.row(projectID) != nil else { return }
        removeProjects(projectsRemoved(with: [projectID], store: store))
    }

    /// The projects that a removal of `selected` removes: each selected
    /// project and every project inside it, once each.
    func projectsRemoved(with selected: [UUID], store: ProjectStore) -> [UUID] {
        var seen = Set<UUID>()
        return selected.flatMap { [$0] + store.descendants(of: $0).map(\.id) }.filter { seen.insert($0).inserted }
    }

    /// A bulk sidebar delete (multi-selection): run `removal` (the caller's
    /// close of `tabs` and removal of the `selected` projects) now, or after
    /// one question for the whole selection. A selected project goes with
    /// everything inside it, as a single Remove does, so the question has
    /// the same counts when a selected project holds tabs or nested
    /// projects. A selection of tabs alone asks only when a process runs.
    func requestRemoveSelection(
        projectIDs selected: [UUID],
        tabs: [(tabID: UUID, projectID: UUID)],
        store: ProjectStore,
        removal: @escaping @MainActor () -> Void
    ) {
        let removed = projectsRemoved(with: selected, store: store)
        let tabCount = removed.reduce(0) { $0 + model.tabs(of: $1).count }
        let selectedSet = Set(selected)
        let nested = removed.count(where: { !selectedSet.isDisjoint(with: store.ancestors(of: $0)) })
        judgeClose(panes(inProjects: removed, tabs: tabs), target: "selection") { [weak self] busy in
            guard let self else { return }
            guard tabCount > 0 || nested > 0 else {
                if busy { confirmRemoveSelection(removal: removal) } else { removal() }
                return
            }
            let message = busy
                ? String(localized: """
                The selected projects contain \(tabCount) tabs and \(nested) nested projects. \
                A process is still running.
                """)
                : String(localized: "The selected projects contain \(tabCount) tabs and \(nested) nested projects.")
            present(PendingDialog(
                kind: .removeSelection,
                title: String(localized: "Remove the selected items?"),
                message: message,
                confirmTitle: String(localized: "Remove"),
                host: .mainWindow,
                onConfirm: removal
            ))
        }
    }

    private func confirmRemoveSelection(removal: @escaping @MainActor () -> Void) {
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
    /// Returns the new tab's ID, nil when the project is not in the model,
    /// holds its one tab already (`singleTab`), or the server refused.
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
        guard model.project(projectID) != nil else { return nil }
        let pane = Pane(projectPath: projectPath, projectID: projectID, sessionSlug: sessionSlug, start: command, env: env)
        guard let tab = writer.tabCreate(in: projectID, root: .pane(pane), focus: focus) else { return nil }
        if !focus {
            for pane in tab.splitRoot.allPanes() {
                warmIfUnrendered(pane, in: tab)
            }
        }
        logger.debug("createTab: project=\(projectID, privacy: .public) tabs=\(self.model.tabs(of: projectID).count, privacy: .public)")
        persistState()
        return tab.id
    }

    /// Creates a tab in the directory `tab-inherit-working-directory` selects.
    /// Active pane falls back to the project path when no local cwd is available.
    /// A project with no folder falls back to home.
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

    /// The configured project root. A project with no folder (Pinned,
    /// Scratch Tabs, a project of a dev build) starts its tabs in home.
    func configuredProjectDirectory(projectID: UUID, projects: [Project]) -> String? {
        guard let project = projects.first(where: { $0.id == projectID }) ?? model.project(projectID) else { return nil }
        return project.hasFolder ? project.path : ProjectPath.currentHome
    }

    /// The teardown half of `closeTab`, without the GUI save — so a bulk
    /// close can persist once for the whole batch.
    private func closeTabWithoutSaving(_ tabID: UUID, projectID: UUID) {
        // Closing a tab that has a pinned record is an unload, not a
        // removal: sessions end, the record (and its pinned.yaml entry)
        // stays as a dimmed row, and the next launch eager-starts it again.
        // Unpin is the removal path.
        if pinnedRecord(tabID) != nil {
            unloadPinnedTab(tabID)
            return
        }
        guard model.tabs(of: projectID).contains(where: { $0.id == tabID }) else { return }
        logger.debug("closeTab: \(tabID, privacy: .public) project=\(projectID, privacy: .public)")
        // The server ends the sessions of the tab's panes.
        writer.tabClose(tabID)
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        closeTabWithoutSaving(tabID, projectID: projectID)
        persistState()
    }

    /// Close several tabs at once — the bulk sidebar delete for tabs. Each is
    /// identified by its owning project since a multi-selection can span
    /// projects. Saves once for the batch.
    func closeTabs(_ tabs: [(tabID: UUID, projectID: UUID)]) {
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            closeTabWithoutSaving(tab.tabID, projectID: tab.projectID)
        }
        persistState()
    }

    /// Close a tab, confirming first when any of its panes has a running
    /// foreground program — closing ends the panes' sessions, so the
    /// destructive-confirmation lives here (quit will detach, not kill).
    func requestCloseTab(_ tabID: UUID, projectID: UUID) {
        guard let tab = model.tabs(of: projectID).first(where: { $0.id == tabID }) else {
            closeTab(tabID, projectID: projectID)
            return
        }
        judgeClose(tab.splitRoot.allPanes(), target: "tab:\(tabID)") { [weak self] needsConfirmation in
            // A wait for a host can end after the tab closed.
            guard let self, model.tabs(of: projectID).contains(where: { $0.id == tabID }) else { return }
            guard needsConfirmation else {
                closeTab(tabID, projectID: projectID)
                return
            }
            confirmCloseTab(tabID, projectID: projectID)
        }
    }

    private func confirmCloseTab(_ tabID: UUID, projectID: UUID) {
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
        // tab), so a record goes through the record-aware path — every
        // caller (sidebar, toolbar switcher, CLI) gets it for free.
        if pinnedRecord(tabID) != nil {
            selectPinnedTab(tabID)
            return
        }
        guard model.tabs(of: projectID).contains(where: { $0.id == tabID }) else { return }
        let before = model.activeTabID(of: projectID)
        writer.tabSelect(tabID, in: projectID)
        if model.activeTabID(of: projectID) != before {
            persistState()
        } else {
            // The tab that a project screen replaced: no change for the hook
            // to see, so end the screen of the window that the hook targets.
            let onProject = windows.filter { $0.activeProjectID == projectID }
            if let target = onProject.first(where: { $0.id == keyWindowID }) ?? onProject.first {
                endProjectScreen(in: target)
            }
        }
    }

    /// Move a tab — with its live panes and running shells intact — to
    /// another project (`tab.move`). No session moves. The destination
    /// becomes the active project with the moved tab selected, so the user
    /// lands where they meant to be. `toIndex` positions the tab within the
    /// destination (a sidebar drop lands at a slot); nil appends. No-op for
    /// a same-project move or an unknown source or tab.
    func moveTab(
        _ tabID: UUID,
        from sourceProjectID: UUID,
        to destProjectID: UUID,
        destPath _: String = "",
        toIndex: Int? = nil
    ) {
        guard sourceProjectID != destProjectID else { return }
        // A move INTO the pinned project is a pin — route through `pinTab`
        // so the declaration is captured and the record inserted. This keeps
        // every drag/menu path a plain `moveTab` call.
        if destProjectID == pinnedProjectID {
            pinTab(tabID, fromProject: sourceProjectID, toRecordIndex: toIndex)
            return
        }
        // An UNLOADED pinned record has no live tab to move; dragging its
        // dimmed row into a project is still an unpin — the drop names where
        // it should spawn.
        if let record = pinnedRecord(tabID), !isPinnedTabLoaded(tabID) {
            unpinUnloadedRecord(record, toProject: destProjectID, toIndex: toIndex)
            return
        }
        guard model.tabs(of: sourceProjectID).contains(where: { $0.id == tabID }) else { return }
        logger.debug(
            "moveTab: \(tabID, privacy: .public) from=\(sourceProjectID, privacy: .public) to=\(destProjectID, privacy: .public)"
        )
        guard writer.tabMove(tabID, to: destProjectID, index: toIndex) else { return }
        // A move OUT of the pinned project is the unpin: the record (and its
        // `pinned.yaml` entry) goes with it.
        removePinnedRecord(forTab: tabID)
        if model.project(destProjectID)?.isSelectable == true {
            activeProjectID = destProjectID
            if model.project(destProjectID)?.isTreeProject == true { recordProjectVisit(destProjectID) }
        }
        persistState()
    }

    /// Merge a tab into the destination project's ACTIVE tab at a resolved
    /// drop target (#227 — dragging a sidebar tab into the window, where
    /// the cursor picks a level: whole-edge, divider, or local pane split).
    /// No-op when the active tab IS the dragged tab.
    func mergeTab(
        _ tabID: UUID,
        from _: UUID,
        at target: TabDropResolution.Target,
        inProject destProjectID: UUID
    ) {
        guard let destTab = model.activeTab(of: destProjectID), destTab.id != tabID else { return }
        // The target pane can vanish mid-drag: the server refuses, and
        // nothing changed.
        guard writer.tabMerge(tabID, into: destTab.id, at: target) else { return }
        // Merging a pinned tab's tree into another tab unpins it — the tab
        // dissolves into the destination.
        removePinnedRecord(forTab: tabID)
        writer.tabSelect(destTab.id, in: destProjectID)
        activeProjectID = destProjectID
        if model.project(destProjectID)?.isTreeProject == true { recordProjectVisit(destProjectID) }
        persistState()
    }

    /// Split a tab apart (#227 — "Separate Panes"): every pane after the first
    /// (in tree order) moves into its own new tab right after the source
    /// tab, and the source keeps only its first pane. The panes keep their
    /// sessions. No-op for a single-pane tab.
    func separateTabPanes(_ tabID: UUID, projectID: UUID) {
        guard let tab = model.tabs(of: projectID).first(where: { $0.id == tabID }) else { return }
        let panes = tab.splitRoot.allPanes()
        guard panes.count > 1 else { return }
        logger.debug("separateTabPanes: \(tabID, privacy: .public) panes=\(panes.count, privacy: .public)")
        // The server puts each new tab right after the source: in reverse,
        // the tabs keep the order of the panes.
        for pane in panes.dropFirst().reversed() {
            writer.paneSeparate(pane.id)
        }
        writer.tabSelect(tabID, in: projectID)
        persistState()
    }

    /// Split a single pane out of its tab into its own new tab — the
    /// per-pane sibling of `separateTabPanes` ("Separate Current Pane"). The
    /// pane keeps its session; the source tab keeps its remaining panes.
    /// `index` is the slot in the destination project's tab list (nil: after
    /// the source in its own project, else at the end). No-op when the pane
    /// isn't in the model or is its tab's only pane.
    func separatePane(_ paneID: UUID, toProject destProjectID: UUID, destPath _: String = "", at index: Int? = nil) {
        guard let (_, sourceTab) = model.locate(pane: paneID),
              sourceTab.splitRoot.allPanes().count > 1
        else { return }
        logger.debug(
            "separatePane: \(paneID, privacy: .public) to=\(destProjectID, privacy: .public) index=\(index ?? -1, privacy: .public)"
        )
        let newTab = UUID()
        guard writer.paneSeparate(paneID, newTab: newTab, in: destProjectID) else { return }
        if let index { writer.tabReorder(newTab, in: destProjectID, toIndex: index) }
        if model.project(destProjectID)?.isSelectable == true {
            activeProjectID = destProjectID
            if model.project(destProjectID)?.isTreeProject == true { recordProjectVisit(destProjectID) }
        }
        persistState()
    }

    /// Reorder a tab within its own project to an absolute drop index (the
    /// offset a sidebar drag-and-drop reports). Persists on a real move.
    func reorderTab(_ tabID: UUID, inProject projectID: UUID, toIndex destination: Int) {
        // A pinned reorder must move the RECORD (the sidebar rows and
        // pinned.yaml follow records, not the live tabs) — the offset
        // arrives in live-tab space here, so translate it.
        if pinnedRecord(tabID) != nil {
            reorderPinnedLiveTab(tabID, toLiveIndex: destination)
            return
        }
        let tabs = model.tabs(of: projectID)
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let to = Self.resolvedMoveIndex(from: from, toDropOffset: destination, count: tabs.count)
        guard to != from else { return }
        writer.tabReorder(tabID, in: projectID, toIndex: to)
        persistState()
    }

    /// Resolve a drag-and-drop insertion offset into the element's final
    /// index. `destination` is in the PRE-removal coordinate space — the
    /// offset SwiftUI's `dropDestination` reports — so it is adjusted down by
    /// one when the element moves toward the end. One home for the
    /// convention: the pinned records reorder speaks it too.
    static func resolvedMoveIndex(from: Int, toDropOffset destination: Int, count: Int) -> Int {
        let clamped = max(0, min(destination, count))
        let to = clamped > from ? clamped - 1 : clamped
        return max(0, min(to, count - 1))
    }

    /// Where Move Tab Up (`step` -1) or Move Tab Down (`step` 1) would put
    /// the active tab, as a drop offset for `reorderTab`, or nil when it is
    /// already at that end. A tab with a pinned record steps through the
    /// RECORDS — the sidebar rows, unloaded ones included — so one keystroke
    /// moves the tab past exactly one row.
    func activeTabMoveOffset(step: Int, projectID: UUID) -> Int? {
        guard let tabID = model.activeTabID(of: projectID) else { return nil }
        let ids = pinnedRecord(tabID) != nil ? pinnedRecords.map(\.id) : model.tabs(of: projectID).map(\.id)
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
              let tabID = model.activeTabID(of: projectID)
        else { return }
        if pinnedRecord(tabID) != nil {
            reorderPinnedTab(tabID, toIndex: offset)
        } else {
            reorderTab(tabID, inProject: projectID, toIndex: offset)
        }
    }

    func selectNextTab(projectID: UUID) {
        stepTab(1, projectID: projectID)
    }

    func selectPreviousTab(projectID: UUID) {
        stepTab(-1, projectID: projectID)
    }

    private func stepTab(_ step: Int, projectID: UUID) {
        // The pinned project cycles in RECORD order — unloaded rows
        // included, restored on landing — so the keyboard walks exactly what
        // the sidebar shows, not just the loaded subset.
        if showsPinnedRecords(projectID) {
            cyclePinnedTab(step: step)
            return
        }
        let tabs = model.tabs(of: projectID)
        guard tabs.count > 1, let active = model.activeTabID(of: projectID),
              let i = tabs.firstIndex(where: { $0.id == active })
        else { return }
        writer.tabSelect(tabs[(i + step + tabs.count) % tabs.count].id, in: projectID)
        persistState()
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
        guard model.project(projectID) != nil else { return }
        // The project screen has no current tab to cycle away from: Recent
        // Tab shows the tab that the screen replaced, with no switcher.
        if let key = keyWindow, key.activeProjectID == projectID, key.showsProjectScreen,
           let current = model.activeTabID(of: projectID)
        {
            selectTab(current, projectID: projectID)
            return
        }
        tabCycler.startIfNeeded(recency: model.recencyOrder(of: projectID), tabs: model.tabs(of: projectID)) { [model] in
            Set(model.allTabs.flatMap { $0.tab.splitRoot.allPanes().map(\.id) })
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
        writer.tabPeek(selected, in: projectID)
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
        guard let selectedID = tabCycler.finish(), model.project(projectID) != nil else { return }
        writer.tabSelect(selectedID, in: projectID)
        persistState()
    }

    enum GlobalTabDirection { case next, previous }

    func selectGlobalTab(_ direction: GlobalTabDirection, projects: [Project]) {
        // Pinned rows cycle first (they sit at the top of the sidebar), in
        // RECORD order — unloaded records included, so keyboard cycling can
        // land on (and restore) a dead pinned tab exactly like clicking it.
        let pinnedEntries: [(projectID: UUID, tabID: UUID)] = pinnedProjectID.map { pinned in
            pinnedRecords.map { (pinned, $0.id) }
        } ?? []
        let projectEntries: [(projectID: UUID, tabID: UUID)] = projects.flatMap { p in
            model.tabs(of: p.id).map { (p.id, $0.id) }
        }
        // The tabs of a project of the bottom section (Scratch Tabs) cycle
        // last: the sidebar draws them below the projects.
        let bottomEntries: [(projectID: UUID, tabID: UUID)] = model.projects.filter { $0.sidebar == .bottom }.flatMap { p in
            model.tabs(of: p.id).map { (p.id, $0.id) }
        }
        let allTabs = pinnedEntries + projectEntries + bottomEntries
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { model.activeTabID(of: $0) }
        let currentIndex =
            allTabs.firstIndex { $0.projectID == activeProjectID && $0.tabID == currentTabID } ?? 0
        let newIndex: Int =
            switch direction {
            case .next: (currentIndex + 1) % allTabs.count
            case .previous: (currentIndex - 1 + allTabs.count) % allTabs.count
            }
        let entry = allTabs[newIndex]
        if pinnedRecord(entry.tabID) != nil {
            // Loads an unloaded record and persists on its own.
            selectPinnedTab(entry.tabID)
            return
        }
        let beforeProjectID = activeProjectID
        let beforeTabID = model.activeTabID(of: entry.projectID)
        activeProjectID = entry.projectID
        writer.tabSelect(entry.tabID, in: entry.projectID)
        if activeProjectID != beforeProjectID || model.activeTabID(of: entry.projectID) != beforeTabID {
            persistState()
        }
    }

    /// Tab slots addressable by Cmd+digit — sidebar ROWS in the pinned
    /// project (records, unloaded included) and live tabs elsewhere, the
    /// same two sources `selectTabByIndex` selects from. It is what bounds
    /// digit accumulation, so the two must keep counting the same things.
    func selectableTabCount(projectID: UUID) -> Int {
        if showsPinnedRecords(projectID) { return pinnedRecords.count }
        return model.tabs(of: projectID).count
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        // Cmd+digit in the pinned project counts SIDEBAR rows (records,
        // unloaded included), matching what the user sees.
        if showsPinnedRecords(projectID) {
            guard pinnedRecords.indices.contains(index) else { return }
            selectPinnedTab(pinnedRecords[index].id)
            return
        }
        let tabs = model.tabs(of: projectID)
        guard tabs.indices.contains(index) else { return }
        let before = model.activeTabID(of: projectID)
        writer.tabSelect(tabs[index].id, in: projectID)
        if model.activeTabID(of: projectID) != before {
            persistState()
        }
    }

    // MARK: - Splits

    /// Splits the focused pane using the user's new split directory preference.
    func splitPane(direction: SplitDirection, projectID: UUID, projects: [Project]) {
        guard let tab = model.activeTab(of: projectID),
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
        guard let pane = model.locate(pane: paneID)?.tab.splitRoot.findPane(id: paneID) else { return nil }
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

    /// The pane that a split of `source` makes: in the source pane's live
    /// cwd (OSC 7, then the kernel's), else its own `projectPath`, unless
    /// `workingDirectory` says otherwise. A REMOTE pane's live cwd is a
    /// folder on the host, so a remote split inherits the scp-style
    /// `projectPath` verbatim. The new pane keeps the source's session slug,
    /// so its session groups with the source's.
    func newSplitPane(
        of source: Pane,
        workingDirectory: String? = nil,
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil
    ) -> Pane {
        let path = workingDirectory ?? source.liveLocalWorkingDirectory() ?? source.projectPath
        return Pane(projectPath: path, projectID: source.projectID, sessionSlug: source.sessionSlug, start: command, env: env)
    }

    /// Split a SPECIFIC pane — found in whichever tab holds it, unlike the
    /// focused-pane overload above — optionally spawning `command` in the new
    /// pane. The control CLI's split path. Returns the new pane's ID.
    /// `focus: false` preserves focus/history/zoom and warms the new pane,
    /// including when its tab or project isn't being displayed.
    @discardableResult
    func splitPane(
        _ paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition = .second,
        projectID _: UUID,
        command: PaneStartCommand? = nil,
        env: [String: String]? = nil,
        newPaneWorkingDirectory: String? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard let tab = model.locate(pane: paneID)?.tab, let source = tab.splitRoot.findPane(id: paneID) else { return nil }
        let pane = newSplitPane(of: source, workingDirectory: newPaneWorkingDirectory, command: command, env: env)
        let newID = writer.paneSplit(
            tab: tab.id,
            target: paneID,
            new: pane,
            direction: direction,
            position: position,
            focus: focus
        )
        if !focus, newID != nil {
            warmIfUnrendered(pane, in: tab)
        }
        persistState()
        return newID
    }

    /// Split a pane into an equal `rows`×`columns` grid (`pane.grid`),
    /// spawning `command` in each new pane. The source pane is the top-left
    /// cell and keeps the focus. Every cell honors the new split directory
    /// preference, so a grid and a `Cmd+D` split off the same pane can't
    /// disagree about it. Returns the new pane IDs.
    @discardableResult
    func makeGrid(
        _ paneID: UUID,
        rows: Int,
        columns: Int,
        projectID: UUID,
        projectDirectory: String,
        command: PaneStartCommand? = nil
    ) -> [UUID] {
        guard rows >= 1, columns >= 1, rows * columns > 1,
              let tab = model.locate(pane: paneID)?.tab,
              let source = tab.splitRoot.findPane(id: paneID)
        else { return [] }
        let newPaneDirectory = NewTerminalWorkingDirectory(inherits: newSplitInheritsWorkingDirectory()).resolveNewTerminalDirectory(
            projectDirectory: projectDirectory,
            activePaneDirectory: source.liveLocalWorkingDirectory()
        )
        _ = projectID
        let panes = (1 ..< rows * columns).map { _ in
            newSplitPane(of: source, workingDirectory: newPaneDirectory, command: command)
        }
        // One request: the server makes the whole grid or nothing.
        guard writer.paneGrid(tab: tab.id, target: paneID, rows: rows, columns: columns, new: panes) else { return [] }
        persistState()
        return panes.map(\.id)
    }

    /// Split the focused pane along its longer on-screen axis (Ghostty's
    /// `new_split` / BSP behavior), measured where the user sees it
    /// (`displayedSize`).
    func autoSplitPane(projectID: UUID, projects: [Project]) {
        guard let tab = model.activeTab(of: projectID),
              let paneID = tab.focusedPaneID,
              let pane = tab.focusedPane,
              let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects)
        else { return }
        let newPaneDirectory = NewTerminalWorkingDirectory(inherits: newSplitInheritsWorkingDirectory()).resolveNewTerminalDirectory(
            projectDirectory: projectDirectory,
            activePaneDirectory: pane.liveLocalWorkingDirectory()
        )
        writer.paneSplit(
            tab: tab.id,
            target: paneID,
            new: newSplitPane(of: pane, workingDirectory: newPaneDirectory),
            direction: SplitDirection.auto(for: displayedSize(of: pane))
        )
        persistState()
    }

    func resizePane(_ direction: PaneFocusDirection, projectID: UUID, delta: CGFloat = 0.03) {
        if let tab = model.activeTab(of: projectID) {
            splitResize(tab, direction: direction, delta: delta)
        }
        persistState()
    }

    /// Resize Split Left/Right/Up/Down: a relative, animated `split.ratio`
    /// of the nearest split of that axis around the focused pane.
    func splitResize(_ tab: TerminalTab, direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        guard let paneID = tab.focusedPaneID,
              let (branch, ratio) = tab.splitRoot.resizedRatio(paneID: paneID, direction: direction, delta: delta)
        else { return }
        writer.splitRatio(branch, ratio: ratio, animated: true)
    }

    /// Move Pane: swap the focused pane with its neighbor in `direction` —
    /// the pane that Focus Left/Right/Up/Down would go to.
    @discardableResult
    func swapFocusedPane(_ tab: TerminalTab, direction: PaneFocusDirection) -> Bool {
        guard let paneID = tab.focusedPaneID,
              let neighborID = tab.splitRoot.nearestPane(from: paneID, direction: direction)
        else { return false }
        return writer.paneSwap(paneID, with: neighborID)
    }

    func toggleZoom(projectID: UUID) {
        guard let tab = model.activeTab(of: projectID),
              let paneID = tab.focusedPaneID
        else { return }
        writer.paneZoom(tab: tab.id, pane: tab.zoomedPaneID == paneID ? nil : paneID)
    }

    func closePane(_ paneID: UUID, projectID: UUID) {
        guard let tab = model.locate(pane: paneID)?.tab else { return }
        // Closing a pinned tab's LAST pane closes the tab, which for a tab
        // with a pinned record is an unload (record kept).
        if tab.splitRoot.allPanes().count <= 1 {
            closeTab(tab.id, projectID: projectID)
            return
        }
        logger.debug("closePane: \(paneID, privacy: .public) project=\(projectID, privacy: .public)")
        // The server ends the pane's session.
        writer.paneClose(paneID)
        persistState()
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
        guard let (_, tab) = model.locate(pane: paneID), let pane = tab.splitRoot.findPane(id: paneID),
              pane.isRemote, pinnedRecord(tab.id) == nil
        else {
            paneProcessExited(paneID, projectID: projectID)
            return
        }
        logger.info("remote pane client ended — closing the pane")
        closePane(paneID, projectID: projectID)
    }

    func requestClosePane(_ paneID: UUID, projectID: UUID) {
        guard let pane = model.pane(paneID) else {
            closePane(paneID, projectID: projectID)
            return
        }
        judgeClose([pane], target: "pane:\(paneID)") { [weak self] needsConfirmation in
            // A wait for a host can end after the pane closed.
            guard let self, model.pane(paneID) != nil else { return }
            guard needsConfirmation else {
                closePane(paneID, projectID: projectID)
                return
            }
            confirmClosePane(paneID, projectID: projectID)
        }
    }

    private func confirmClosePane(_ paneID: UUID, projectID: UUID) {
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
            tabs: model.tabs(of: project.id),
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
        let tabs = model.tabs(of: project.id)
        do {
            let layout = LayoutSerializer.layout(tabs: tabs, projectName: project.name, projectRoot: project.path)
            let saved = try layoutFiles.save(layout, for: project, siblingProjects: siblingProjects)
            logger.info("saveLayout succeeded: tabs=\(tabs.count, privacy: .public)")
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
        let existing = Set(model.tabs(of: projectID).map(\.id))
        var order: [UUID] = []
        for planned in plan.tabs {
            if let id = planned.existingTabID, existing.contains(id) {
                // The tab keeps its id; its tree changes. A pane that the new
                // tree does not hold leaves the model, and the server ends its
                // session.
                writer.tabLayout(id, root: planned.root, focusedPaneID: planned.focusedPaneID)
                writer.tabSet(id, title: planned.title)
                order.append(id)
            } else if let tab = writer.tabCreate(in: projectID, root: planned.root, title: planned.title, focus: false) {
                order.append(tab.id)
            }
        }
        for id in plan.tabsToClose {
            writer.tabClose(id)
        }
        for (index, id) in order.enumerated() where model.tabs(of: projectID).firstIndex(where: { $0.id == id }) != index {
            writer.tabReorder(id, in: projectID, toIndex: index)
        }
        if let first = order.first { writer.tabSelect(first, in: projectID) }
        activeProjectID = projectID
        persistState()

        // Focus the declared/active pane once its surface attaches to a window.
        if let tab = order.first.flatMap(model.tab), let paneID = tab.focusedPaneID {
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
        guard let tab = model.locate(pane: paneID)?.tab else { return }
        _ = projectID
        writer.paneFocus(paneID)
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
        guard let pane = model.pane(paneID) else { return }
        _ = projectID
        let surface = SurfaceRegistry.shared.surface(for: pane, in: Self.host(windowID))
        guard surface.adaptiveBackgroundColor != color else { return }
        surface.adaptiveBackgroundColor = color
    }

    /// Begin the sidebar rename flow for the tab containing `paneID` — the
    /// ghostty `prompt_surface_title` keybind's Macterm mapping (titles live
    /// on tabs here, not surfaces). No-op for panes outside any workspace
    /// (the quick terminal has no tab UI to rename).
    func renameTab(containing paneID: UUID, projectID: UUID) {
        guard let tab = model.tabs(of: projectID).first(where: { $0.splitRoot.contains(paneID: paneID) })
        else { return }
        sidebarVisible = true
        let tabID = tab.id
        // Defer a tick so the sidebar row's TextField exists before it's asked
        // to begin editing.
        DispatchQueue.main.async { self.renamingTabID = tabID }
    }

    /// Set (or, with nil, clear) the custom title of the tab containing
    /// `paneID` — the ghostty `set_tab_title` keybind's Macterm mapping,
    /// writing the same field the sidebar rename edits.
    func setTabTitle(containing paneID: UUID, projectID: UUID, title: String?) {
        guard let tab = model.tabs(of: projectID).first(where: { $0.splitRoot.contains(paneID: paneID) })
        else { return }
        setTabTitle(tab, title: title)
    }

    /// The one write of a tab's custom title from the GUI (the sidebar row,
    /// the palette's Rename Current Tab, the ghostty keybind). nil gives back
    /// the automatic title.
    func setTabTitle(_ tab: TerminalTab, title: String?) {
        writer.tabSet(tab.id, title: title)
        persistState()
    }

    func navigateToPane(_ paneID: UUID, projectID: UUID) {
        guard model.project(projectID)?.isSelectable == true else {
            NSApp.activate()
            appDelegate?.reopenIfNeeded()
            return
        }
        revealProject(projectID)
        if model.project(projectID)?.isTreeProject == true { recordProjectVisit(projectID) }
        if let tab = model.tabs(of: projectID).first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
            let beforeTabID = model.activeTabID(of: projectID)
            let beforeFocusedPaneID = tab.focusedPaneID
            writer.tabSelect(tab.id, in: projectID)
            writer.paneFocus(paneID)
            if model.activeTabID(of: projectID) != beforeTabID
                || tab.focusedPaneID != beforeFocusedPaneID
            {
                persistState()
            }
        }
        appDelegate?.reopenIfNeeded()
        NSApp.activate()
        if let tab = model.tabs(of: projectID).first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
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
        model.activeTab(of: projectID)?.focusedPane
    }

    // MARK: - Pane focus navigation

    func focusPaneInDirection(_ direction: PaneFocusDirection, projectID: UUID) {
        guard let tab = model.activeTab(of: projectID),
              let focusedID = tab.focusedPaneID
        else { return }
        if let bestID = tab.splitRoot.nearestPane(from: focusedID, direction: direction) {
            writer.paneFocus(bestID)
        }
    }

    /// Swap the focused pane with its neighbor in `direction` (Move Pane
    /// Left/Right/Up/Down). The neighbor is the pane that Focus in the same
    /// direction would go to. Shells and focus stay with their panes.
    func moveFocusedPane(_ direction: PaneFocusDirection, projectID: UUID) {
        guard let tab = model.activeTab(of: projectID), swapFocusedPane(tab, direction: direction) else { return }
        persistState()
    }

    /// Whether Move Pane in `direction` has a pane to swap with.
    func canMoveFocusedPane(_ direction: PaneFocusDirection, projectID: UUID) -> Bool {
        guard let tab = model.activeTab(of: projectID), let paneID = tab.focusedPaneID else { return false }
        return tab.splitRoot.nearestPane(from: paneID, direction: direction) != nil
    }

    /// Cycle focus through the active tab's panes in tree order, wrapping at
    /// the ends. `forward` moves to the next pane; otherwise the previous.
    func cyclePane(forward: Bool, projectID: UUID) {
        guard let tab = model.activeTab(of: projectID) else { return }
        let panes = tab.splitRoot.allPanes()
        guard panes.count > 1 else { return }
        let current = tab.focusedPaneID.flatMap { id in panes.firstIndex(where: { $0.id == id }) } ?? 0
        let step = forward ? 1 : -1
        let next = panes[(current + step + panes.count) % panes.count]
        writer.paneFocus(next.id)
    }

    // MARK: - Project navigation

    func selectNextProject(projects: [Project]) {
        stepProject(1, projects: projects)
    }

    func selectPreviousProject(projects: [Project]) {
        stepProject(-1, projects: projects)
    }

    /// Project cycling treats the project of the top section (Pinned) as a
    /// slot ABOVE the first project and the project of the bottom section
    /// (Scratch Tabs) as a slot BELOW the last (where the sidebar draws
    /// them) — without it, the keyboard could enter a section but never
    /// leave it. `projects` is in tree order, so every project, with a
    /// folder or not, is a slot in the order of the sidebar. A section
    /// project is a slot only while the sidebar draws it.
    private func stepProject(_ step: Int, projects: [Project]) {
        var slots = projects.map(\.id)
        if let pinned = pinnedProjectID, !pinnedRecords.isEmpty {
            slots.insert(pinned, at: 0)
        }
        for bottom in model.projects where bottom.sidebar == .bottom && !model.tabs(of: bottom.id).isEmpty {
            slots.append(bottom.id)
        }
        guard slots.count > 1, let current = activeProjectID,
              let i = slots.firstIndex(of: current)
        else { return }
        let target = slots[(i + step + slots.count) % slots.count]
        if showsPinnedRecords(target) {
            selectPinnedProject()
        } else if let project = projects.first(where: { $0.id == target }) ?? model.project(target) {
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
        guard let tab = model.activeTab(of: projectID),
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
        model.activeTab(of: projectID)?.markSeen()
    }

    /// Marks the active tab seen when it holds `paneID`, the app is active,
    /// and the key window draws the pane (`paneIsInKeyWindow`). Reads
    /// `isAppActive`, not `NSApp.isActive`: NSApp is nil during init
    /// (`pollNow`) and in tests.
    func markSeenIfActive(paneID: UUID, projectID: UUID) {
        guard isAppActive(),
              projectID == activeProjectID,
              let tab = model.activeTab(of: projectID),
              let pane = tab.splitRoot.findPane(id: paneID),
              paneIsInKeyWindow(pane)
        else { return }
        tab.markSeen()
    }

    /// A project that was just added gets its first tab at once, so that
    /// no project with a folder is without tabs (design 010 section 11).
    /// `ProjectStore.onAdd` calls it for every path that adds a project
    /// (`MactermApp` connects the two).
    func projectAdded(_ project: Project) {
        guard model.tabs(of: project.id).isEmpty, project.hasFolder else { return }
        createTab(projectID: project.id, projectPath: project.path)
    }
}

/// The answers of one `AppState.askPlainShells`.
@MainActor
private final class CloseJudgement {
    /// The panes whose host has not answered yet.
    private(set) var waiting: Set<UUID>
    /// The verdict of each pane whose host answered.
    private(set) var answers: [UUID: Bool] = [:]
    var isDone = false
    var deadline: Task<Void, Never>?

    init(waiting: Set<UUID>) {
        self.waiting = waiting
    }

    func record(_ answer: Bool?, for pane: UUID) {
        waiting.remove(pane)
        if let answer { answers[pane] = answer }
    }
}
