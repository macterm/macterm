import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ScratchTabs")

/// Scratch tabs (#665): the hidden project with the alias `scratch`
/// (design/010 §11), below the projects. It holds ordinary tabs that belong
/// to no project.
///
/// The rules, in one place:
/// - It is a project of the model. Selection, per-window tab selection,
///   mirrors, moves, merges and reorders all take the generic path. The app
///   makes it EMPTY at the first need: a tab there is one that someone asked
///   for.
/// - Closing a scratch tab is a close, not an unload. Nothing declares a
///   scratch tab outside the model, and a dead one leaves no row.
/// - A move into it is a plain `moveTab`. A move out of it, to a project or
///   to the pinned project, is the same move or a pin.
extension AppState {
    // MARK: - Queries

    /// The scratch project, found by its alias. Nil until the first scratch
    /// tab.
    var scratchProjectID: UUID? { model.project(alias: ScratchTabs.alias)?.id }

    /// Whether the sidebar has scratch rows to draw.
    var hasScratchTabs: Bool { scratchProjectID.map { !model.tabs(of: $0).isEmpty } ?? false }

    /// The scratch project, made at the first need.
    @discardableResult
    func ensureScratchProject() -> UUID? {
        if let id = scratchProjectID { return id }
        let project = ScratchTabs.newProject()
        guard writer.projectCreate(project) else { return nil }
        return project.id
    }

    // MARK: - Selection

    /// Select the scratch project itself (the sidebar's Scratch Tabs header),
    /// in `window`, or app-wide when none is given.
    func selectScratchTabs(in window: WindowState? = nil) {
        guard let id = ensureScratchProject(), let project = model.project(id) else { return }
        selectProject(project, in: window)
        // The project can be restored with no selection (every tab was
        // closed, then a tab was created from the CLI with `--no-focus`);
        // a nil active tab renders a blank detail view.
        if model.activeTabID(of: id) == nil, let first = model.tabs(of: id).first {
            writer.tabPeek(first.id, in: id)
        }
    }

    /// Select a scratch tab from a keyboard cycle or the CLI: the project
    /// first, then the tab.
    func selectScratchTab(_ tabID: UUID) {
        guard let id = scratchProjectID, model.tabs(of: id).contains(where: { $0.id == tabID }) else { return }
        activeProjectID = id
        writer.tabSelect(tabID, in: id)
        warmFocusedProject()
        persistState()
    }

    // MARK: - Creation and moves

    /// A new scratch tab: a shell in home, or in the focused scratch pane's
    /// directory under `tab-inherit-working-directory`. With `focus` the
    /// project becomes the active one first, so the key window follows the
    /// new tab as it does for Cmd+T in a project.
    @discardableResult
    func createScratchTab(command: PaneStartCommand? = nil, env: [String: String]? = nil, focus: Bool = true) -> UUID? {
        guard let scratch = ensureScratchProject() else { return nil }
        if focus, activeProjectID != scratch {
            activeProjectID = scratch
        }
        let id = createTab(projectID: scratch, projects: [], command: command, env: env, focus: focus)
        logger.info("createScratchTab: \(id?.uuidString ?? "nil", privacy: .public)")
        return id
    }

    /// Move a project tab out of its project. Shells intact; the tab keeps
    /// its own working directory. `toIndex` is the slot among the scratch
    /// rows; nil appends.
    func moveTabToScratchTabs(_ tabID: UUID, from sourceProjectID: UUID, toIndex: Int? = nil) {
        guard let scratch = ensureScratchProject(), sourceProjectID != scratch else { return }
        moveTab(tabID, from: sourceProjectID, to: scratch, toIndex: toIndex)
    }
}
