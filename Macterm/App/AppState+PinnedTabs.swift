import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PinnedTabs")

/// Pinned tabs: the hidden project with the alias `pinned` (design/010
/// §11), above the projects. Each pinned tab is a `PinnedTabRecord`: a
/// durable declaration (splits + per-pane cwd/run/shell) plus, while
/// loaded, an ordinary live tab of the pinned project. The records are GUI
/// data (`gui-state.json`, `pinned.yaml`), keyed by tab id.
///
/// The rules, in one place:
/// - Pin = `moveTab` into the pinned project (declaration captured, origin
///   stamped); Unpin = `moveTab` back to the origin project. Both are
///   `tab.move` — sessions are never killed by pinning state changes.
///   "Remove from Pinned" is the one killing action (busy-confirmed).
/// - CLOSING a tab with a record is an UNLOAD, never a removal: sessions
///   end, the record — and its `pinned.yaml` entry — stays as a dimmed row,
///   and the next launch eager-starts it again. The same unload happens when
///   a tab's own sessions die (`paneProcessExited`). Selecting an unloaded
///   record rebuilds the tab from its declaration, re-running its `run:`
///   commands.
/// - `pinned.yaml` (see `PinnedLayoutStore`) mirrors the records and is
///   authoritative for membership at launch. It is rewritten on membership
///   changes, on a debounced pinned-pane foreground change
///   (`notePinnedForegroundChangesIfNeeded`), and at quit; external edits are
///   absorbed before every write, never clobbered.
extension AppState {
    // MARK: - Queries

    /// The pinned project, found by its alias. Nil until the first pin.
    var pinnedProjectID: UUID? { model.project(alias: PinnedTabs.alias)?.id }

    /// The live pinned tabs, in order.
    var pinnedTabs: [TerminalTab] { pinnedProjectID.map { model.tabs(of: $0) } ?? [] }

    func isPinnedTabLoaded(_ id: UUID) -> Bool {
        pinnedTabs.contains { $0.id == id }
    }

    func pinnedRecord(_ id: UUID) -> PinnedTabRecord? {
        pinnedRecords.first { $0.id == id }
    }

    /// The pinned project, made at the first need (the first pin, or a
    /// launch that has `pinned.yaml` entries). Empty: a tab there is one
    /// that someone pinned.
    @discardableResult
    func ensurePinnedProject() -> UUID? {
        if let id = pinnedProjectID { return id }
        let project = PinnedTabs.newProject()
        guard writer.projectCreate(project) else { return nil }
        return project.id
    }

    // MARK: - Pin / Unpin

    /// Move a project tab into the pinned project, capturing its live
    /// layout (cwd/run/shell per pane — the same seams Save Layout reads) as
    /// the record's declaration. `toRecordIndex` is the sidebar slot among
    /// the pinned rows (records, loaded or not); nil appends.
    func pinTab(_ tabID: UUID, fromProject sourceProjectID: UUID, toRecordIndex: Int? = nil) {
        guard sourceProjectID != pinnedProjectID,
              pinnedRecord(tabID) == nil,
              let tab = model.tabs(of: sourceProjectID).first(where: { $0.id == tabID }),
              let pinned = ensurePinnedProject()
        else { return }
        logger.info("pinTab: \(tabID, privacy: .public) from=\(sourceProjectID, privacy: .public)")
        let declaration = LayoutSerializer.pinnedDeclaration(for: tab)
        let recordIndex = min(max(toRecordIndex ?? pinnedRecords.count, 0), pinnedRecords.count)
        guard writer.tabMove(tabID, to: pinned, index: liveIndex(forRecordIndex: recordIndex)) else { return }
        let record = PinnedTabRecord(id: tabID, declaration: declaration, originProjectID: sourceProjectID)
        pinnedRecords.insert(record, at: recordIndex)
        activeProjectID = pinned
        persistState()
    }

    /// Unpin: a LOADED tab moves back to its origin project (falling back to
    /// the first project) — a move, never a kill. An UNLOADED record has no
    /// live tab to move; unpinning it just forgets the declaration.
    func unpinTab(_ tabID: UUID, projects: [Project]) {
        guard let record = pinnedRecord(tabID) else { return }
        guard isPinnedTabLoaded(tabID), let pinned = pinnedProjectID else {
            logger.info("unpinTab: forgetting unloaded record \(tabID, privacy: .public)")
            removePinnedRecord(forTab: tabID)
            persistState()
            return
        }
        guard let dest = unpinDestination(for: record, projects: projects) else { return }
        // moveTab removes the record (its unpin hook) and rewrites the file.
        moveTab(tabID, from: pinned, to: dest)
    }

    /// Where an unpinned tab goes: its origin project (a project of the
    /// tree, or Scratch Tabs), else the first project, else Scratch Tabs,
    /// which every tab can live in.
    private func unpinDestination(for record: PinnedTabRecord, projects: [Project]) -> UUID? {
        if let origin = record.originProjectID, let project = model.project(origin), project.isSelectable, origin != pinnedProjectID {
            return origin
        }
        return projects.first?.id ?? ensureScratchProject()
    }

    /// Unpin a record that has NO live tab (its sessions died) into a
    /// project — the drag-an-unloaded-row-out path, where the drop names the
    /// destination. The declaration spawns there, `run:` and all.
    func unpinUnloadedRecord(_ record: PinnedTabRecord, toProject destProjectID: UUID, toIndex: Int? = nil) {
        logger.info("unpinUnloadedRecord: \(record.id, privacy: .public) → \(destProjectID, privacy: .public)")
        if let planned = declaredPinnedTree(record, projectID: destProjectID) {
            writer.tabCreate(
                in: destProjectID,
                root: planned.root,
                id: record.id,
                index: toIndex,
                title: record.declaration.name
            )
        }
        removePinnedRecord(forTab: record.id)
        activeProjectID = destProjectID
        persistState()
    }

    /// Drop a record after its tab left the pinned project (a moveTab /
    /// merge out). The model side is the caller's job.
    func removePinnedRecord(forTab tabID: UUID) {
        guard pinnedRecords.contains(where: { $0.id == tabID }) else { return }
        pinnedRecords.removeAll { $0.id == tabID }
    }

    /// Reorder a pinned row to a drop offset in RECORD space (pre-removal
    /// coordinates, like `AppState.reorderTab`), then realign the live tab
    /// order to match.
    func reorderPinnedTab(_ tabID: UUID, toIndex destination: Int) {
        guard let from = pinnedRecords.firstIndex(where: { $0.id == tabID }) else { return }
        let to = Self.resolvedMoveIndex(from: from, toDropOffset: destination, count: pinnedRecords.count)
        guard to != from else { return }
        let record = pinnedRecords.remove(at: from)
        pinnedRecords.insert(record, at: to)
        alignPinnedTabOrder()
        persistState()
    }

    /// The CLI's `tab move` computes its offset against the LIVE tab list;
    /// translate it into record space so the sidebar rows and `pinned.yaml`
    /// follow the reorder instead of silently disagreeing with it.
    func reorderPinnedLiveTab(_ tabID: UUID, toLiveIndex destination: Int) {
        let tabs = pinnedTabs
        let recordDest: Int = if destination >= tabs.count {
            pinnedRecords.count
        } else {
            pinnedRecords.firstIndex { $0.id == tabs[max(destination, 0)].id } ?? pinnedRecords.count
        }
        reorderPinnedTab(tabID, toIndex: recordDest)
    }

    /// Separate a pane into its own PINNED tab at a sidebar slot. The slot is
    /// in RECORD space (what the pinned ForEach's insertion offset counts —
    /// unloaded rows included); `separatePane` speaks live-tab indices, so
    /// this owns the conversion and then pins the auto-created record at the
    /// requested slot.
    func separatePaneIntoPinned(_ paneID: UUID, atRecordIndex recordIndex: Int?) {
        guard let pinned = ensurePinnedProject() else { return }
        let slot = recordIndex.map { min(max($0, 0), pinnedRecords.count) }
        let before = Set(pinnedRecords.map(\.id))
        separatePane(paneID, toProject: pinned, at: slot.map { liveIndex(forRecordIndex: $0) })
        // `persistState` (inside separatePane) recorded the new tab at a slot
        // derived from its LIVE position; move the record to the slot the
        // drop actually named (they differ when unloaded rows precede it).
        guard let slot,
              let newID = pinnedRecords.map(\.id).first(where: { !before.contains($0) }),
              let from = pinnedRecords.firstIndex(where: { $0.id == newID })
        else { return }
        let to = min(slot, pinnedRecords.count - 1)
        guard to != from else { return }
        let record = pinnedRecords.remove(at: from)
        pinnedRecords.insert(record, at: to)
        alignPinnedTabOrder()
        persistState()
    }

    // MARK: - Selection / loading

    /// Select the pinned project itself (the sidebar's pinned header).
    func selectPinnedProject() {
        guard let pinned = ensurePinnedProject() else { return }
        activeProjectID = pinned
        // The pinned project can be restored with no selection; a nil
        // activeTab renders a blank detail view.
        if model.activeTabID(of: pinned) == nil, let first = model.tabs(of: pinned).first {
            writer.tabPeek(first.id, in: pinned)
        }
        warmFocusedProject()
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    /// Select a pinned row. Loaded → plain tab selection. Unloaded → rebuild
    /// from the declaration, re-running its `run:` commands.
    func selectPinnedTab(_ tabID: UUID) {
        guard let record = pinnedRecord(tabID), let pinned = ensurePinnedProject() else { return }
        activeProjectID = pinned
        if !isPinnedTabLoaded(tabID) {
            loadPinnedTab(record, activate: true)
        }
        writer.tabSelect(tabID, in: pinned)
        warmFocusedProject()
        persistState()
    }

    /// Rebuild an unloaded record's live tab from its declaration — a
    /// pure-spawn reconcile plan (no live tab → nothing to destroy), so
    /// declared `run:` commands start as typed `PaneStartCommand`s. The tab
    /// takes the record's id.
    private func loadPinnedTab(_ record: PinnedTabRecord, activate: Bool) {
        logger.info("loadPinnedTab: restoring \(record.id, privacy: .public) from declaration")
        guard let pinned = ensurePinnedProject(),
              let planned = declaredPinnedTree(record, projectID: pinned),
              let recordIndex = pinnedRecords.firstIndex(where: { $0.id == record.id })
        else { return }
        writer.tabCreate(
            in: pinned,
            root: planned.root,
            id: record.id,
            index: liveIndex(forRecordIndex: recordIndex),
            title: record.declaration.name,
            focus: activate
        )
    }

    /// The tree of a record's declaration, with new panes. Shared by
    /// restore-on-selection, the eager launch load, and the unpin of an
    /// unloaded record (which spawns into a project). The pinned PSEUDO-ROOT
    /// (`PinnedTabs.pathMarker`) makes `LayoutBuilder.resolveCwd` treat every
    /// leaf cwd as self-contained.
    private func declaredPinnedTree(_ record: PinnedTabRecord, projectID: UUID) -> (root: SplitNode, focusedPaneID: UUID?)? {
        let layout = LayoutFile(name: nil, tabs: [record.declaration])
        let plan = LayoutReconciler.plan(
            layout: layout,
            tabs: [],
            projectRoot: PinnedTabs.pathMarker,
            projectID: projectID
        )
        guard let planned = plan.tabs.first else { return nil }
        return (planned.root, planned.focusedPaneID)
    }

    /// In-project keyboard cycling for the pinned project: steps through
    /// the RECORDS (what the sidebar shows), restoring an unloaded row on
    /// landing — not just the loaded tabs.
    func cyclePinnedTab(step: Int) {
        guard pinnedRecords.count > 1 else { return }
        let currentIndex = pinnedProjectID.flatMap { model.activeTabID(of: $0) }
            .flatMap { id in pinnedRecords.firstIndex { $0.id == id } } ?? 0
        let count = pinnedRecords.count
        let next = pinnedRecords[(currentIndex + step + count) % count]
        selectPinnedTab(next.id)
    }

    // MARK: - Session death → unload

    /// The process-exit path (a pane's shell ended on its own), distinct from
    /// the user's close request. For a tab with no record this is the close
    /// of the pane (and the tab with its last pane). For a pinned tab, the
    /// LAST pane dying unloads the tab instead: sessions are gone, surfaces
    /// torn down, but the record — and its sidebar row — stay, and the next
    /// selection restores from the declaration.
    func paneProcessExited(_ paneID: UUID, projectID: UUID) {
        guard let (_, tab) = model.locate(pane: paneID), pinnedRecord(tab.id) != nil else {
            requestClosePane(paneID, projectID: projectID)
            return
        }
        if tab.splitRoot.allPanes().count > 1 {
            closePane(paneID, projectID: projectID)
        } else {
            unloadPinnedTab(tab.id)
        }
    }

    /// Close a pinned tab's live half (`tab.close`: the server ends its
    /// sessions), keeping the record as an unloaded row. Deliberately NOT
    /// refreshing the declaration here: a dead pane reads as idle, and
    /// capturing that would erase the `run:` this record exists to re-run.
    func unloadPinnedTab(_ tabID: UUID) {
        guard isPinnedTabLoaded(tabID) else { return }
        logger.info("unloadPinnedTab: \(tabID, privacy: .public)")
        writer.tabClose(tabID)
        persistState()
    }

    // MARK: - Restore / materialize

    /// The records of `gui-state.json`. The live tabs are in the model.
    func restorePinnedState(_ records: [PinnedRecordState]) {
        pinnedRecords = records.map {
            PinnedTabRecord(id: $0.id, declaration: $0.declaration, originProjectID: $0.originProjectID)
        }
        if !pinnedRecords.isEmpty { ensurePinnedProject() }
    }

    /// Materialize EVERY pinned record into a running tab at launch — pinned
    /// tabs are eager by design (they exist to keep things running), unlike
    /// projects, which stay lazy until selected. A tab whose sessions
    /// survived keeps its panes; one whose local sessions all died (a
    /// restart of the Mac) — and a record that was unloaded at quit, or
    /// hand-added to `pinned.yaml` — rebuilds from its declaration,
    /// re-running its `run:` commands. A tab with any REMOTE pane always
    /// keeps its panes — its sessions live on the remote host, which the
    /// local server can't see. A failed listing (nil) also keeps everything:
    /// fail toward reattach, never toward respawning over sessions that may
    /// be alive.
    ///
    /// The unloaded (dimmed) state therefore only arises mid-session, when a
    /// tab's own sessions die — and stays lazy there on purpose: eagerly
    /// respawning at the moment of death would be a crash loop for a `run:`
    /// that exits immediately.
    func materializeRestoredPinnedTabs() async {
        guard !pinnedRecords.isEmpty else { return }
        var aliveNames: Set<String>?
        if pinnedTabs.isEmpty {
            aliveNames = []
        } else if sessionClient.isBundled() {
            if let sessions = await sessionClient.listSessions() {
                aliveNames = Set(sessions.filter(\.isRunning).map(\.name))
            }
        } else {
            // No persistence layer: nothing survived the quit.
            aliveNames = []
        }
        guard let pinned = ensurePinnedProject() else { return }
        for record in pinnedRecords {
            if let tab = model.tab(record.id), model.projectID(ofTab: record.id) == pinned {
                let panes = tab.splitRoot.allPanes()
                let hasRemote = panes.contains(where: \.isRemote)
                // ANY surviving pane keeps the whole tab — deliberately:
                // rebuilding from the declaration would end the survivors.
                let survived = hasRemote || aliveNames.map { alive in panes.contains { alive.contains($0.sessionName) } } ?? true
                if survived { continue }
                logger.info("pinned tab \(record.id, privacy: .public): sessions died; respawning from layout")
                if let planned = declaredPinnedTree(record, projectID: pinned) {
                    writer.tabLayout(record.id, root: planned.root, focusedPaneID: planned.focusedPaneID)
                }
                continue
            }
            loadPinnedTab(record, activate: false)
        }
        if model.activeTabID(of: pinned) == nil, let first = model.tabs(of: pinned).first {
            writer.tabPeek(first.id, in: pinned)
        }
        warmPinnedTabs()
        persistState()
    }

    /// Start every pinned pane's shell off-screen via the shared stagger
    /// (`warmStaggered`). Incubation is idempotent, so a pane SwiftUI has
    /// already spawned just no-ops. The shared warm path wires the same exit
    /// classifier as rendered panes: a dead pinned shell unloads its tab,
    /// while a dropped remote connection stays for the reconnect sweep.
    private func warmPinnedTabs() {
        warmStaggered(pinnedTabs.flatMap { $0.splitRoot.allPanes() })
    }

    // MARK: - pinned.yaml

    /// Launch reconcile: the file is authoritative for MEMBERSHIP.
    /// - entries matched by id keep their record, adopting the file's
    ///   declaration (hand-edits take effect at the next restore);
    /// - unmatched entries become new UNLOADED records (a hand-added tab —
    ///   it spawns when selected, or shows as a dimmed row until then);
    /// - records missing from the file are unpinned: an unloaded one is
    ///   forgotten, one with a restorable live tab moves to its origin
    ///   project (a move — its surviving sessions reattach there).
    /// An absent or unparseable file is "no external input", never
    /// "remove everything" (editor truncate-then-write saves, mid-edit
    /// typos); unparseable additionally suspends auto-writes.
    func reconcilePinnedLayoutAtLaunch(projects: [Project]) {
        switch pinnedLayoutStore.read() {
        case .absent:
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            if !pinnedRecords.isEmpty { writePinnedLayout() }
        case let .invalid(reason):
            suspendPinnedLayoutWrites(reason: reason)
            pinnedMembershipStamp = pinnedRecords.map(\.id)
        case let .file(tabs, text):
            applyPinnedFileMembership(tabs, projects: projects)
            pinnedLayoutLastWrittenText = text
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            pinnedLayoutSuspended = false
        }
    }

    private func applyPinnedFileMembership(_ fileTabs: [LayoutTab], projects: [Project]) {
        // Entries carry no wire-level id (hostile to hand-editing); they are
        // matched back to records by name → exact layout → position
        // (`PinnedLayoutMatcher`). A matched record keeps its internal
        // identity — and thus its live-session snapshot — while adopting the
        // entry's declaration; an unmatched entry is a genuine addition.
        let matching = PinnedLayoutMatcher.match(entries: fileTabs, records: pinnedRecords)
        let result: [PinnedTabRecord] = matching.pairs.map { entry, record in
            if var record {
                record.declaration = entry
                return record
            }
            return PinnedTabRecord(id: UUID(), declaration: entry, originProjectID: nil)
        }
        let removed = matching.removed
        pinnedRecords = result
        for record in removed {
            guard isPinnedTabLoaded(record.id) else {
                logger.info("pinned.yaml removed unloaded record \(record.id, privacy: .public); forgotten")
                continue
            }
            // The file unpinned a tab whose sessions may still be running:
            // honor it as a MOVE into the origin project, keeping the shells.
            guard let dest = unpinDestination(for: record, projects: projects) else {
                logger.warning("pinned.yaml removed \(record.id, privacy: .public) but no project exists; forgotten")
                continue
            }
            logger.info("pinned.yaml unpinned \(record.id, privacy: .public) → \(dest, privacy: .public)")
            writer.tabMove(record.id, to: dest)
        }
    }

    /// Give every live tab of the pinned project a record (a tab created
    /// inside it — CLI `tab new`, a separated pane, a merge — is pinned from
    /// birth), then rewrite `pinned.yaml` iff membership changed. Called
    /// from every `persistState()`, so it must stay cheap on the steady
    /// path: a set compare when nothing moved.
    func syncPinnedRecordsWithModel() {
        let tabs = pinnedTabs
        let known = Set(pinnedRecords.map(\.id))
        for tab in tabs where !known.contains(tab.id) {
            let declaration = LayoutSerializer.pinnedDeclaration(for: tab)
            let record = PinnedTabRecord(id: tab.id, declaration: declaration, originProjectID: nil)
            pinnedRecords.insert(record, at: recordIndex(forLiveTab: tab.id, in: tabs))
        }
        let membership = pinnedRecords.map(\.id)
        if let stamp = pinnedMembershipStamp {
            if membership != stamp { writePinnedLayout() }
        } else if !membership.isEmpty {
            // No baseline yet (first pin of a fresh run, or a test that never
            // restored). An empty set with no baseline writes nothing — that
            // is what keeps a pre-restore save from clobbering the file.
            writePinnedLayout()
        }
    }

    /// Quit hook: refresh every LOADED record's declaration from its live tab
    /// (the moment the recipe is about to matter), persist the snapshot, and
    /// rewrite the file.
    func persistForTermination() {
        refreshPinnedDeclarationsFromLiveTabs()
        refreshDesktopWidgetRecipes()
        persistState()
        writeWidgetLayout()
        // Nothing pinned and no file ever written this run → don't create
        // (or churn) pinned.yaml for users who never touch the feature. The
        // membership stamp can't stand in for this check — the launch
        // reconcile sets it on every branch, empty set included.
        if !(pinnedRecords.isEmpty && pinnedLayoutLastWrittenText == nil) {
            writePinnedLayout()
        }
    }

    /// Poll hook: when any pinned pane's foreground name changed since the
    /// last tick (a command started, ended, or was replaced), schedule a
    /// debounced declaration refresh + persist. Debounced because a command
    /// boundary often lands as two quick transitions (resolver race reports
    /// nil, then the real argv), and because each persist rewrites
    /// `pinned.yaml` — a file people dotfile-sync. Returns whether a persist
    /// was scheduled (for tests).
    @discardableResult
    func notePinnedForegroundChangesIfNeeded() -> Bool {
        let tabs = pinnedTabs
        guard !tabs.isEmpty else {
            pinnedForegroundStamp = [:]
            return false
        }
        var stamp: [UUID: String?] = [:]
        for pane in tabs.flatMap({ $0.splitRoot.allPanes() }) {
            stamp[pane.id] = pane.foregroundSample?.name
        }
        guard stamp != pinnedForegroundStamp else { return false }
        pinnedForegroundStamp = stamp
        schedulePinnedDeclarationPersist()
        return true
    }

    private func schedulePinnedDeclarationPersist() {
        pinnedDeclarationPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pinnedDeclarationPersistWork = nil
                self.persistRefreshedPinnedDeclarations()
            }
        }
        pinnedDeclarationPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Re-capture every loaded record's declaration from its live tab and
    /// persist both layers (snapshot + `pinned.yaml`). The debounced landing
    /// point of `notePinnedForegroundChangesIfNeeded`; also safe to call
    /// directly.
    func persistRefreshedPinnedDeclarations() {
        guard !pinnedRecords.isEmpty, !pinnedTabs.isEmpty else { return }
        let before = pinnedRecords.map(\.declaration)
        refreshPinnedDeclarationsFromLiveTabs()
        // A boundary that changed nothing observable (the run-preserving
        // merge often absorbs it) must not churn two files.
        guard pinnedRecords.map(\.declaration) != before else { return }
        persistState()
        writePinnedLayout()
    }

    func refreshPinnedDeclarationsFromLiveTabs() {
        let tabs = pinnedTabs
        for index in pinnedRecords.indices {
            guard let live = tabs.first(where: { $0.id == pinnedRecords[index].id }) else { continue }
            var fresh = LayoutSerializer.pinnedDeclaration(for: live)
            // Never let an idle capture ERASE the respawn recipe — see
            // `LayoutNode.preservingRuns(from:)` for the moments this guards.
            fresh.layout = fresh.layout.preservingRuns(from: pinnedRecords[index].declaration.layout)
            pinnedRecords[index].declaration = fresh
        }
    }

    /// Rewrite `pinned.yaml` from the records — after absorbing any external
    /// edit made since our last write (tracked by exact text). Additions
    /// absorb as new unloaded records and edits update declarations;
    /// removals of LIVE tabs are honored at launch only (this path has no
    /// project list to move them into) and get re-declared. A file that no
    /// longer parses suspends auto-writes instead of clobbering the user's
    /// mid-edit work.
    func writePinnedLayout() {
        // ONE read serves both the suspension re-check and the absorb — the
        // read parses the whole file, so doubling it doubled the cost.
        let onDisk = pinnedLayoutStore.read()
        if pinnedLayoutSuspended {
            // Re-check: the user may have fixed (or deleted) the file since.
            switch onDisk {
            case .absent,
                 .file:
                pinnedLayoutSuspended = false
            case .invalid:
                return
            }
        }
        switch onDisk {
        case .absent:
            break
        case let .invalid(reason):
            suspendPinnedLayoutWrites(reason: reason)
            return
        case let .file(tabs, text):
            if text != pinnedLayoutLastWrittenText {
                absorbExternalPinnedEdits(tabs)
            }
        }
        do {
            pinnedLayoutLastWrittenText = try pinnedLayoutStore.write(tabs: pinnedRecords.map(\.declaration))
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            // No noteLayoutFilesChanged(): the Projects settings pane's
            // listing filters pinned.yaml out, so a rescan can never observe
            // this write — bumping the version would only force a re-parse of
            // every project file for zero visible delta.
        } catch {
            logger.error("Failed to write pinned.yaml: \(error, privacy: .public)")
        }
    }

    /// Write-time absorption (the app is running; launch reconcile handles
    /// the rest): the records adopt the file's ORDER and declarations,
    /// additions become unloaded records, and removals of UNLOADED records
    /// are honored. Removals of LIVE tabs can't be honored here (no project
    /// list to move them into) — those records are kept, appended after the
    /// file's order, and get re-declared by the write that follows.
    private func absorbExternalPinnedEdits(_ fileTabs: [LayoutTab]) {
        logger.info("pinned.yaml changed externally; absorbing before write")
        let matching = PinnedLayoutMatcher.match(entries: fileTabs, records: pinnedRecords)
        var result: [PinnedTabRecord] = matching.pairs.map { entry, record in
            if var record {
                record.declaration = entry
                return record
            }
            return PinnedTabRecord(id: UUID(), declaration: entry, originProjectID: nil)
        }
        result += matching.removed.filter { isPinnedTabLoaded($0.id) }
        pinnedRecords = result
        alignPinnedTabOrder()
    }

    private func suspendPinnedLayoutWrites(reason: BilingualMessage) {
        guard !pinnedLayoutSuspended else { return }
        pinnedLayoutSuspended = true
        logger.error("pinned.yaml auto-save suspended: \(reason.english, privacy: .public)")
        presentLayoutError(
            verb: .save,
            message: String(localized: """
            \(reason.localized)

            Pinned-tab auto-save is paused so your edits are not overwritten. \
            Fix the file, or delete it, to start auto-save again.
            """),
            title: String(localized: "Pinned layout file problem")
        )
    }

    // MARK: - Record/live index alignment

    /// The pinned project holds only LOADED tabs; the sidebar shows every
    /// record. These helpers keep the two orders consistent.
    private func liveIndex(forRecordIndex recordIndex: Int) -> Int {
        let liveIDs = Set(pinnedTabs.map(\.id))
        return pinnedRecords.prefix(recordIndex).count { liveIDs.contains($0.id) }
    }

    private func recordIndex(forLiveTab tabID: UUID, in tabs: [TerminalTab]) -> Int {
        // Insert after the record of the nearest preceding live tab.
        guard let liveIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return pinnedRecords.count }
        for earlier in tabs[..<liveIndex].reversed() {
            if let idx = pinnedRecords.firstIndex(where: { $0.id == earlier.id }) {
                return idx + 1
            }
        }
        return 0
    }

    /// Put the loaded tabs in the records' order (after a sidebar reorder).
    private func alignPinnedTabOrder() {
        guard let pinned = pinnedProjectID else { return }
        let loaded = pinnedRecords.map(\.id).filter(isPinnedTabLoaded)
        for (index, id) in loaded.enumerated() where model.tabs(of: pinned).firstIndex(where: { $0.id == id }) != index {
            writer.tabReorder(id, in: pinned, toIndex: index)
        }
    }
}
