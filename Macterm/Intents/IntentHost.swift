import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "IntentHost")

/// The one way an App Intent reaches the running app.
///
/// An intent is instantiated by the system, not by us, so it has no way to be
/// handed `AppState` — and it can arrive at the worst possible moment: running
/// a shortcut launches Macterm, and the system delivers `perform()` as soon as
/// the process is up, which can be before `MainWindow` has handed the delegate
/// its state objects and before the launch task has restored the selection.
/// Acting then would either find no state at all or have `restoreSelection`
/// overwrite whatever the intent just selected. So this is the same shape as
/// `FinderServiceProvider`: the delegate `attach`es its objects from
/// `installResponders`, and readiness additionally waits on
/// `AppState.performWhenRestored` — the hook any launch-time external request
/// uses.
///
/// The difference from the Finder service is that an intent has to *return* a
/// result, so it cannot park a closure and walk away: `context()` awaits
/// readiness instead. The wait is bounded, because a launch that never fronts
/// the app builds no window and may never install responders (#241) — an
/// intent hanging forever there would wedge the shortcut with no error, so a
/// deadline turns it into `.appUnavailable`.
@MainActor
final class MactermIntentHost {
    static let shared = MactermIntentHost()

    /// How long an intent waits for the app to finish launching before giving
    /// up. Generous, because a cold launch does libghostty init, a config
    /// load and a workspace restore before `restoreWindows` runs.
    static let readinessTimeout: TimeInterval = 20
    private static let pollInterval = Duration.milliseconds(50)

    private weak var appState: AppState?
    private weak var projectStore: ProjectStore?
    /// True once the state objects exist AND the launch restore has run.
    private(set) var isReady = false
    /// The project memory that `GetMactermProjectMemoryIntent` reads. A
    /// closure, so a test can hand in a memory on a temporary store without
    /// starting the shared one.
    var projectMemory: () -> ProjectMemory = { .shared }

    private init() {}

    /// Hand the host its targets once they exist (from
    /// `AppDelegate.installResponders`). Readiness is deferred to the restore
    /// rather than announced here.
    func attach(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
        appState.performWhenRestored { [weak self] in
            self?.isReady = true
            logger.debug("intent host ready")
        }
    }

    /// Test seam: pretend the launch is done with these objects.
    func attachForTesting(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
        isReady = true
    }

    /// The app's state objects, waiting out the launch if it is still going.
    ///
    /// A deadline poll rather than a continuation: the readiness flag is set
    /// from a `performWhenRestored` closure that cannot itself be cancelled or
    /// timed out, and the repo's own convention for a bounded wait is a loop
    /// that *sleeps* (a `Task.yield()` loop starves the main-actor timers it
    /// is waiting on).
    func context() async throws -> AppCommandContext {
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while !isReady, Date() < deadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
        guard isReady, let appState, let projectStore else {
            logger.warning("intent gave up waiting for the app to become ready")
            throw MactermIntentError.appUnavailable
        }
        return AppCommandContext(appState: appState, projectStore: projectStore)
    }

    /// The entry point every `perform()` shares: check the permission gate,
    /// then hand over the state objects. Permission is checked BEFORE the wait
    /// so a denied intent fails at once instead of after a launch.
    func authorizedContext() async throws -> AppCommandContext {
        try IntentPermissionGate.shared.authorize()
        return try await context()
    }
}

/// Locating the thing an entity names. Entities carry an identity and nothing
/// else — deliberately, so they are tokens rather than handles: a saved
/// shortcut can name a tab that has since closed, and every lookup has to be
/// able to say so. `ControlHandler`'s resolution is not reused because it
/// speaks a different language (a selector string that may be a name, a
/// 1-based index or a UUID); here the identity is exact and the only question
/// is whether it is still live.
@MainActor
enum IntentTargets {
    /// Where a pane sits: the workspace that routes to it and the tab that
    /// draws it, both of which the acting intents need (focus selects the tab,
    /// close asks the tab whether anything is running).
    struct PaneLocation {
        let projectID: UUID
        let tab: TerminalTab
        let pane: Pane
    }

    /// A project by id that Shortcuts may address (`isShortcutTarget`):
    /// Pinned and Scratch Tabs included.
    static func project(_ id: UUID, in ctx: AppCommandContext) throws -> Project {
        guard let project = ctx.appState.model.project(id), isShortcutTarget(project, in: ctx) else {
            throw MactermIntentError.notFound
        }
        return project
    }

    /// The Shortcuts rule (design/010 §11, §2): a project that a window can
    /// show, of the tree or with a tab. The quick terminal and the widgets
    /// never are.
    static func isShortcutTarget(_ project: Project, in ctx: AppCommandContext) -> Bool {
        guard project.isSelectable else { return false }
        if project.isTreeProject { return true }
        return !ctx.appState.model.tabs(of: project.id).isEmpty
            || (project.sidebar == .top && !ctx.appState.pinnedRecords.isEmpty)
    }

    /// Show a project and front its window — what Focus Project and the
    /// Spotlight open both do.
    static func focusProject(_ id: UUID, in ctx: AppCommandContext) throws {
        let target = try project(id, in: ctx)
        // `revealProject` fronts a window ALREADY showing it rather than
        // repointing whichever window happens to be key — the rule for
        // something that happens *to* a project rather than being chosen in a
        // window (a notification click, the CLI's `pane focus`), which is
        // exactly the shape of an intent arriving from outside.
        ctx.appState.appDelegate?.showWindow()
        if target.isTreeProject {
            ctx.appState.revealProject(target.id)
        } else {
            ctx.appState.select(project: target)
        }
    }

    /// Whether a pane of this project is one the pane entities can name:
    /// the quick terminal's panes and the desktop widgets' panes are not.
    static func isAddressablePane(projectID: UUID, in ctx: AppCommandContext) -> Bool {
        ctx.appState.model.project(projectID)?.isSelectable == true
    }

    /// A tab by id, in any project a window can show — a `TabEntity`
    /// carries no project, and a tab can be moved between projects after the
    /// shortcut was written.
    static func tab(_ id: UUID, in ctx: AppCommandContext) throws -> (projectID: UUID, tab: TerminalTab) {
        guard let tab = ctx.appState.model.tab(id),
              let projectID = ctx.appState.model.projectID(ofTab: id),
              isAddressablePane(projectID: projectID, in: ctx)
        else { throw MactermIntentError.notFound }
        return (projectID, tab)
    }

    /// A pane by zmx session name — the restart-stable identity (`Pane.id` is
    /// regenerated on every restore, so a shortcut keyed on it would break at
    /// the first relaunch). One pane is one session.
    static func pane(session: String, in ctx: AppCommandContext) throws -> PaneLocation {
        guard let match = allPanes(in: ctx).first(where: { $0.pane.sessionName == session }) else {
            throw MactermIntentError.notFound
        }
        return match
    }

    /// Every live pane, for the entity queries and the lookup above.
    /// Deterministic order (project list order, then tab order, then tree
    /// order) so the Shortcuts picker doesn't reshuffle between openings.
    static func allPanes(in ctx: AppCommandContext) -> [PaneLocation] {
        var result: [PaneLocation] = []
        for projectID in orderedProjectIDs(in: ctx) {
            for tab in ctx.appState.model.tabs(of: projectID) {
                for pane in tab.splitRoot.allPanes() {
                    result.append(PaneLocation(projectID: projectID, tab: tab, pane: pane))
                }
            }
        }
        return result
    }

    static func allTabs(in ctx: AppCommandContext) -> [(projectID: UUID, tab: TerminalTab)] {
        orderedProjectIDs(in: ctx).flatMap { projectID in
            ctx.appState.model.tabs(of: projectID).map { (projectID, $0) }
        }
    }

    /// The projects of the top section first (Pinned), then the projects in
    /// sidebar order, then the bottom section (Scratch Tabs) — the order the
    /// sidebar itself draws, so a picker reads the same way. Only the
    /// projects that Shortcuts may address (`isShortcutTarget`).
    static func orderedProjectIDs(in ctx: AppCommandContext) -> [UUID] {
        let model = ctx.appState.model
        let sections = { (sidebar: MactermProtocol.ProjectSidebar) in
            model.projects.filter { $0.sidebar == sidebar && isShortcutTarget($0, in: ctx) }.map(\.id)
        }
        return sections(.top) + ctx.projectStore.projects.map(\.id) + sections(.bottom)
    }

    /// What the sidebar calls the project a tab belongs to — used for a tab's
    /// and pane's subtitle in a picker, where a bare tab title ("nu") says
    /// nothing about which project it is in.
    static func projectName(_ projectID: UUID, in ctx: AppCommandContext) -> String? {
        ctx.appState.model.project(projectID)?.name
    }
}
