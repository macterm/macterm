import AppKit
import Foundation
import Observation

/// One terminal window's own selection state (#345).
///
/// Macterm was single-window, so "which project is showing" lived on `AppState`
/// as a single `activeProjectID`. With several windows that value has to mean
/// two different things at once — what THIS window renders, and what the app
/// as a whole considers frontmost (which drives polling cadence, remote
/// foreground probes, and which project gets its shells warmed).
///
/// They are split rather than duplicated: this type owns the per-window answer,
/// and `AppState.activeProjectID` becomes a mirror of whichever window is key.
/// That keeps every existing "the frontmost project" call site correct as
/// written — there are far more of those than there are genuine selection
/// sites — while the views that render a specific window read this instead.
///
/// Deliberately NOT a place for tab or pane selection yet. `Workspace`
/// activeTabID and `TerminalTab.focusedPaneID` stay shared, so two windows
/// showing the SAME project still share a selected tab. That is a real
/// limitation, and not the case #345 asks for: its motivation is one project
/// per Space, where the windows show different projects and never collide.
@MainActor
@Observable
final class WindowState: Identifiable {
    let id = UUID()

    /// The project this window is showing. Independent per window — that is
    /// the whole point. A project that becomes active opens its sidebar
    /// section, so the user sees the tab they are in.
    var activeProjectID: UUID? {
        didSet {
            guard activeProjectID != oldValue else { return }
            showsProjectScreen = false
            expandActiveProject()
        }
    }

    /// Whether this window shows the project screen (`EmptyProjectView`) of
    /// `activeProjectID` in place of a tab, also when the project has tabs.
    /// `AppState.showProjectScreen` sets it. A change of project clears it.
    /// Saved as `WindowSnapshot.showsProjectScreen`.
    var showsProjectScreen = false

    /// The rows whose sidebar sections are open in this window: projects and
    /// groups (design 013). The saved key keeps its old name.
    ///
    /// Per window, and persisted (`WindowSnapshot.expandedProjectIDs`), so a
    /// relaunch keeps each section open or closed as the user left it. It
    /// lived on the sidebar's view state before, which the next launch built
    /// empty: every project except the active one came back closed.
    ///
    /// Model state and not view state because the restore writes it before
    /// the sidebar builds, and the active-project rule above must run in the
    /// same order as the restore: project first, then the saved set over it.
    /// A saved set that closed the active project therefore stays closed.
    var expandedRows: Set<UUID> = []

    /// The sidebar's selection, rename draft and row order. On the window,
    /// not on a view, because commands read the selection as their target
    /// (`AppState.commandTarget(store:)`, design 013 §2.1). Both copies of
    /// the sidebar (native and overlay) share it.
    @ObservationIgnored
    let sidebar = SidebarPresentationState()

    /// Whether the focus of this window is in its sidebar: the first
    /// responder is the outline view of the sidebar's `List`. Observed, so
    /// that a menu item whose title follows the command target updates when
    /// the focus moves (`AppState.commandTarget(store:)`). `watchFocus(of:)`
    /// keeps it current.
    var sidebarHasFocus = false

    @ObservationIgnored
    private var focusObservation: NSKeyValueObservation?

    /// Follow the first responder of `nsWindow` into `sidebarHasFocus`.
    /// Nothing else in a main window is an outline view.
    func watchFocus(of nsWindow: NSWindow) {
        sidebarHasFocus = nsWindow.firstResponder is NSOutlineView
        focusObservation = nsWindow.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                let focused = window.firstResponder is NSOutlineView
                if self?.sidebarHasFocus != focused { self?.sidebarHasFocus = focused }
            }
        }
    }

    /// The nodes that a command from the palette acts on, recorded when the
    /// palette opens, before it takes the focus from the sidebar
    /// (`AppState.commandTarget(store:)`). nil while the palette is closed.
    @ObservationIgnored
    var paletteTarget: [SidebarItem]?

    /// The tab this window shows for each project it has visited, keyed by
    /// project id.
    ///
    /// Per window so that two windows can show different tabs of one project.
    /// `Workspace.activeTabID` stays the KEY window's selection — a mirror of
    /// this map, the same shape as `AppState.activeProjectID` — so every "the
    /// tab the user is working in" call site keeps working unchanged. Two
    /// windows that select one tab draw the same panes, each with a surface of
    /// its own (`SurfaceRegistry.surface(for:in:)`).
    var activeTabIDs: [UUID: UUID] = [:]

    /// This window's sidebar width.
    ///
    /// Per window because the restore is ours to do — SwiftUI's own column
    /// autosave writes under a name built from a runtime address and can never
    /// read it back, and `navigationSplitViewColumnWidth`'s `ideal:` is only a
    /// preference AppKit was measured to ignore. Since we restore it by hand
    /// anyway, doing so per window costs nothing extra.
    ///
    /// Seeded from `Preferences.sidebarWidth`, which stays the app-wide
    /// default a NEW window opens at.
    var sidebarWidth: Double

    /// Presentation state that is one-per-window. These used to live on
    /// `AppState`, which was the same thing with one window; with several,
    /// every `MainWindow` rendered them, so ⌘K raised a palette in every
    /// window, the New Remote Project sheet presented on all of them, and
    /// toggling one sidebar toggled every sidebar. `AppState` keeps mirrors
    /// of the key window's copy for the app-wide code paths (hotkeys, palette
    /// commands, the CLI) that mean "the window the user is in".
    var sidebarVisible = true

    /// Whether this window shows the Project Insights panel
    /// (`ProjectMemoryPanel`). Each window opens and closes it on its own.
    /// It is saved as `WindowSnapshot.projectMemoryPanelVisible`. Toggle
    /// Project Insights changes the key window's value through
    /// `AppState.projectMemoryPanelVisible`.
    var projectMemoryPanelVisible = false

    /// This window's frame, as AppKit's `frameDescriptor` — what the next
    /// launch reopens it at (`WindowSnapshot.frame`). Written on every move
    /// and resize outside full screen, so it holds the windowed frame while
    /// the window is full screen. Unobserved: nothing renders from it, and a
    /// live resize would otherwise invalidate the window's views per event.
    @ObservationIgnored
    var frame: String?

    var isCommandPaletteVisible = false {
        didSet { if !isCommandPaletteVisible { paletteTarget = nil } }
    }

    /// The view the palette and its breadcrumb row are drawn over while the
    /// palette is up — what Capture Palette frames
    /// (`PaletteScreenshot`). Unobserved; the palette sets it as it mounts.
    @ObservationIgnored
    weak var paletteAnchor: NSView?
    /// The palette screens showing (`PaletteScope`), root first; empty is
    /// the root itself. Every push and pop goes through the methods below,
    /// which own a frame's end of life (`PaletteScope.deactivate`); the
    /// panel owns its start, since activation needs the palette's context.
    /// Emptied whenever the palette closes.
    private(set) var paletteStack: [PaletteFrame] = []

    /// The screen on top, nil on the root.
    var paletteScope: PaletteScopeID? { paletteStack.last?.scopeID }

    /// Opens `frame` over whatever is showing.
    func pushPaletteFrame(_ frame: PaletteFrame) {
        paletteStack.append(frame)
    }

    /// Back one screen; nothing on the root.
    func popPaletteFrame() {
        guard let frame = paletteStack.popLast() else { return }
        frame.scope.deactivate()
    }

    /// Back to the frame at `index`, which stays — a click on its pill.
    func popPaletteFrames(above index: Int) {
        guard index >= 0, index < paletteStack.count - 1 else { return }
        let popped = paletteStack[(index + 1)...]
        paletteStack.removeSubrange((index + 1)...)
        popped.forEach { $0.scope.deactivate() }
    }

    /// Shows `scope` alone — a screen's own chord, from wherever the
    /// palette was — or the root for nil.
    func showPaletteScope(_ scope: PaletteScopeID?) {
        resetPaletteStack()
        if let scope {
            paletteStack = [PaletteFrame(scope)]
        }
    }

    /// Back to the root.
    func resetPaletteStack() {
        let popped = paletteStack
        paletteStack = []
        popped.forEach { $0.scope.deactivate() }
    }

    var isNewRemoteProjectSheetPresented = false
    /// The fields that the palette filled in for the sheet: it checks them
    /// at once. nil: the sheet opens empty.
    var newRemoteProjectDraft: NewRemoteProjectDraft?
    /// The password editor sheet up in this window — the palette's Password
    /// Manager adding an entry.
    var passwordEditor: PasswordEditorRequest?

    init(activeProjectID: UUID? = nil, sidebarWidth: Double? = nil) {
        self.activeProjectID = activeProjectID
        self.sidebarWidth = sidebarWidth ?? Preferences.shared.sidebarWidth
        expandActiveProject()
    }

    /// The pinned workspace has no section to open.
    private func expandActiveProject() {
        guard let activeProjectID, activeProjectID != PinnedTabs.workspaceID else { return }
        expandedRows.insert(activeProjectID)
    }
}
