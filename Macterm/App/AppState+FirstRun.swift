import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "FirstRunSeed")

extension AppState {
    /// Give a genuinely fresh install something to look at: a pinned
    /// "Welcome" row that prints a short tutorial as terminal output, and a
    /// Home project with one plain shell tab. See `FirstRunSeed` for the policy and
    /// `Tutorial` for the text.
    ///
    /// Runs from `MainWindow`'s launch task, AFTER `restoreSelection` — which
    /// is what makes "empty" answerable: the snapshot is loaded, the pinned
    /// records are reconciled against `pinned.yaml`, and `loadFailed` is
    /// known. `AppState` doesn't own the `ProjectStore` (the same reason
    /// `saveLayout` takes its projects), so the caller passes it.
    ///
    /// Returns whether it seeded, for the tests and the log.
    @discardableResult
    func seedFirstRunIfNeeded(projectStore: ProjectStore) -> Bool {
        let decision = FirstRunSeed.decide(
            alreadySeeded: Preferences.shared.hasSeededFirstRun,
            projectCount: projectStore.projects.count,
            pinnedRecordCount: pinnedRecords.count,
            workspaceCount: workspaces.count,
            snapshotLoadFailed: snapshotLoadFailed,
            isHarnessRun: BenchmarkControl.isEnabled
        )
        switch decision {
        case .postpone:
            logger.info("first run: postponed (harness run or unreadable snapshot)")
            return false
        case .skip:
            Preferences.shared.hasSeededFirstRun = true
            return false
        case .seed:
            break
        }
        logger.info("first run: seeding the welcome project and pinned tab")
        // Record before doing anything: a seed that half-succeeds must not be
        // retried on the next launch on top of what it did manage to create.
        Preferences.shared.hasSeededFirstRun = true

        let project = projectStore.create(name: FirstRunSeed.projectName, path: FirstRunSeed.projectPath)
        // The project's first tab is a plain shell with no `run:`, the same
        // tab that every added project gets. `projectAdded` does nothing when
        // the `onAdd` hook of the store already gave the tab.
        projectAdded(project)

        // The pinned half is added as a record with no live tab — exactly the
        // state a relaunch restores from a declaration-only `pinned.yaml`
        // entry — so `materializeRestoredPinnedTabs` builds and warms it
        // through the one path that already knows how.
        ensurePinnedWorkspace()
        pinnedRecords.append(PinnedTabRecord(
            id: UUID(),
            declaration: FirstRunSeed.pinnedDeclaration,
            // The project we just made: where "Unpin Tab" sends the row.
            originProjectID: project.id
        ))

        // Selects, warms and (via the pinned membership change) writes
        // `pinned.yaml`. The project tab is the one on screen; the pinned row
        // sits above it with its tutorial already printed.
        selectProject(project)
        persistState()
        Task { await materializeRestoredPinnedTabs() }
        return true
    }
}
