import Foundation
@testable import Macterm
import Testing

/// Pinned tabs: the hidden pinned project, pin/unpin moves, the
/// can't-close rule, unload-on-session-death + restore-from-declaration, and
/// the `pinned.yaml` write/absorb contract.
@MainActor
struct PinnedTabsTests {
    // MARK: - Setup helpers

    @MainActor
    private struct Fixture {
        let state: AppState
        /// `gui-state.json`: the pinned records.
        let storeURL: URL
        let projectsDir: URL

        /// The pinned project, made at the first need.
        var pinnedID: UUID { state.ensurePinnedProject() ?? UUID() }

        /// The live tabs of the pinned project.
        var pinned: LiveTabs? { state.pinnedProjectID.flatMap { state.liveTabs[$0] } }

        /// The pinned records of `gui-state.json`.
        var savedRecords: [PinnedRecordState] { GUIStateStore(fileURL: storeURL).load()?.pinned ?? [] }

        /// A relaunch: a second AppState on the same server and files, with a
        /// no-op session client.
        func relaunch() -> AppState {
            let state2 = TestModel.relaunch(
                state,
                guiStateStore: GUIStateStore(fileURL: storeURL),
                projectFiles: ProjectFileStore(directoryURL: projectsDir)
            )
            state2.sessionClient = .noop
            state2.incubatePane = { _ in }
            return state2
        }
    }

    /// AppState over a test server, with temp-file stores and a no-op
    /// session client (a test must never reap the developer's live sessions).
    private func makeFixture() -> Fixture {
        let dir = TestModel.folder("pinned")
        let storeURL = dir.appending(path: "gui-state.json")
        let projectsDir = dir.appending(path: "projects", directoryHint: .isDirectory)
        let state = TestModel.appState(
            guiStateStore: GUIStateStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        state.sessionClient = .noop
        // Never let the eager pinned launch warm REAL surfaces in the test
        // host (that would spawn actual shells).
        state.incubatePane = { _ in }
        return Fixture(state: state, storeURL: storeURL, projectsDir: projectsDir)
    }

    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        TestModel.project(state, name: name, path: path)
    }

    /// A second tab in `project`.
    private func addTab(_ state: AppState, in project: Project) throws -> TerminalTab {
        let id = try #require(state.createTab(projectID: project.id, projectPath: project.path))
        return try #require(state.model.tab(id))
    }

    /// Split the first pane of `tab`. Returns the new pane's id.
    private func split(_ state: AppState, _ tab: TerminalTab) throws -> UUID {
        let target = try #require(tab.splitRoot.allPanes().first)
        let pane = Pane(projectPath: "/tmp", projectID: target.projectID)
        return try #require(state.writer.paneSplit(tab: tab.id, target: target.id, new: pane, direction: .horizontal))
    }

    // MARK: - Reserved name

    @Test
    func reserves_its_own_name_in_any_case_and_padding_only() {
        // Every spelling `ControlHandler.resolveProject` reads as the pinned
        // workspace, plus the padded ones that would look like it in a row.
        for name in ["Pinned", "pinned", "PINNED", "pInNeD", " Pinned ", "\tpinned\n"] {
            #expect(PinnedTabs.reservesName(name), "\(name)")
        }
        for name in ["", "Pinned 2", "Pinned Tabs", "unpinned", "pinned.yaml", "Pin ned"] {
            #expect(!PinnedTabs.reservesName(name), "\(name)")
        }
    }

    // MARK: - Pin

    @Test
    func pinTab_moves_tab_into_pinned_workspace_and_records_it() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)

        fx.state.pinTab(tab.id, fromProject: p.id)

        #expect(fx.state.liveTabs[p.id]?.tabs.isEmpty == true)
        #expect(fx.pinned?.tabs.map(\.id) == [tab.id])
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.pinnedRecords.first?.originProjectID == p.id)
        #expect(pane.projectID == fx.pinnedID)
        #expect(fx.state.activeProjectID == fx.pinnedID)
    }

    @Test
    func pinTab_writes_pinned_yaml_with_marker_and_id() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)

        fx.state.pinTab(tab.id, fromProject: p.id)

        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("<pinned>"))
        // No wire-level ids — entries stay hand-editable.
        #expect(!text.contains(tab.id.uuidString))
    }

    @Test
    func moveTab_into_pinned_routes_to_pin() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)

        fx.state.moveTab(tab.id, from: p.id, to: fx.pinnedID, destPath: "/anything")

        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.pinned?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func new_tab_created_inside_pinned_workspace_gets_a_record() throws {
        let fx = makeFixture()
        fx.state.selectPinnedProject()
        let tabID = try #require(
            fx.state.createTab(projectID: fx.pinnedID, projectPath: PinnedTabs.fallbackRoot)
        )
        #expect(fx.state.pinnedRecords.map(\.id) == [tabID])
    }

    // MARK: - Unpin

    @Test
    func unpinTab_returns_loaded_tab_to_origin_project() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.unpinTab(tab.id, projects: [p])

        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.pinned?.tabs.isEmpty == true)
        #expect(fx.state.liveTabs[p.id]?.tabs.map(\.id) == [tab.id])
        #expect(tab.splitRoot.allPanes().first?.projectID == p.id)
    }

    /// Pin and Unpin are `tab.move` requests: the tab, its panes and their
    /// sessions stay the same objects. Pin records the tab in
    /// `gui-state.json`; Unpin removes the record, and the tab lands in its
    /// origin project.
    @Test
    func pin_and_unpin_are_tab_moves_that_keep_the_records() throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let origin = seedProject(fx.state, name: "origin")
        let other = seedProject(fx.state, name: "other")
        let tab = try #require(fx.state.liveTabs[origin.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let session = pane.sessionName

        fx.state.pinTab(tab.id, fromProject: origin.id)

        // Pin: the same tab is in the pinned project, and it has a record.
        let pinnedID = try #require(fx.state.pinnedProjectID)
        #expect(fx.state.model.tab(tab.id) === tab)
        #expect(fx.state.model.projectID(ofTab: tab.id) == pinnedID)
        #expect(fx.state.model.pane(pane.id) === pane)
        #expect(pane.sessionName == session)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.savedRecords.map(\.id) == [tab.id])
        #expect(fx.savedRecords.first?.originProjectID == origin.id)

        // Unpin with another project first in the list: the tab goes back to
        // its origin, not to the first project.
        fx.state.unpinTab(tab.id, projects: [other, origin])

        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.savedRecords.isEmpty)
        #expect(fx.state.model.projectID(ofTab: tab.id) == origin.id)
        #expect(fx.state.liveTabs[origin.id]?.tabs.map(\.id) == [tab.id])
        #expect(fx.state.liveTabs[pinnedID]?.tabs.isEmpty == true)
        #expect(fx.state.model.pane(pane.id) === pane)
        #expect(pane.projectID == origin.id)
        #expect(pane.sessionName == session)
        #expect(fx.state.activeProjectID == origin.id)
    }

    /// A `tab.move` out of the pinned project from any path (a drag, the
    /// CLI) is the unpin: the record goes with it.
    @Test
    func moveTab_out_of_pinned_removes_the_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.moveTab(tab.id, from: fx.pinnedID, to: p.id)

        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.savedRecords.isEmpty)
        #expect(fx.state.liveTabs[p.id]?.tabs.map(\.id) == [tab.id])
    }

    /// The records survive a relaunch in `gui-state.json`, and meet the live
    /// tab that the server kept, by tab id.
    @Test
    func pinned_records_meet_the_servers_tabs_after_a_relaunch() throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        let state2 = fx.relaunch()
        state2.restorePinnedState(fx.savedRecords)

        #expect(state2.pinnedRecords.map(\.id) == [tab.id])
        #expect(state2.pinnedRecords.first?.originProjectID == p.id)
        #expect(state2.isPinnedTabLoaded(tab.id))
        #expect(state2.pinnedProjectID == fx.state.pinnedProjectID)

        state2.unpinTab(tab.id, projects: [p])
        #expect(state2.pinnedRecords.isEmpty)
        #expect(state2.liveTabs[p.id]?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func unpinTab_unloaded_record_is_forgotten() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp"))),
            originProjectID: nil
        )
        // A record lives in the pinned project (`restorePinnedState`).
        fx.state.ensurePinnedProject()
        fx.state.pinnedRecords = [record]

        fx.state.unpinTab(record.id, projects: [])

        #expect(fx.state.pinnedRecords.isEmpty)
    }

    // MARK: - Close = unload

    /// One `AppCommand.closeTab` serves both kinds of tab: on the pinned
    /// workspace it unloads (record kept), on a project it closes for good.
    @Test
    func closeTab_command_unloads_pinned_and_closes_normal_tabs() throws {
        let fx = makeFixture()
        let ctx = AppCommandContext(appState: fx.state, projectStore: TestModel.projectStore(fx.state))
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        // Active tab is the pinned one → close unloads, keeping the record.
        // (Bound before calling: invoking the `#require` result directly
        // crashes the Swift 6.3 frontend.)
        let closePinned = try #require(AppCommand.closeTab.action(in: ctx))
        closePinned()
        #expect(fx.pinned?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])

        // Back on the project (pinning moved its only tab out, so make a
        // fresh one), close removes the tab outright.
        fx.state.activeProjectID = p.id
        _ = try #require(fx.state.createTab(projectID: p.id, projectPath: p.path))
        let closeNormal = try #require(AppCommand.closeTab.action(in: ctx))
        closeNormal()
        #expect(fx.state.liveTabs[p.id]?.tabs.isEmpty == true)
    }

    @Test
    func requestCloseTab_unloads_pinned_tab_keeping_the_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.requestCloseTab(tab.id, projectID: fx.pinnedID)

        // Sessions end and the live tab goes — but the record (the dimmed
        // row, and its pinned.yaml entry) stays; unpin is the removal path.
        #expect(fx.pinned?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
    }

    @Test
    func closeTabs_bulk_unloads_pinned_and_closes_normal_tabs() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let pinnedTab = ws.tabs[0]
        let normalTab = try addTab(fx.state, in: p)
        fx.state.pinTab(pinnedTab.id, fromProject: p.id)

        fx.state.closeTabs([
            (tabID: pinnedTab.id, projectID: fx.pinnedID),
            (tabID: normalTab.id, projectID: p.id),
        ])

        #expect(fx.pinned?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [pinnedTab.id])
        #expect(fx.state.liveTabs[p.id]?.tabs.isEmpty == true)
    }

    @Test
    func closePane_last_pane_of_pinned_tab_unloads_it() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.closePane(paneID, projectID: fx.pinnedID)

        #expect(fx.pinned?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
    }

    @Test
    func closePane_allows_inner_pane_of_pinned_split() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let newPane = try split(fx.state, tab)

        fx.state.closePane(newPane, projectID: fx.pinnedID)

        #expect(tab.splitRoot.allPanes().count == 1)
        #expect(fx.pinned?.tabs.count == 1)
    }

    // MARK: - Session death → unload → restore

    @Test
    func paneProcessExited_last_pane_unloads_tab_keeping_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.paneProcessExited(paneID, projectID: fx.pinnedID)

        #expect(fx.pinned?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.isPinnedTabLoaded(tab.id) == false)
    }

    @Test
    func selectPinnedTab_rebuilds_unloaded_tab_from_declaration() throws {
        let fx = makeFixture()
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(
                name: "dev",
                layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
            ),
            originProjectID: nil
        )]

        fx.state.selectPinnedTab(recordID)

        let tab = try #require(fx.pinned?.tabs.first)
        #expect(tab.id == recordID)
        #expect(tab.customTitle == "dev")
        let pane = try #require(tab.splitRoot.allPanes().first)
        #expect(pane.start == .typed("npm run dev"))
        #expect(pane.projectPath == "/tmp")
        #expect(fx.state.activeProjectID == fx.pinnedID)
        #expect(fx.pinned?.activeTabID == recordID)
    }

    @Test
    func paneProcessExited_in_normal_project_closes_as_before() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let tab = try #require(ws.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.paneProcessExited(paneID, projectID: p.id)

        #expect(ws.tabs.isEmpty)
    }

    // MARK: - Persistence + materialize

    @Test
    func pinned_tabs_persist_and_restore_as_records_with_live_snapshots() throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.persistState()

        // The record is in `gui-state.json`; the live tab is in the server's
        // model, in the hidden pinned project.
        let saved = fx.savedRecords
        #expect(saved.count == 1)
        #expect(saved.first?.id == tab.id)
        #expect(saved.first?.originProjectID == p.id)
        #expect(fx.state.model.projectID(ofTab: tab.id) == fx.pinnedID)
        let pinned = try #require(fx.state.model.project(fx.pinnedID))
        #expect(pinned.sidebar == .top)
        #expect(!pinned.removable)
        #expect(!fx.state.model.treeProjects.contains { $0.id == fx.pinnedID })
    }

    @Test
    func materialize_respawns_dead_sessions_from_the_declaration() async throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        let originalSession = try #require(tab.splitRoot.allPanes().first?.sessionName)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.persistState()

        // Second launch: a new state on the same server and file, with a zmx
        // whose listing says nothing survived. Pinned tabs are EAGER: the
        // dead tab respawns from its declaration at launch, not on click.
        let state2 = fx.relaunch()
        var dead = SessionClient.noop
        dead.isBundled = { true }
        dead.listSessions = { [] }
        state2.sessionClient = dead
        state2.incubatePane = { _ in }
        state2.restorePinnedState(fx.savedRecords)

        await state2.materializeRestoredPinnedTabs()

        #expect(state2.pinnedRecords.map(\.id) == [tab.id])
        #expect(state2.isPinnedTabLoaded(tab.id))
        // A respawn, not a reattach: fresh pane, fresh session identity.
        let pane = try #require(state2.pinnedTabs.first?.splitRoot.allPanes().first)
        #expect(pane.sessionName != originalSession)
        #expect(pane.projectPath == "/tmp")
    }

    @Test
    func materialize_eager_loads_declaration_only_records_and_warms_them() async throws {
        let fx = makeFixture()
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(
                name: "dev",
                layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
            ),
            originProjectID: nil
        )]
        var warmed: [UUID] = []
        fx.state.incubatePane = { warmed.append($0.id) }

        await fx.state.materializeRestoredPinnedTabs()

        #expect(fx.state.isPinnedTabLoaded(recordID))
        let pane = try #require(fx.pinned?.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.start == .typed("npm run dev"))
        #expect(warmed == [pane.id])
    }

    @Test
    func materialize_reattaches_surviving_sessions() async throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        let sessionName = try #require(tab.splitRoot.allPanes().first?.sessionName)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.persistState()

        let state2 = fx.relaunch()
        var alive = SessionClient.noop
        alive.isBundled = { true }
        alive.listSessions = { [SessionInfo(name: sessionName)] }
        state2.sessionClient = alive
        state2.incubatePane = { _ in }
        state2.restorePinnedState(fx.savedRecords)

        await state2.materializeRestoredPinnedTabs()

        #expect(state2.isPinnedTabLoaded(tab.id))
        // Session identity survives the round trip verbatim.
        let restoredPane = try #require(state2.pinnedTabs.first?.splitRoot.allPanes().first)
        #expect(restoredPane.sessionName == sessionName)
    }

    @Test
    func materialize_failed_listing_reattaches_conservatively() async throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.persistState()

        let state2 = fx.relaunch()
        var unknown = SessionClient.noop
        unknown.isBundled = { true }
        unknown.listSessions = { nil } // probe failed → unknown
        state2.sessionClient = unknown
        state2.incubatePane = { _ in }
        state2.restorePinnedState(fx.savedRecords)

        await state2.materializeRestoredPinnedTabs()

        // Unknown must fail toward reattach, never toward respawn.
        #expect(state2.isPinnedTabLoaded(tab.id))
    }

    // MARK: - Declaration freshness

    @Test
    func foreground_change_schedules_a_declaration_refresh() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let pane = try #require(tab.splitRoot.allPanes().first)

        // First observation populates the stamp (counts as a change);
        // steady state schedules nothing; a new foreground does.
        #expect(fx.state.notePinnedForegroundChangesIfNeeded())
        #expect(fx.state.notePinnedForegroundChangesIfNeeded() == false)
        pane.foregroundProcessName = "btop"
        #expect(fx.state.notePinnedForegroundChangesIfNeeded())
        #expect(fx.state.notePinnedForegroundChangesIfNeeded() == false)
    }

    @Test
    func persistRefreshedPinnedDeclarations_recaptures_and_rewrites_the_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        // The declaration was captured at pin time; a later change to the tab
        // (a rename stands in for a started process, which needs a live
        // surface to observe) must reach both the record and pinned.yaml.
        fx.state.writer.tabSet(tab.id, title: "renamed")
        fx.state.persistRefreshedPinnedDeclarations()

        #expect(fx.state.pinnedRecords.first?.declaration.name == "renamed")
        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("renamed"))
    }

    // MARK: - Audit regressions

    @Test
    func declaration_refresh_never_erases_an_established_run() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        // The record was pinned with a run: (hand-set here; live capture in
        // tests always reads idle, which is exactly the hazard).
        fx.state.pinnedRecords[0].declaration = LayoutTab(
            name: nil, layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
        )

        fx.state.refreshPinnedDeclarationsFromLiveTabs()

        guard case let .pane(leaf) = fx.state.pinnedRecords[0].declaration.layout else {
            Issue.record("expected a leaf")
            return
        }
        #expect(leaf.run == "npm run dev")
    }

    @Test
    func pinned_active_tab_survives_a_restart() async throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let first = ws.tabs[0]
        let second = try addTab(fx.state, in: p)
        fx.state.pinTab(first.id, fromProject: p.id)
        fx.state.pinTab(second.id, fromProject: p.id)
        fx.state.selectPinnedTab(second.id)
        fx.state.persistState()

        // The server keeps the active tab of the pinned project.
        let state2 = fx.relaunch()
        // Computed on the main actor first — the client closure is @Sendable.
        let sessionEntries = [first, second].flatMap { $0.splitRoot.allPanes() }.map {
            SessionInfo(name: $0.sessionName)
        }
        var alive = SessionClient.noop
        alive.isBundled = { true }
        alive.listSessions = { sessionEntries }
        state2.sessionClient = alive
        state2.incubatePane = { _ in }
        state2.restorePinnedState(fx.savedRecords)
        await state2.materializeRestoredPinnedTabs()

        let pinned2 = try #require(state2.pinnedProjectID)
        #expect(state2.model.activeTabID(of: pinned2) == second.id)
    }

    @Test
    func dragging_an_unloaded_record_into_a_project_spawns_it_there() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(name: "dev", layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        )]

        fx.state.moveTab(recordID, from: fx.pinnedID, to: p.id, destPath: p.path)

        #expect(fx.state.pinnedRecords.isEmpty)
        let moved = try #require(fx.state.liveTabs[p.id]?.tabs.first { $0.id == recordID })
        #expect(moved.splitRoot.allPanes().first?.start == .typed("btop"))
        #expect(moved.splitRoot.allPanes().first?.projectID == p.id)
    }

    @Test
    func reorderTab_in_pinned_moves_the_record_too() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let first = ws.tabs[0]
        let second = try addTab(fx.state, in: p)
        fx.state.pinTab(first.id, fromProject: p.id)
        fx.state.pinTab(second.id, fromProject: p.id)

        // The CLI's live-tab drop offset: move `second` to the front.
        fx.state.reorderTab(second.id, inProject: fx.pinnedID, toIndex: 0)

        #expect(fx.state.pinnedRecords.map(\.id) == [second.id, first.id])
        #expect(fx.pinned?.tabs.map(\.id) == [second.id, first.id])
    }

    @Test
    func moveActiveTab_in_pinned_steps_past_one_sidebar_row() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        // An UNLOADED record below the loaded tab: one step down passes it.
        let unloadedID = UUID()
        fx.state.pinnedRecords.append(PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(name: "idle", layout: .pane(LayoutPane(cwd: "/tmp"))),
            originProjectID: nil
        ))
        fx.state.writer.tabPeek(tab.id, in: fx.pinnedID)

        #expect(fx.state.activeTabMoveOffset(step: -1, projectID: fx.pinnedID) == nil)
        fx.state.moveActiveTab(step: 1, projectID: fx.pinnedID)
        #expect(fx.state.pinnedRecords.map(\.id) == [unloadedID, tab.id])
        #expect(fx.state.activeTabMoveOffset(step: 1, projectID: fx.pinnedID) == nil)
        fx.state.moveActiveTab(step: -1, projectID: fx.pinnedID)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id, unloadedID])
    }

    @Test
    func selectTabByIndex_in_pinned_counts_sidebar_rows() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        // An UNLOADED record ahead of the loaded tab: index 0 must reach it.
        let unloadedID = UUID()
        fx.state.pinnedRecords.insert(PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        ), at: 0)

        fx.state.selectTabByIndex(0, projectID: fx.pinnedID)

        #expect(fx.pinned?.activeTabID == unloadedID)
        #expect(fx.state.isPinnedTabLoaded(unloadedID))
    }

    @Test
    func project_cycling_steps_through_the_pinned_slot() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        #expect(fx.state.activeProjectID == fx.pinnedID)

        fx.state.selectNextProject(projects: [p])
        #expect(fx.state.activeProjectID == p.id)

        fx.state.selectPreviousProject(projects: [p])
        #expect(fx.state.activeProjectID == fx.pinnedID)
    }

    @Test
    func write_time_absorption_adopts_the_files_order() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let a = ws.tabs[0]
        let b = try addTab(fx.state, in: p)
        fx.state.pinTab(a.id, fromProject: p.id)
        fx.state.pinTab(b.id, fromProject: p.id)
        fx.state.pinnedRecords[0].declaration = LayoutTab(name: "a", layout: .pane(LayoutPane(cwd: "/tmp")))
        fx.state.pinnedRecords[1].declaration = LayoutTab(name: "b", layout: .pane(LayoutPane(cwd: "/tmp")))

        // Hand-reorder the file while the app runs, then trigger a write.
        try fx.state.pinnedLayoutStore.write(tabs: [
            fx.state.pinnedRecords[1].declaration,
            fx.state.pinnedRecords[0].declaration,
        ])
        fx.state.writePinnedLayout()

        #expect(fx.state.pinnedRecords.map(\.declaration.name) == ["b", "a"])
        #expect(fx.pinned?.tabs.map(\.id) == [b.id, a.id])
    }

    @Test
    func quit_never_creates_pinned_yaml_for_users_who_never_pinned() {
        let fx = makeFixture()
        _ = seedProject(fx.state)
        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        fx.state.persistForTermination()

        #expect(!FileManager.default.fileExists(atPath: fx.state.pinnedLayoutStore.fileURL.path))
    }

    @Test
    func separated_pane_lands_at_the_record_slot_the_drop_named() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        // An unloaded record occupies row 0; the drop names slot 1 (below it).
        let unloadedID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(name: "sleeper", layout: .pane(LayoutPane(cwd: "/tmp"))),
            originProjectID: nil
        )]
        fx.state.ensurePinnedProject()
        let paneID = try split(fx.state, tab)

        fx.state.separatePaneIntoPinned(paneID, atRecordIndex: 1)

        #expect(fx.state.pinnedRecords.count == 2)
        #expect(fx.state.pinnedRecords[0].id == unloadedID)
        #expect(fx.state.pinnedRecords[1].id != unloadedID)
    }

    // MARK: - pinned.yaml reconcile / absorb

    @Test
    func launch_reconcile_adds_file_entries_as_unloaded_records() throws {
        let fx = makeFixture()
        try fx.state.pinnedLayoutStore.write(tabs: [
            LayoutTab(name: "hand-added", layout: .pane(LayoutPane(cwd: "~/dev", run: "btop"))),
        ])

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.count == 1)
        #expect(fx.state.pinnedRecords.first?.declaration.name == "hand-added")
        #expect(fx.state.isPinnedTabLoaded(fx.state.pinnedRecords[0].id) == false)
    }

    @Test
    func launch_reconcile_drops_unloaded_records_removed_from_file() throws {
        let fx = makeFixture()
        let keep = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "keep", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        let removed = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "removed", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [keep, removed]
        try fx.state.pinnedLayoutStore.write(tabs: [keep.declaration])

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.map(\.id) == [keep.id])
    }

    @Test
    func launch_reconcile_unpins_restorable_live_tab_removed_from_file() throws {
        let fx = makeFixture()
        // The GUI state is written only after the launch restore.
        fx.state.restoreSelection(projects: [])
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.persistState()

        // Next launch: the user deleted the entry while the app was closed.
        let state2 = fx.relaunch()
        state2.sessionClient = .noop
        try state2.pinnedLayoutStore.write(tabs: [])
        state2.restorePinnedState(fx.savedRecords)

        state2.reconcilePinnedLayoutAtLaunch(projects: [p])

        #expect(state2.pinnedRecords.isEmpty)
        // Honored as a MOVE: the tab landed in its origin project.
        #expect(state2.liveTabs[p.id]?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func launch_reconcile_absent_file_keeps_records_and_materializes_file() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "mine", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [record]

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.map(\.id) == [record.id])
        #expect(FileManager.default.fileExists(atPath: fx.state.pinnedLayoutStore.fileURL.path))
    }

    @Test
    func invalid_pinned_yaml_suspends_writes_and_preserves_the_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id) // creates a valid file

        // The user breaks the file mid-edit.
        let broken = "path: <pinned>\ntabs: [ not yaml {"
        try broken.write(to: fx.state.pinnedLayoutStore.fileURL, atomically: true, encoding: .utf8)

        // A membership change would normally rewrite — it must not clobber.
        fx.state.unpinTab(tab.id, projects: [p])

        #expect(fx.state.pinnedLayoutSuspended)
        let onDisk = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(onDisk == broken)
    }

    @Test
    func external_addition_is_absorbed_before_the_next_write() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let first = ws.tabs[0]
        let second = try addTab(fx.state, in: p)
        fx.state.pinTab(first.id, fromProject: p.id)

        // Hand-edit while running: append an entry. The existing entry is
        // matched back by content (no wire-level ids).
        try fx.state.pinnedLayoutStore.write(tabs: [
            fx.state.pinnedRecords[0].declaration,
            LayoutTab(name: "external", layout: .pane(LayoutPane(run: "htop"))),
        ])

        // Next membership change triggers a write, which absorbs first.
        fx.state.pinTab(second.id, fromProject: p.id)

        #expect(fx.state.pinnedRecords.count == 3)
        #expect(fx.state.pinnedRecords.contains { $0.declaration.name == "external" })
        // The absorbed entry survived the rewrite too.
        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("external"))
    }

    // MARK: - Keyboard navigation

    @Test
    func nextTabInProject_cycles_pinned_records_and_restores_unloaded_ones() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.liveTabs[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let unloadedID = UUID()
        fx.state.pinnedRecords.append(PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        ))

        fx.state.selectNextTab(projectID: fx.pinnedID)

        // Landed on the unloaded record and restored it.
        #expect(fx.pinned?.activeTabID == unloadedID)
        #expect(fx.state.isPinnedTabLoaded(unloadedID))

        fx.state.selectPreviousTab(projectID: fx.pinnedID)
        #expect(fx.pinned?.activeTabID == tab.id)
    }

    // MARK: - Global cycling

    @Test
    func selectGlobalTab_cycles_through_pinned_first() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.liveTabs[p.id])
        let pinnedTab = ws.tabs[0]
        let projectTab = try addTab(fx.state, in: p)
        fx.state.pinTab(pinnedTab.id, fromProject: p.id)
        fx.state.selectPinnedTab(pinnedTab.id)

        fx.state.selectGlobalTab(.next, projects: [p])

        #expect(fx.state.activeProjectID == p.id)
        #expect(fx.state.liveTabs[p.id]?.activeTabID == projectTab.id)

        fx.state.selectGlobalTab(.next, projects: [p])
        #expect(fx.state.activeProjectID == fx.pinnedID)
        #expect(fx.pinned?.activeTabID == pinnedTab.id)
    }
}
