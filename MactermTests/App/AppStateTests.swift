import CoreGraphics
import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateTests {
    // MARK: - Setup helpers

    /// Build an AppState with a temp-file workspace store and a temp-dir
    /// project-file store so tests don't touch the user's real App Support
    /// data or `~/.config/macterm/projects`.
    private func makeAppState(
        store: WorkspaceStore? = nil,
        projectFiles: ProjectFileStore? = nil
    ) -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        return AppState(
            workspaceStore: store ?? WorkspaceStore(fileURL: tmp),
            projectFiles: projectFiles ?? makeProjectFileStore()
        )
    }

    /// Fresh central project-file store rooted in a unique tempdir.
    private func makeProjectFileStore() -> ProjectFileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return ProjectFileStore(directoryURL: dir)
    }

    /// Create a project + workspace inside `state` and return the project.
    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    // MARK: - Tabs

    @Test
    func createTab_uses_selected_directory_and_preserves_project_session_slug() throws {
        let state = makeAppState()
        state.newTabInheritsWorkingDirectory = { true }
        let localProject = seedProject(state, path: "/project")
        let localWorkspace = try #require(state.workspaces[localProject.id])
        let activePane = try #require(localWorkspace.activeTab?.focusedPane)
        SurfaceRegistry.shared.ensureView(of: activePane).currentPwd = "/project/src"

        state.createTab(projectID: localProject.id, projects: [localProject])

        #expect(localWorkspace.activeTab?.focusedPane?.projectPath == "/project/src")
        #expect(localWorkspace.activeTab?.focusedPane?.sessionSlug == "project")

        let inheritedPane = try #require(localWorkspace.activeTab?.focusedPane)
        SurfaceRegistry.shared.ensureView(of: inheritedPane).currentPwd = "/project/src/deep"
        state.newTabInheritsWorkingDirectory = { false }

        state.createTab(projectID: localProject.id, projects: [localProject])

        #expect(localWorkspace.activeTab?.focusedPane?.projectPath == localProject.path)
        #expect(localWorkspace.activeTab?.focusedPane?.sessionSlug == "project")
    }

    @Test
    func createTab_in_an_explicit_directory_keeps_the_project_session_slug() throws {
        // The sidebar's Worktrees menu roots a tab in a worktree beside the
        // project: the pane starts there, but its zmx session still groups
        // under the project, like every other tab the project owns.
        let state = makeAppState()
        let project = seedProject(state, path: "/project")
        let workspace = try #require(state.workspaces[project.id])

        let tabID = try #require(state.createTab(
            projectID: project.id,
            projects: [project],
            workingDirectory: "/project-feature"
        ))

        #expect(workspace.activeTabID == tabID)
        let pane = try #require(workspace.activeTab?.focusedPane)
        #expect(pane.projectPath == "/project-feature")
        #expect(pane.sessionSlug == "project")
        #expect(pane.sessionName.hasPrefix("macterm-project-"))
    }

    @Test
    func createTab_remote_active_pane_falls_back_to_project_directory() throws {
        let state = makeAppState()
        state.newTabInheritsWorkingDirectory = { true }
        let remoteProject = seedProject(state, path: "devbox:~/repo")
        let remoteWorkspace = try #require(state.workspaces[remoteProject.id])

        state.createTab(projectID: remoteProject.id, projects: [remoteProject])

        #expect(remoteWorkspace.activeTab?.focusedPane?.projectPath == remoteProject.path)
    }

    /// Environment forwarding (text-file editors) and no-focus creation must
    /// compose through every creation layer; both extend the same APIs.
    @Test(arguments: ["tab", "split"], [false, true])
    func creation_preserves_environment_with_either_focus_policy(kind: String, focus: Bool) throws {
        let state = makeAppState()
        let project = seedProject(state)
        let workspace = try #require(state.workspaces[project.id])
        let originalTab = try #require(workspace.activeTab)
        let source = try #require(originalTab.focusedPane)
        let environment = ["MACTERM_TEST_ENV": "literal $value with spaces"]
        var warmed: [Pane] = []
        state.incubatePane = { warmed.append($0) }

        let created: Pane
        if kind == "tab" {
            let tabID = try #require(state.createTab(
                projectID: project.id, projects: [project], command: .typed("test-command"),
                env: environment, focus: focus
            ))
            let tab = try #require(workspace.tabs.first { $0.id == tabID })
            created = try #require(tab.focusedPane)
            #expect(workspace.activeTabID == (focus ? tabID : originalTab.id))
        } else {
            let paneID = try #require(state.splitPane(
                source.id, direction: .horizontal, projectID: project.id,
                projectDirectory: project.path, command: .typed("test-command"),
                env: environment, focus: focus
            ))
            created = try #require(originalTab.splitRoot.findPane(id: paneID))
            #expect(originalTab.focusedPaneID == (focus ? paneID : source.id))
        }
        #expect(created.env == environment)
        #expect(created.start == .typed("test-command"))
        #expect(warmed.map(\.id) == (focus ? [] : [created.id]))
    }

    // MARK: - Splits

    @Test
    func splitPane_adds_pane_and_focuses_it() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        #expect(tab.splitRoot.allPanes().count == 2)
        #expect(tab.focusedPaneID != before)
    }

    // MARK: - Two panes on one session

    @Test
    func a_pane_leads_until_its_session_says_it_does_not() throws {
        // The session decides leadership. Before its first `lead` message a
        // surface counts as the leader, so a new pane never blurs.
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)

        #expect(state.isLeader(pane))
        #expect(state.nonLeaderPaneIDs(in: tab).isEmpty)

        SurfaceRegistry.shared.surfaces(of: pane)[0].receiveLead(false)
        #expect(!state.isLeader(pane))
        #expect(state.nonLeaderPaneIDs(in: tab) == [pane.id])

        SurfaceRegistry.shared.surfaces(of: pane)[0].receiveLead(true)
        #expect(state.isLeader(pane))
        #expect(state.nonLeaderPaneIDs(in: tab).isEmpty)
    }

    /// One pane that two windows draw. Window `a` is key, but the session
    /// made `b`'s surface lead, as when the user typed there.
    private struct TwoWindows {
        let project: Project
        let tab: TerminalTab
        let pane: Pane
        let a: WindowState
        let b: WindowState
        let forA: PaneSurface
        let forB: PaneSurface
    }

    private func paneInTwoWindows(
        _ state: AppState,
        _ session: FakeSessionLeads,
        path: String = "/tmp"
    ) throws -> TwoWindows {
        let p = seedProject(state, name: "proj", path: path)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: p.id)
        let b = WindowState(activeProjectID: p.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = SurfaceRegistry.shared.surface(for: pane, in: .window(a.id))
        let forB = SurfaceRegistry.shared.surface(for: pane, in: .window(b.id))
        session.attach([forB, forA])
        session.claimed = []
        return TwoWindows(project: p, tab: tab, pane: pane, a: a, b: b, forA: forA, forB: forB)
    }

    @Test
    func a_surface_that_the_session_does_not_make_leader_is_blurred_in_its_window() throws {
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session)

        #expect(state.isMirrored(two.pane))
        #expect(two.forB.isLeader)
        #expect(!state.isLeader(two.pane), "the reference surface is the first window's")
        #expect(state.nonLeaderPaneIDs(in: two.tab, window: two.a.id) == [two.pane.id])
        #expect(state.nonLeaderPaneIDs(in: two.tab, window: two.b.id).isEmpty)
    }

    @Test
    func focusing_a_pane_claims_leadership_for_its_surface_in_that_window() throws {
        // Focus is how the user says "drive the size from here".
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session)

        state.focusPane(two.pane.id, projectID: two.project.id, windowID: two.a.id)

        #expect(session.claimed == [two.forA.id])
        #expect(two.forA.isLeader)
        #expect(!two.forB.isLeader)
        #expect(state.nonLeaderPaneIDs(in: two.tab, window: two.b.id) == [two.pane.id])

        // And back again in the other window: leadership does not latch.
        state.noteKeyWindow(two.b)
        state.focusPane(two.pane.id, projectID: two.project.id, windowID: two.b.id)
        #expect(two.forB.isLeader)
        #expect(!two.forA.isLeader)
    }

    @Test
    func an_undelivered_claim_leaves_leadership_where_the_session_has_it() throws {
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session)

        session.deliverable = false
        state.claimSessionLeadership(two.forA)
        #expect(two.forB.isLeader)
        #expect(!two.forA.isLeader)

        session.deliverable = true
        state.claimSessionLeadership(two.forA)
        #expect(two.forA.isLeader)
    }

    @Test
    func a_claim_is_not_sent_for_a_surface_that_leads() throws {
        // `mouseDown` reports focus twice per click, and `FocusRestoration`
        // retries across run-loop ticks: a surface that leads sends nothing.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session)

        state.claimSessionLeadership(two.forB)
        #expect(session.claimed.isEmpty)

        state.claimSessionLeadership(two.forA)
        state.claimSessionLeadership(two.forA)
        state.claimSessionLeadership(two.forA)
        #expect(session.claimed == [two.forA.id])
    }

    @Test
    func a_claim_is_sent_once_until_the_session_answers() throws {
        // The session answers a network trip later. The focus reports in the
        // meantime send nothing more.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session)
        session.answers = false

        state.claimSessionLeadership(two.forA)
        state.claimSessionLeadership(two.forA)
        #expect(session.claimed == [two.forA.id])

        // The channel ended before the answer: the claim may be lost, so the
        // next focus sends it again.
        two.forA.receiveLead(nil)
        state.claimSessionLeadership(two.forA)
        #expect(session.claimed == [two.forA.id, two.forA.id])
    }

    @Test
    func focusing_a_remote_pane_claims_as_a_local_one_does() throws {
        // A remote pane is a session of the host's server, and the claim is a
        // message on its channel, never input. So it claims as a local pane.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session, path: "me@box:/srv")
        #expect(two.pane.isRemote)

        state.focusPane(two.pane.id, projectID: two.project.id, windowID: two.a.id)

        #expect(session.claimed == [two.forA.id])
        #expect(two.forA.isLeader)
        #expect(!two.forB.isLeader)
    }

    @Test
    func closing_the_window_whose_surface_leads_sends_no_claim() throws {
        // When the leader leaves, the session makes the next client lead and
        // tells it. A closed window that was not key makes the app send
        // nothing.
        let state = makeAppState()
        let session = FakeSessionLeads(state)
        let two = try paneInTwoWindows(state, session)

        state.unregisterWindow(two.b)
        #expect(session.claimed.isEmpty)

        // The session makes the client that remains lead, and says so.
        two.forA.receiveLead(true)
        #expect(state.isLeader(two.pane))
        #expect(state.nonLeaderPaneIDs(in: two.tab, window: two.a.id).isEmpty)
    }

    @Test
    func busy_project_paths_stage_confirmation_through_the_shared_guard() {
        let state = makeAppState()
        state.paneNeedsConfirmClose = { _ in true }
        let p = seedProject(state)

        var removed = false
        state.requestRemoveProject(p.id) { removed = true }
        #expect(!removed)
        #expect(state.pendingDialog?.kind == .removeProject(p.id))
        state.dismissPendingDialog()

        state.requestRemoveSelection(projectIDs: [p.id], tabs: []) { removed = true }
        #expect(!removed)
        #expect(state.pendingDialog?.kind == .removeSelection)

        // An unknown project has no panes and so nothing to confirm.
        #expect(state.panes(inProject: UUID()).isEmpty)
    }

    @Test
    func sidebar_rename_refuses_the_pinned_workspaces_name_with_a_notice() throws {
        // The sidebar's half of `project rename`'s refusal: its field has
        // already closed, so the notice is what says why the name didn't take.
        let state = makeAppState()
        let store = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-rename-\(UUID().uuidString).json"))
        let project = store.create(name: "alpha", path: "/tmp")

        state.renameProject(project.id, to: "pinned", store: store)
        #expect(store.projects.first?.name == "alpha")
        let notice = try #require(state.pendingDialog)
        #expect(notice.kind == .refusedProjectName)
        #expect(notice.confirmTitle == nil)
        #expect(notice.message == PinnedTabs.reservedNameMessage)
        state.dismissPendingDialog()

        state.renameProject(project.id, to: "beta", store: store)
        #expect(store.projects.first?.name == "beta")
        #expect(state.pendingDialog == nil)
    }

    @Test
    func sidebar_rename_refuses_a_slash_with_a_notice() throws {
        let state = makeAppState()
        let store = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-rename-\(UUID().uuidString).json"))
        let project = store.create(name: "alpha", path: "/tmp")

        state.renameProject(project.id, to: "Work/api", store: store)
        #expect(store.projects.first?.name == "alpha")
        let notice = try #require(state.pendingDialog)
        #expect(notice.kind == .refusedProjectName)
        #expect(notice.message == Project.slashMessage)
    }

    @Test
    func splitPane_uses_selected_directory() throws {
        let state = makeAppState()
        state.newSplitInheritsWorkingDirectory = { true }
        let project = seedProject(state, path: "/project")
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let activePane = try #require(tab.focusedPane)
        SurfaceRegistry.shared.ensureView(of: activePane).currentPwd = "/project/src"

        state.splitPane(direction: .horizontal, projectID: project.id, projects: [project])

        #expect(tab.focusedPane?.projectPath == "/project/src")

        let inheritedPane = try #require(tab.focusedPane)
        SurfaceRegistry.shared.ensureView(of: inheritedPane).currentPwd = "/project/src/deep"
        state.newSplitInheritsWorkingDirectory = { false }

        state.splitPane(direction: .vertical, projectID: project.id, projects: [project])

        #expect(tab.focusedPane?.projectPath == project.path)
    }

    /// "Active pane" with no usable LOCAL cwd must fall through to the source
    /// pane's own `projectPath`, NOT to the project root: a remote pane
    /// coerced to the project directory loses its declared subdirectory, and
    /// one whose tab was moved into a local project would spawn a LOCAL shell
    /// instead of a remote zmx sibling.
    @Test
    func splitPane_remote_source_inherits_its_own_path_not_the_project_root() throws {
        let state = makeAppState()
        state.newSplitInheritsWorkingDirectory = { true }
        let project = seedProject(state, path: "devbox:~/repo")
        state.createTab(projectID: project.id, projectPath: "devbox:~/repo/sub")
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        #expect(tab.focusedPane?.projectPath == "devbox:~/repo/sub")

        state.splitPane(direction: .horizontal, projectID: project.id, projects: [project])

        #expect(tab.focusedPane?.projectPath == "devbox:~/repo/sub")
        #expect(tab.focusedPane?.isRemote == true)
    }

    /// A grid honors the split directory preference, so `macterm grid` and a
    /// `Cmd+D` split off the same pane can't disagree about it.
    @Test
    func makeGrid_uses_selected_directory() throws {
        let state = makeAppState()
        state.newSplitInheritsWorkingDirectory = { false }
        let project = seedProject(state, path: "/project")
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let source = try #require(tab.focusedPane)
        SurfaceRegistry.shared.ensureView(of: source).currentPwd = "/project/src"

        let created = state.makeGrid(
            source.id,
            rows: 2,
            columns: 2,
            projectID: project.id,
            projectDirectory: project.path
        )

        #expect(created.count == 3)
        for id in created {
            #expect(tab.splitRoot.findPane(id: id)?.projectPath == "/project")
        }
    }

    @Test
    func splitPane_no_focused_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        ModelWriter.tabSetTree(tab, root: tab.splitRoot, focusedPaneID: nil)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    @Test
    func adaptiveBackgroundColor_updatesOwnedPaneOnly() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        let color = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        state.setAdaptiveBackgroundColor(color, paneID: pane.id, projectID: project.id)
        #expect(SurfaceRegistry.shared.surface(for: pane, in: .incubator).adaptiveBackgroundColor == color)

        let otherProject = seedProject(state, name: "other", path: "/tmp/other")
        state.setAdaptiveBackgroundColor(nil, paneID: pane.id, projectID: otherProject.id)
        #expect(SurfaceRegistry.shared.surface(for: pane, in: .incubator).adaptiveBackgroundColor == color)

        state.setAdaptiveBackgroundColor(nil, paneID: UUID(), projectID: project.id)
        #expect(SurfaceRegistry.shared.surface(for: pane, in: .incubator).adaptiveBackgroundColor == color)

        state.setAdaptiveBackgroundColor(nil, paneID: pane.id, projectID: project.id)
        #expect(SurfaceRegistry.shared.surface(for: pane, in: .incubator).adaptiveBackgroundColor == nil)
    }

    // MARK: - Close pane

    @Test
    func closePane_last_pane_closes_the_whole_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let originalTab = try #require(ws.activeTab)
        let onlyPane = try #require(originalTab.focusedPaneID)
        // Add a second tab so closing the original doesn't leave us with zero.
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let otherTab = try #require(ws.activeTabID)

        // Focus the original tab, then close its only pane.
        ModelWriter.tabSelect(originalTab.id, in: ws)
        state.closePane(onlyPane, projectID: p.id)

        #expect(ws.tabs.count == 1)
        #expect(ws.activeTabID == otherTab)
    }

    @Test
    func closePane_middle_pane_removes_from_tree() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        #expect(tab.splitRoot.allPanes().count == 2)
        let target = try #require(tab.focusedPaneID)
        state.closePane(target, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 1)
        #expect(tab.focusedPaneID != target)
    }

    /// Integration-level regression: HV-close on the active tab via AppState.
    @Test
    func closePane_HV_close_regression() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)

        // Replace splitRoot with a known HV shape.
        let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
        ModelWriter.tabSetTree(tab, root: tree, focusedPaneID: ids["l1"])

        try state.closePane(#require(ids["l1"]), projectID: p.id)

        #expect(render(tab.splitRoot, ids: ids) == "V(r1, r2)")
        let remaining = Set(tab.splitRoot.allPanes().map(\.id))
        #expect(try remaining == [#require(ids["r1"]), #require(ids["r2"])])
    }

    @Test
    func closePane_from_non_active_tab_still_works() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let originalTab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let targetInOriginal = try #require(originalTab.focusedPaneID)

        // Switch to a new tab, then close a pane on the (now non-active) original.
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        #expect(ws.activeTabID != originalTab.id)
        state.closePane(targetInOriginal, projectID: p.id)
        #expect(originalTab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Move tab between projects

    @Test
    func moveTab_relocates_tab_and_activates_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        // Give p1 a second tab so moving one away doesn't empty it.
        let moving = ModelWriter.tabCreate(in: ws1, projectPath: "/tmp1")
        let staying = try #require(ws1.tabs.first?.id)

        state.moveTab(moving.id, from: p1.id, to: p2.id, destPath: p2.path)

        // Source lost the tab; destination gained it (object reused, surfaces intact).
        #expect(ws1.tabs.map(\.id) == [staying])
        let ws2 = try #require(state.workspaces[p2.id])
        #expect(ws2.tabs.contains { $0.id == moving.id })
        // Destination is now active with the moved tab selected.
        #expect(state.activeProjectID == p2.id)
        #expect(ws2.activeTabID == moving.id)
    }

    @Test
    func moveTab_leaves_source_workspace_empty_when_moving_its_only_tab() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let only = try #require(ws1.tabs.first?.id)

        state.moveTab(only, from: p1.id, to: p2.id, destPath: p2.path)

        #expect(ws1.tabs.isEmpty)
        #expect(ws1.activeTabID == nil)
        #expect(state.workspaces[p2.id]?.tabs.contains { $0.id == only } == true)
    }

    @Test
    func moveTab_creates_destination_workspace_when_absent() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let ws1 = try #require(state.workspaces[p1.id])
        let tab = ModelWriter.tabCreate(in: ws1, projectPath: "/tmp1")
        // A project that's never been opened — no workspace yet.
        let p2 = Project(name: "p2", path: "/tmp2", sortOrder: 1)
        #expect(state.workspaces[p2.id] == nil)

        state.moveTab(tab.id, from: p1.id, to: p2.id, destPath: p2.path)

        let ws2 = try #require(state.workspaces[p2.id])
        #expect(ws2.tabs.contains { $0.id == tab.id })
    }

    @Test
    func moveTab_same_project_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let before = ws.tabs.map(\.id)
        try state.moveTab(#require(before.first), from: p.id, to: p.id, destPath: p.path)
        #expect(ws.tabs.map(\.id) == before)
    }

    @Test
    func moveTab_unknown_tab_is_noop() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws2Before = try #require(state.workspaces[p2.id]).tabs.count
        state.moveTab(UUID(), from: p1.id, to: p2.id, destPath: p2.path)
        #expect(state.workspaces[p2.id]?.tabs.count == ws2Before)
    }

    // MARK: - Merge a tab into the workspace's active tab (#227)

    @Test
    func mergeTab_at_pane_target_splits_in_zone_direction() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let destTab = try #require(ws.activeTab)
        let destPane = try #require(destTab.splitRoot.allPanes().first?.id)
        let sourceTab = ModelWriter.tabCreate(in: ws, projectPath: p.path)
        let sourcePane = try #require(sourceTab.splitRoot.allPanes().first?.id)
        ModelWriter.tabSelect(destTab.id, in: ws)

        state.mergeTab(sourceTab.id, from: p.id, at: .pane(destPane, .top), inProject: p.id)

        #expect(ws.tabs.map(\.id) == [destTab.id])
        // .top means the source lands first in a vertical split.
        #expect(destTab.splitRoot.allPanes().map(\.id) == [sourcePane, destPane])
        guard case let .split(branch) = destTab.splitRoot else {
            Issue.record("expected a split root")
            return
        }
        #expect(branch.direction == .vertical)
    }

    @Test
    func mergeTab_at_rootEdge_equalizes_to_thirds() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let destTab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let sourceTab = ModelWriter.tabCreate(in: ws, projectPath: p.path)
        ModelWriter.tabSelect(destTab.id, in: ws)

        state.mergeTab(sourceTab.id, from: p.id, at: .rootEdge(.left), inProject: p.id)

        // Side-by-side-by-side: every column takes an even third.
        let frames = destTab.splitRoot.paneFrames()
        #expect(frames.count == 3)
        for frame in frames.values {
            #expect(abs(frame.width - 1.0 / 3.0) < 0.001)
        }
    }

    @Test
    func mergeTab_when_active_tab_is_source_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.mergeTab(tab.id, from: p.id, at: .rootEdge(.bottom), inProject: p.id)
        #expect(ws.tabs.count == 1)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Separate panes (#227)

    @Test
    func separateTabPanes_gives_each_pane_its_own_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        state.splitPane(direction: .vertical, projectID: p.id, projects: [p])
        let panes = tab.splitRoot.allPanes().map(\.id)
        #expect(panes.count == 3)

        state.separateTabPanes(tab.id, projectID: p.id)

        // One tab per pane, inserted right after the source in tree order;
        // the source keeps the first pane and stays selected.
        #expect(ws.tabs.count == 3)
        #expect(ws.tabs.first?.id == tab.id)
        #expect(tab.splitRoot.allPanes().map(\.id) == [panes[0]])
        #expect(tab.focusedPaneID == panes[0])
        #expect(ws.tabs.map { $0.splitRoot.allPanes().map(\.id) } == panes.map { [$0] })
        #expect(ws.activeTabID == tab.id)
    }

    @Test
    func separateTabPanes_single_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.separateTabPanes(tab.id, projectID: p.id)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Separate one pane into its own tab (Separate Current Pane)

    @Test
    func separatePane_splits_the_pane_into_its_own_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let original = try #require(tab.focusedPaneID)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let dragged = try #require(tab.focusedPaneID)
        ModelWriter.paneZoom(tab, toggling: dragged)

        state.separatePane(dragged, toProject: p.id, destPath: p.path)

        // The source tab keeps its remaining pane, exits the stale zoom, and
        // repairs focus; the dragged Pane object lives on in the new tab.
        #expect(tab.splitRoot.allPanes().map(\.id) == [original])
        #expect(tab.zoomedPaneID == nil)
        #expect(tab.focusedPaneID == original)
        #expect(ws.tabs.count == 2)
        let newTab = try #require(ws.tabs.last)
        #expect(newTab.splitRoot.allPanes().map(\.id) == [dragged])
        #expect(newTab.focusedPaneID == dragged)
        #expect(ws.activeTabID == newTab.id)
    }

    @Test
    func separatePane_at_index_lands_at_that_slot() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let dragged = try #require(tab.focusedPaneID)

        state.separatePane(dragged, toProject: p.id, destPath: p.path, at: 0)

        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.first?.splitRoot.allPanes().map(\.id) == [dragged])
        #expect(ws.tabs.last?.id == tab.id)
    }

    @Test
    func separatePane_across_projects_rebinds_and_activates_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let ws2 = try #require(state.workspaces[p2.id])
        state.selectProject(p1)
        state.splitPane(direction: .horizontal, projectID: p1.id, projects: [p1])
        let sourceTab = try #require(ws1.activeTab)
        let dragged = try #require(sourceTab.focusedPaneID)
        let ws2TabsBefore = ws2.tabs.count

        state.separatePane(dragged, toProject: p2.id, destPath: p2.path)

        #expect(sourceTab.splitRoot.allPanes().count == 1)
        #expect(ws2.tabs.count == ws2TabsBefore + 1)
        let newTab = try #require(ws2.tabs.last)
        #expect(newTab.splitRoot.allPanes().map(\.id) == [dragged])
        // Routing identity follows the pane, mirroring moveTab's rebind.
        #expect(newTab.splitRoot.allPanes().allSatisfy { $0.projectID == p2.id })
        #expect(state.activeProjectID == p2.id)
        #expect(ws2.activeTabID == newTab.id)
    }

    @Test
    func separatePane_only_pane_of_its_tab_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let onlyPane = try #require(tab.focusedPaneID)
        state.separatePane(onlyPane, toProject: p.id, destPath: p.path)
        #expect(ws.tabs.count == 1)
        #expect(tab.splitRoot.allPanes().map(\.id) == [onlyPane])
    }

    @Test
    func separatePane_unknown_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        state.separatePane(UUID(), toProject: p.id, destPath: p.path)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Project-scoped tab navigation

    @Test
    func selectNextTab_wraps_within_the_project() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let other = seedProject(state, name: "other", path: "/tmp/other")
        let ws = try #require(state.workspaces[p.id])
        let first = try #require(ws.activeTabID)
        let second = ModelWriter.tabCreate(in: ws, projectPath: p.path).id
        // Seed a tab in the sibling project so a leak across projects would show.
        _ = try #require(state.workspaces[other.id]?.activeTabID)
        state.activeProjectID = p.id
        ModelWriter.tabSelect(first, in: ws)

        state.selectNextTab(projectID: p.id)
        #expect(ws.activeTabID == second)
        // At the last tab it wraps to the first rather than crossing over.
        state.selectNextTab(projectID: p.id)
        #expect(ws.activeTabID == first)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func selectPreviousTab_wraps_within_the_project() throws {
        let state = makeAppState()
        let p = seedProject(state)
        _ = seedProject(state, name: "other", path: "/tmp/other")
        let ws = try #require(state.workspaces[p.id])
        let first = try #require(ws.activeTabID)
        let second = ModelWriter.tabCreate(in: ws, projectPath: p.path).id
        state.activeProjectID = p.id
        ModelWriter.tabSelect(first, in: ws)

        // At the first tab it wraps to the last rather than crossing over.
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == second)
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == first)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func selectNextTab_single_tab_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let only = try #require(ws.activeTabID)
        state.selectNextTab(projectID: p.id)
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == only)
    }

    // MARK: - Focus navigation

    @Test
    func focusPaneInDirection_right_in_horizontal_split() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        ModelWriter.tabSetTree(tab, root: tree, focusedPaneID: ids["a"])
        state.focusPaneInDirection(.right, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
    }

    @Test
    func focusPaneInDirection_no_neighbor_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.focusPaneInDirection(.right, projectID: p.id)
        #expect(tab.focusedPaneID == before)
    }

    @Test
    func cyclePane_forward_advances_in_tree_order() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        ModelWriter.tabSetTree(tab, root: tree, focusedPaneID: ids["a"])
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["c"])
    }

    @Test
    func cyclePane_forward_wraps_at_end() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        ModelWriter.tabSetTree(tab, root: tree, focusedPaneID: ids["b"])
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["a"])
    }

    @Test
    func cyclePane_backward_wraps_at_start() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        ModelWriter.tabSetTree(tab, root: tree, focusedPaneID: ids["a"])
        state.cyclePane(forward: false, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
    }

    @Test
    func cyclePane_single_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == before)
    }

    // MARK: - Project lifecycle

    @Test
    func removeProject_drops_workspace_and_clears_active_when_matching() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)
        state.removeProject(p.id)
        #expect(state.workspaces[p.id] == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test
    func removeProject_leaves_active_alone_when_not_matching() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // p2 is active; remove p1.
        state.removeProject(p1.id)
        #expect(state.activeProjectID == p2.id)
    }

    @Test
    func two_projects_for_the_same_directory_get_independent_workspaces_and_sessions() throws {
        // Removing the one-project-per-directory constraint: distinct projects
        // may share a path yet keep wholly separate workspaces (keyed on
        // Project.id) and non-colliding zmx sessions (per-pane hex entropy).
        let state = makeAppState()
        let a = seedProject(state, name: "a", path: "/tmp/shared")
        let b = seedProject(state, name: "b", path: "/tmp/shared")

        #expect(a.id != b.id)
        let wsA = try #require(state.workspaces[a.id])
        let wsB = try #require(state.workspaces[b.id])
        #expect(wsA !== wsB)

        // Session names differ despite the shared path: the slug matches but
        // each pane's hex suffix comes from its own UUID.
        let nameA = try #require(wsA.activeTab?.splitRoot.allPanes().first?.sessionName)
        let nameB = try #require(wsB.activeTab?.splitRoot.allPanes().first?.sessionName)
        #expect(nameA != nameB)
    }

    // MARK: - Bulk removal (sidebar multi-select)

    @Test
    func removeProjects_drops_every_listed_workspace() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let p3 = seedProject(state, name: "p3", path: "/tmp3")

        state.removeProjects([p1.id, p3.id])

        #expect(state.workspaces[p1.id] == nil)
        #expect(state.workspaces[p3.id] == nil)
        #expect(state.workspaces[p2.id] != nil)
    }

    @Test
    func removeProjects_empty_list_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.removeProjects([])
        #expect(state.workspaces[p.id] != nil)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func closeTabs_closes_each_tab_across_projects() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let ws2 = try #require(state.workspaces[p2.id])
        // Two tabs in each so closing one doesn't empty the workspace.
        let close1 = ModelWriter.tabCreate(in: ws1, projectPath: "/tmp1")
        let keep1 = try #require(ws1.tabs.first?.id)
        let close2 = ModelWriter.tabCreate(in: ws2, projectPath: "/tmp2")
        let keep2 = try #require(ws2.tabs.first?.id)

        state.closeTabs([
            (tabID: close1.id, projectID: p1.id),
            (tabID: close2.id, projectID: p2.id),
        ])

        #expect(ws1.tabs.map(\.id) == [keep1])
        #expect(ws2.tabs.map(\.id) == [keep2])
    }

    @Test
    func requestRemoveSelection_runs_removal_immediately_when_no_pane_busy() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // No pane ever gets an NSView in tests, so nothing is "busy" — the
        // removal must run inline rather than staging a confirmation.
        var ran = false
        state.requestRemoveSelection(projectIDs: [p1.id, p2.id], tabs: []) { ran = true }

        #expect(ran)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func requestRemoveGroup_asks_only_when_the_group_has_projects() {
        let state = makeAppState()
        let group = Project(name: "g", path: "")

        var ran = false
        state.requestRemoveGroup(group, projectCount: 0) { ran = true }
        #expect(ran, "an empty group goes at once")
        #expect(state.pendingDialog == nil)

        ran = false
        state.requestRemoveGroup(group, projectCount: 2) { ran = true }
        #expect(!ran)
        #expect(state.pendingDialog?.kind == .removeGroup(group.id))
        #expect(state.pendingDialog?.message.contains("2") == true, "the question says how many")
        state.confirmPendingDialog()
        #expect(ran)
    }

    @Test
    func pendingBulkRemove_confirm_and_cancel() {
        let state = makeAppState()
        // Every pane reads busy, so the selection stages instead of running.
        state.paneNeedsConfirmClose = { _ in true }
        let p = seedProject(state)

        var ran = false
        state.requestRemoveSelection(projectIDs: [p.id], tabs: []) { ran = true }
        #expect(state.pendingDialog?.kind == .removeSelection)
        state.dismissPendingDialog()
        #expect(state.pendingDialog == nil)
        #expect(!ran)

        state.requestRemoveSelection(projectIDs: [p.id], tabs: []) { ran = true }
        state.confirmPendingDialog()
        #expect(state.pendingDialog == nil)
        #expect(ran)
    }

    // MARK: - Attention (the session's flags)

    private let unseenFailure = MactermProtocol.Attention(unseen: true, failed: true)

    @Test
    func selecting_a_background_tab_marks_its_panes_seen() throws {
        let state = makeAppState()
        state.isAppActive = { true }
        let project = seedProject(state)
        let background = try #require(state.workspaces[project.id]?.activeTab)
        state.createTab(projectID: project.id, projects: [project])
        let pane = try #require(background.focusedPane)
        pane.receiveAttention(unseenFailure)

        state.markSeenIfActive(paneID: pane.id, projectID: project.id)
        #expect(background.completionFailed)

        state.selectTab(background.id, projectID: project.id)

        #expect(pane.attention == MactermProtocol.Attention())
        #expect(background.executionState == .idle)
    }

    @Test
    func selecting_a_project_marks_its_active_tab_seen() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        _ = seedProject(state, name: "p2", path: "/tmp2")
        let pane = try #require(state.workspaces[p1.id]?.activeTab?.focusedPane)
        pane.receiveAttention(unseenFailure)

        state.selectProject(p1)

        #expect(pane.attention == MactermProtocol.Attention())
    }

    @Test
    func the_active_tab_is_seen_only_while_the_app_is_active() throws {
        let state = makeAppState()
        state.paneIsInKeyWindow = { _ in true }
        state.isAppActive = { false }
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        pane.receiveAttention(unseenFailure)

        state.paneAttentionDidChange(paneID: pane.id)
        #expect(pane.attention == unseenFailure)

        state.isAppActive = { true }
        state.paneAttentionDidChange(paneID: pane.id)
        #expect(pane.attention == MactermProtocol.Attention())
    }

    /// The workspace's active tab can name a tab that the window does not
    /// draw (a selection made while the window was not key). A pane that is
    /// in no key window keeps its flags.
    @Test
    func a_pane_that_the_key_window_does_not_draw_is_not_seen() throws {
        let state = makeAppState()
        state.isAppActive = { true }
        state.paneIsInKeyWindow = { _ in false }
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        pane.receiveAttention(unseenFailure)

        state.paneAttentionDidChange(paneID: pane.id)
        state.markActiveTabSeenOnActivation()

        #expect(pane.attention == unseenFailure)
    }

    /// The quick terminal's tab is not in `workspaces`. Its focused pane is
    /// seen when the flags arrive while the panel is key, and the app need
    /// not be active (the panel is non-activating).
    @Test
    func the_focused_pane_of_a_key_quick_terminal_is_seen_when_its_flags_arrive() throws {
        let quick = QuickTerminalSplitState()
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")),
            projectFiles: makeProjectFileStore(),
            quickTerminal: quick
        )
        state.isAppActive = { false }
        var keyPaneIDs: Set<UUID> = []
        state.paneIsInKeyWindow = { keyPaneIDs.contains($0.id) }
        let pane = try #require(quick.focusedPaneID.flatMap { quick.splitRoot.findPane(id: $0) })

        pane.receiveAttention(unseenFailure)
        state.paneAttentionDidChange(paneID: pane.id)
        #expect(pane.attention == unseenFailure)

        keyPaneIDs = [pane.id]
        state.paneAttentionDidChange(paneID: pane.id)
        #expect(pane.attention == MactermProtocol.Attention())
    }

    /// The flags of a run end in the focused pane of a key quick terminal
    /// clear, and its `.done` state with them. A split pane that is not
    /// focused keeps its state and flags.
    @Test
    func a_run_end_in_a_key_quick_terminal_marks_only_its_focused_pane_seen() throws {
        let quick = QuickTerminalSplitState()
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")),
            projectFiles: makeProjectFileStore(),
            quickTerminal: quick
        )
        state.paneIsInKeyWindow = { _ in true }
        let focused = try #require(quick.focusedPaneID.flatMap { quick.splitRoot.findPane(id: $0) })
        quick.split(paneID: focused.id, direction: .horizontal, position: .second)
        quick.focusPane(focused.id)
        let other = try #require(quick.splitRoot.allPanes().first { $0.id != focused.id })

        for pane in [focused, other] {
            pane.receiveAttention(unseenFailure)
            state.paneAttentionDidChange(paneID: pane.id)
        }

        #expect(focused.executionState == .idle)
        #expect(focused.attention == MactermProtocol.Attention())
        #expect(other.executionState == .done)
        #expect(other.attention == unseenFailure)
    }

    /// The session keeps the flags across a quit: the saved file has none.
    @Test
    func saved_workspaces_hold_no_attention() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(fileURL: tmp)
        let state = makeAppState(store: store)
        state.isAppActive = { false }
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        pane.receiveAttention(unseenFailure)
        #expect(pane.executionState == .done)
        state.saveWorkspaces()

        let restored = WorkspaceSerializer.restore(from: store.load().workspaces, validIDs: [project.id])
        #expect(restored.first?.tabs.first?.executionState == .idle)
        #expect(restored.first?.tabs.first?.splitRoot.allPanes().first?.executionState == .idle)
    }

    // MARK: - Rename state

    @Test
    func renamingTabID_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renamingTabID_can_be_set_and_cleared() {
        let state = makeAppState()
        let id = UUID()
        state.renamingTabID = id
        #expect(state.renamingTabID == id)
        state.renamingTabID = nil
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renameTabContaining_targets_the_panes_tab() async throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)
        state.sidebarVisible = false

        state.renameTab(containing: paneID, projectID: p.id)

        #expect(state.sidebarVisible)
        // The rename target lands a runloop tick later (the sidebar row's
        // TextField must exist before it's asked to edit) — poll with sleeps.
        for _ in 0 ..< 100 where state.renamingTabID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(state.renamingTabID == tab.id)
    }

    @Test
    func renameTabContaining_unknown_pane_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        // Sidebar visibility is per window (#345); the app-wide property is a
        // mirror of the key window's, so there has to be one to hold it.
        let window = WindowState(activeProjectID: p.id)
        state.registerWindow(window)
        state.noteKeyWindow(window)
        state.sidebarVisible = false
        state.renameTab(containing: UUID(), projectID: p.id)
        #expect(!state.sidebarVisible)
    }

    @Test
    func setTabTitleContaining_sets_and_clears_customTitle() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        state.setTabTitle(containing: paneID, projectID: p.id, title: "deploy")
        #expect(tab.customTitle == "deploy")

        // Empty/nil restores the automatic title, same contract as the
        // ghostty keybind.
        state.setTabTitle(containing: paneID, projectID: p.id, title: nil)
        #expect(tab.customTitle == nil)
    }

    @Test
    func renamingProjectID_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.renamingProjectID == nil)
    }

    @Test
    func renamingProjectID_can_be_set_and_cleared() {
        let state = makeAppState()
        let id = UUID()
        state.renamingProjectID = id
        #expect(state.renamingProjectID == id)
        state.renamingProjectID = nil
        #expect(state.renamingProjectID == nil)
    }

    @Test
    func postPaletteAction_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.postPaletteAction == nil)
    }

    @Test
    func postPaletteAction_is_invoked_and_consumed() {
        let state = makeAppState()
        var invoked = false
        state.postPaletteAction = { invoked = true }
        #expect(state.postPaletteAction != nil)
        state.postPaletteAction?()
        state.postPaletteAction = nil
        #expect(invoked)
        #expect(state.postPaletteAction == nil)
    }

    // MARK: - requestClosePane / pendingClosePane

    @Test
    func requestClosePane_without_running_process_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let target = try #require(tab.focusedPaneID)
        // No GhosttyTerminalNSView is ever created in tests, so needsConfirmQuit is false.
        state.requestClosePane(target, projectID: p.id)
        #expect(state.pendingDialog == nil)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - A plain shell's host decides the close (0494)

    /// A tab with two panes whose surfaces read busy, as libghostty reads a
    /// plain ssh shell with no OSC 133 marks. The host answers `answer` for
    /// the pane that runs the plain shell.
    private func plainShellTab(answer: Bool?) throws -> (state: AppState, project: Project, tab: TerminalTab, target: UUID) {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let target = try #require(tab.focusedPaneID)
        state.paneNeedsConfirmClose = { _ in true }
        state.paneRunsPlainShell = { $0.id == target }
        state.askPlainShellNeedsConfirmClose = { pane, _ in pane.id == target ? answer : nil }
        return (state, p, tab, target)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func a_plain_shell_that_its_host_calls_idle_closes_with_no_warning() async throws {
        let fx = try plainShellTab(answer: false)
        fx.state.requestClosePane(fx.target, projectID: fx.project.id)
        await waitUntil { fx.tab.splitRoot.allPanes().count == 1 }
        #expect(fx.tab.splitRoot.allPanes().count == 1)
        #expect(fx.state.pendingDialog == nil)
    }

    @Test
    func a_plain_shell_that_its_host_calls_busy_warns() async throws {
        let fx = try plainShellTab(answer: true)
        fx.state.requestClosePane(fx.target, projectID: fx.project.id)
        await waitUntil { fx.state.pendingDialog != nil }
        #expect(fx.state.pendingDialog?.kind == .closePane(paneID: fx.target, projectID: fx.project.id))
        #expect(fx.tab.splitRoot.allPanes().count == 2)
    }

    @Test
    func a_plain_shell_whose_host_does_not_answer_warns() async throws {
        let fx = try plainShellTab(answer: nil)
        fx.state.requestClosePane(fx.target, projectID: fx.project.id)
        await waitUntil { fx.state.pendingDialog != nil }
        #expect(fx.state.pendingDialog?.kind == .closePane(paneID: fx.target, projectID: fx.project.id))
    }

    @Test
    func a_tab_with_an_idle_plain_shell_still_warns_for_its_other_busy_pane() async throws {
        let fx = try plainShellTab(answer: false)
        fx.state.requestCloseTab(fx.tab.id, projectID: fx.project.id)
        await waitUntil { fx.state.pendingDialog != nil }
        #expect(fx.state.pendingDialog?.kind == .closeTab(tabID: fx.tab.id, projectID: fx.project.id))
    }

    @Test
    func a_host_that_does_not_answer_in_time_gets_a_warning() async throws {
        let fx = try plainShellTab(answer: false)
        fx.state.plainShellAnswerTimeout = .milliseconds(50)
        fx.state.askPlainShellNeedsConfirmClose = { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return false
        }
        fx.state.requestClosePane(fx.target, projectID: fx.project.id)
        await waitUntil { fx.state.pendingDialog != nil }
        #expect(fx.state.pendingDialog?.kind == .closePane(paneID: fx.target, projectID: fx.project.id))
    }

    @Test
    func a_pane_that_closed_during_the_wait_gets_no_warning() async throws {
        let fx = try plainShellTab(answer: true)
        var asked = false
        fx.state.askPlainShellNeedsConfirmClose = { _, _ in
            asked = true
            try? await Task.sleep(for: .milliseconds(100))
            return true
        }
        fx.state.requestClosePane(fx.target, projectID: fx.project.id)
        // A second request for the same pane while the host is asked does nothing.
        fx.state.requestClosePane(fx.target, projectID: fx.project.id)
        await waitUntil { asked }
        fx.state.closePane(fx.target, projectID: fx.project.id)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fx.state.pendingDialog == nil)
        #expect(fx.tab.splitRoot.allPanes().count == 1)
    }

    @Test
    func the_hosts_answer_replaces_only_its_own_panes_reading() throws {
        let fx = try plainShellTab(answer: false)
        let panes = fx.tab.splitRoot.allPanes()
        let plain = try #require(panes.first { $0.id == fx.target })
        #expect(!fx.state.closeNeedsConfirmation([plain], plainAnswers: [plain.id: false]))
        #expect(fx.state.closeNeedsConfirmation([plain]))
        #expect(fx.state.closeNeedsConfirmation(panes, plainAnswers: [plain.id: false]))
    }

    @Test
    func the_async_verdict_uses_the_hosts_answer() async throws {
        let idle = try plainShellTab(answer: false)
        let idlePane = try #require(idle.tab.splitRoot.findPane(id: idle.target))
        #expect(await !idle.state.judgeClose([idlePane]))
        let busy = try plainShellTab(answer: true)
        let busyPane = try #require(busy.tab.splitRoot.findPane(id: busy.target))
        #expect(await busy.state.judgeClose([busyPane]))
    }

    @Test
    func the_quit_rows_leave_out_a_plain_shell_that_its_host_calls_idle() async throws {
        let fx = try plainShellTab(answer: false)
        let panes = fx.tab.splitRoot.allPanes()
        let rows = await fx.state.panesThatNeedConfirmClose(panes)
        #expect(rows.map(\.id) == panes.map(\.id).filter { $0 != fx.target })
    }

    @Test
    func the_quit_rows_wait_for_every_host() async throws {
        let fx = try plainShellTab(answer: true)
        let panes = fx.tab.splitRoot.allPanes()
        let slow = try #require(panes.first { $0.id != fx.target })
        // Both panes run a plain shell. The first answer is busy, and the
        // second host answers idle later: a stop at the first busy answer
        // would give the slow pane the surface's busy reading.
        fx.state.paneRunsPlainShell = { _ in true }
        fx.state.askPlainShellNeedsConfirmClose = { pane, _ in
            if pane.id == fx.target { return true }
            try? await Task.sleep(for: .milliseconds(50))
            return false
        }
        let rows = await fx.state.panesThatNeedConfirmClose(panes)
        #expect(rows.map(\.id) == [fx.target])
        #expect(!rows.contains { $0.id == slow.id })
    }

    // MARK: - applyLayout

    /// Create a temp project directory and seed a workspace rooted there.
    private func seedProjectWithDir(_ state: AppState) -> (project: Project, root: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Project(name: "proj", path: dir.path, sortOrder: 0)
        state.selectProject(p)
        return (p, dir.path)
    }

    /// Write a raw central project file into `store`'s directory.
    private func writeProjectFile(_ yaml: String, in store: ProjectFileStore, filename: String = "test.yaml") {
        try? FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try? yaml.write(to: store.directoryURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    @Test
    func selecting_project_with_matching_project_file_does_not_apply_it() throws {
        // A declared layout only ever lands through an explicit Apply Layout.
        // Selecting the project builds the default single-pane workspace and
        // leaves the file alone — no apply, no prompt, no error.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-noautoapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A central file declaring this path exists *before* the project opens.
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let project = Project(name: "declared", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == nil)
        #expect(ws.tabs[0].splitRoot.allPanes().count == 1)
        #expect(state.pendingDialog == nil)
        // The file is still there for Apply Layout to pick up.
        #expect(files.applyState(forProjectPath: dir.path) == .applicable)
    }

    @Test
    func first_open_without_a_project_file_uses_the_default_workspace() throws {
        // No central file declares this path, so first open is a plain
        // single-pane workspace.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-nofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "No File", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        #expect(state.pendingDialog == nil)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
        // Nothing is written on open — files appear only on explicit Save Layout.
        #expect(files.find(forProjectPath: dir.path) == nil)
    }

    @Test
    func selecting_project_with_invalid_project_file_raises_no_error() throws {
        // Selection never reads the file, so a broken one can't fail a plain
        // open; the parse error surfaces when Apply Layout is invoked.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Header identifies the file; tabs fail the full decode.
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - split: { direction: horizontal, first: {} }
        """, in: files)

        let project = Project(name: "broken", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        #expect(state.pendingDialog == nil)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingDialog?.kind == .layoutError(verb: .apply))
    }

    @Test
    func apply_layout_without_a_project_file_surfaces_an_error() throws {
        // An already-open project with no central declaration: Apply Layout has
        // nothing to read and says so, rather than silently doing nothing.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-applynofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "Existing", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingDialog?.kind == .layoutError(verb: .apply))
        #expect(files.find(forProjectPath: dir.path) == nil)
        // The live workspace is untouched by a failed apply.
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    // MARK: - Action toasts

    @Test
    func save_layout_toasts_with_the_full_path_it_wrote() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, _) = seedProjectWithDir(state) // name "proj" → proj.yaml

        state.saveLayoutPresentingError(project)

        #expect(state.pendingDialog == nil)
        #expect(state.activeToast?.title == "Layout saved")
        // The full path, not just the filename: the projects directory isn't
        // somewhere the user necessarily has in mind, so the subtitle has to
        // say where to go look — while still naming *which* file a save with
        // several same-path candidates landed in.
        let subtitle = try #require(state.activeToast?.subtitle)
        #expect(subtitle.hasSuffix("proj.yaml"))
        #expect(subtitle.contains("/"))
        #expect(subtitle == ProjectPath.homeContracted(files.directoryURL.appendingPathComponent("proj.yaml").path))
    }

    @Test
    func save_layout_toast_contracts_the_home_prefix() {
        // A path under home renders as `~/…` — readable, and it keeps the
        // username out of screenshots. `homeContracted` is the same helper the
        // written file's own `path:` uses, so the two can't drift.
        let home = ProjectPath.currentHome
        #expect(ProjectPath.homeContracted("\(home)/.config/macterm/projects/a.yaml")
            == "~/.config/macterm/projects/a.yaml")
        // Outside home, it passes through rather than mangling the path.
        #expect(ProjectPath.homeContracted("/etc/macterm/a.yaml") == "/etc/macterm/a.yaml")
    }

    @Test
    func save_layout_conflict_raises_a_dialog_instead_of_a_toast() {
        // A stray file declaring the same path makes the save a *notice*, not a
        // clean success. Toasting "Layout saved" alongside would undercut the
        // dialog that explains what's wrong.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // Bare `path:` with no `name:` — files no project's slug owns, which is
        // what makes them strays rather than a sibling's legitimate file. Two,
        // mirroring `save_layout_lists_ignored_duplicates_when_the_save_wins`:
        // the save claims one and reports the rest.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "zzz.yaml")

        state.saveLayoutPresentingError(project)

        #expect(state.pendingDialog?.kind == .layoutError(verb: .save))
        #expect(state.activeToast == nil)
    }

    @Test
    func apply_layout_toasts_on_a_clean_apply() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-toastapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeProjectFile("path: \(dir.path)\ntabs:\n  - name: \"Dev\"\n", in: files)
        let project = Project(name: "toast", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // Selecting applies nothing, so there is nothing to toast yet.
        #expect(state.activeToast == nil)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingDialog == nil)
        #expect(state.activeToast?.title == "Layout applied")
    }

    /// Both scenes in `MactermApp` bind alerts to this one pending value, so a
    /// staged dialog has to say which window asked for it — an ungated binding
    /// opens the settings window purely to stack a duplicate dialog on the one
    /// the user is answering. The default must stay the main window: everything
    /// but the settings pane (palette, menu, sidebar, CLI) relies on it.
    @Test
    func staged_destructive_apply_records_the_window_that_asked_for_it() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-applyhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeProjectFile("path: \(dir.path)\ntabs:\n  - name: \"Dev\"\n", in: files)
        let project = Project(name: "applyhost", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        // A second live tab the one-tab declaration doesn't mention: applying
        // would close it, which is what stages the confirmation.
        state.createTab(projectID: project.id, projectPath: dir.path)

        state.applyLayoutPresentingError(project)
        #expect(state.pendingDialog?.kind == .applyLayout(projectID: project.id))
        #expect(state.pendingDialog?.host == .mainWindow)

        state.dismissPendingDialog()

        state.applyLayoutPresentingError(project, host: .settings)
        #expect(state.pendingDialog?.kind == .applyLayout(projectID: project.id))
        #expect(state.pendingDialog?.host == .settings)
    }

    /// Same gate for the notice alerts: a Settings-invoked failure must not
    /// surface behind the main window (or in both).
    @Test
    func layout_error_records_the_window_that_asked_for_it() {
        let state = makeAppState(projectFiles: makeProjectFileStore())
        let (project, _) = seedProjectWithDir(state)

        state.applyLayoutPresentingError(project)
        #expect(state.pendingDialog?.kind == .layoutError(verb: .apply))
        #expect(state.pendingDialog?.host == .mainWindow)

        state.dismissPendingDialog()

        state.applyLayoutPresentingError(project, host: .settings)
        #expect(state.pendingDialog?.host == .settings)
    }

    @Test
    func apply_layout_failure_raises_a_dialog_instead_of_a_toast() {
        // No file declares this project's path — the command surfaces the
        // error, and a success toast would flatly contradict it.
        let state = makeAppState(projectFiles: makeProjectFileStore())
        let (project, _) = seedProjectWithDir(state)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingDialog?.kind == .layoutError(verb: .apply))
        #expect(state.activeToast == nil)
    }

    @Test
    func dismissing_a_superseded_toast_leaves_the_newer_one_up() {
        // The auto-dismiss task is keyed by toast id. A stale one firing after
        // a second toast replaced the first must not cut the new one short.
        let state = makeAppState()
        state.presentToast("First")
        let first = try? #require(state.activeToast?.id)
        state.presentToast("Second")

        if let first { state.dismissToast(first) }

        #expect(state.activeToast?.title == "Second")
    }

    @Test
    func dismissing_the_current_toast_clears_it() {
        let state = makeAppState()
        state.presentToast("Only")
        let id = state.activeToast?.id

        if let id { state.dismissToast(id) }

        #expect(state.activeToast == nil)
    }

    @Test
    func a_longer_toast_stays_up_longer() {
        // More text needs more reading time. The subtitle counts too.
        let short = Toast(title: "Layout saved", subtitle: "~/a.yaml")
        let long = Toast(title: "Layout saved", subtitle: "~/.config/macterm/projects/website.yaml")
        #expect(short.duration < long.duration)
    }

    @Test
    func toast_duration_is_clamped() {
        #expect(Toast(title: "Done").duration == Toast.minimumDuration)
        #expect(Toast(title: "Failed", subtitle: String(repeating: "x", count: 500)).duration == Toast.maximumDuration)
    }

    // MARK: - saveLayout duplicate conflicts

    @Test
    func save_layout_does_not_flag_a_sibling_projects_file() {
        // A distinct-name sibling on the same directory owns its own file.
        // Saving this project must neither report that file as a stray nor
        // realign-delete it.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state) // name "proj" → proj.yaml
        let sibling = Project(name: "other", path: root, sortOrder: 1)
        writeProjectFile("name: other\npath: \(root)", in: files, filename: "other.yaml")

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        #expect(state.pendingDialog == nil)
        #expect(files.find(forProjectPath: root, preferredSlug: "other")?.url.lastPathComponent == "other.yaml")
        #expect(files.find(forProjectPath: root, preferredSlug: "proj")?.url.lastPathComponent == "proj.yaml")
    }

    @Test
    func save_layout_lists_ignored_duplicates_when_the_save_wins() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // "proj.yaml" (the save target) sorts before the surviving duplicate.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "zzz.yaml")

        state.saveLayoutPresentingError(project)

        let notice = try #require(state.pendingDialog)
        #expect(notice.title == "Layout saved with a conflict")
        #expect(notice.message.contains("zzz.yaml"))
        #expect(notice.message.contains("ignores"))
    }

    @Test
    func save_layout_stays_silent_without_duplicates() {
        let state = makeAppState()
        let (project, _) = seedProjectWithDir(state)
        state.saveLayoutPresentingError(project)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func save_layout_warns_when_a_same_named_project_shares_the_directory() throws {
        // Two projects for one directory with the same name → same filename
        // slug → the same layout file. The save silently overwrote the other's
        // layout, so it must warn.
        let state = makeAppState()
        let (project, root) = seedProjectWithDir(state) // name "proj"
        let sibling = Project(name: "proj", path: root, sortOrder: 1)

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        let notice = try #require(state.pendingDialog)
        #expect(notice.title == "Layout file shared with another project")
        #expect(notice.message.contains("proj"))
    }

    @Test
    func save_layout_stays_silent_when_same_dir_projects_have_distinct_names() {
        // Same directory but different names → distinct slug files
        // (`proj.yaml` / `other.yaml`), so there's no shared-file overwrite.
        let state = makeAppState()
        let (project, root) = seedProjectWithDir(state) // name "proj"
        let sibling = Project(name: "other", path: root, sortOrder: 1)

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        #expect(state.pendingDialog == nil)
    }

    @Test
    func each_same_directory_project_saves_and_loads_its_own_layout() throws {
        // The core guarantee of per-project layout identity: two distinct-name
        // projects on one directory each save to and load from their own file —
        // saving one never clobbers the other's, and neither resolves the
        // other's on load (path alone can't tell them apart; the slug does).
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let alpha = Project(name: "alpha", path: dir.path, sortOrder: 0)
        let bravo = Project(name: "bravo", path: dir.path, sortOrder: 1)
        state.selectProject(alpha)
        state.selectProject(bravo)
        let siblings = [alpha, bravo]

        state.saveLayoutPresentingError(alpha, siblingProjects: siblings)
        state.saveLayoutPresentingError(bravo, siblingProjects: siblings)

        #expect(state.pendingDialog == nil)
        // Both files coexist — saving bravo didn't realign-delete alpha's.
        #expect(files.find(forProjectPath: dir.path, preferredSlug: "alpha")?.url.lastPathComponent == "alpha.yaml")
        #expect(files.find(forProjectPath: dir.path, preferredSlug: "bravo")?.url.lastPathComponent == "bravo.yaml")
        // Each resolves the file it wrote, identified by the stored name.
        #expect(try files.loadFull(forProjectPath: dir.path, preferredSlug: "alpha")?.name == "alpha")
        #expect(try files.loadFull(forProjectPath: dir.path, preferredSlug: "bravo")?.name == "bravo")
    }

    @Test
    func selecting_project_without_layout_file_uses_default_workspace() {
        let state = makeAppState()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-nolayout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "plain", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // No layout file → default single-pane workspace.
        #expect(state.workspaces[project.id]?.tabs.count == 1)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    @Test
    func reopen_restores_snapshot_silently_and_ignores_project_file() throws {
        // Reopen is always silent: a restored session snapshot wins (a
        // project's panes must reattach their live zmx sessions, and its live
        // layout is remembered), and the declared file is NOT applied and NOT
        // prompted for — even when it differs.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "winner", path: dir.path, sortOrder: 0)

        // Pre-seed a saved snapshot for the project: a single-pane workspace.
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(fileURL: storeURL)
        let snapshotWS = Workspace(id: project.id, projectPath: dir.path)
        store.save(WorkspaceSerializer.snapshot([project.id: snapshotWS]))

        // And a central file declaring a different (two-pane) split.
        let files = makeProjectFileStore()
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store, projectFiles: files)
        state.restoreSelection(projects: [project])

        // Restored snapshot wins: one pane, file NOT applied, NO prompt.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs[0].splitRoot.allPanes().count == 1)
        #expect(ws.tabs[0].customTitle != "Dev")
        #expect(state.pendingDialog == nil)
    }

    @Test
    func restore_without_snapshot_ignores_project_file_and_uses_default_workspace() throws {
        // No snapshot at all → the default single-pane workspace, not the
        // declared file. A layout lands only through an explicit Apply Layout.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-firstopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "fresh", path: dir.path, sortOrder: 0)
        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        let files = makeProjectFileStore()
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store, projectFiles: files)
        state.restoreSelection(projects: [project])

        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == nil)
        #expect(ws.tabs[0].splitRoot.allPanes().count == 1)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func restore_gives_a_never_opened_project_its_first_tab_and_a_group_none() throws {
        // A project holds its tabs from the start (design 010 section 11): a
        // project with no snapshot that no window selects still gets its
        // first tab at the restore. A group (no folder) holds no tabs.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-neveropened-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "never", path: dir.path, sortOrder: 0)
        let group = Project(name: "Work", path: "", sortOrder: 1)
        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = nil
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store)
        state.restoreSelection(projects: [project, group])

        #expect(state.activeProjectID == nil)
        #expect(state.workspaces[project.id]?.tabs.count == 1)
        #expect(state.workspaces[group.id] == nil)
    }

    @Test
    func an_added_project_gets_its_first_tab_at_once() {
        let state = makeAppState()
        let projects = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-added-\(UUID().uuidString).json"))
        projects.onAdd = { [weak state] in state?.projectAdded($0) }
        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = nil
        defer { Preferences.shared.activeProjectID = priorActive }
        state.restoreSelection(projects: projects.projects)

        let project = projects.create(name: "fresh", path: "/tmp")
        let group = projects.add(Project(name: "Work", path: ""))

        #expect(state.workspaces[project.id]?.tabs.count == 1)
        #expect(state.workspaces[group.id] == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test
    func a_project_with_every_tab_closed_stays_empty_after_a_relaunch() throws {
        // Closing the last tab leaves the project empty. A relaunch must keep
        // it empty: selecting it does not create a default tab.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-emptyproject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "empty", path: dir.path, sortOrder: 0)
        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        let first = makeAppState(store: store)
        first.selectProject(project)
        let tabID = try #require(first.workspaces[project.id]?.tabs.first?.id)
        first.closeTab(tabID, projectID: project.id)
        #expect(first.workspaces[project.id]?.tabs.isEmpty == true)

        let relaunched = makeAppState(store: store)
        relaunched.restoreSelection(projects: [project])
        relaunched.selectProject(project)

        let ws = try #require(relaunched.workspaces[project.id])
        #expect(ws.tabs.isEmpty)
        #expect(ws.activeTabID == nil)
    }

    @Test
    func applyLayout_malformed_file_returns_error_and_does_not_apply() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        // Invalid: a `split` mapping missing its `second` child.
        writeProjectFile("path: \(root)\ntabs:\n  - split: { direction: horizontal, first: {} }\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error != nil)
        // Workspace is untouched — same tabs, nothing spawned or closed.
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func applyLayout_missing_file_returns_error_and_does_not_apply() throws {
        let state = makeAppState()
        let (p, _) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        let error = state.applyLayout(project: p)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func applyLayout_empty_tabs_returns_error_and_never_plans_destruction() throws {
        // A bare declaration (no tabs:) must read as "nothing to apply" —
        // planning against an empty tab list would close every live tab.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        writeProjectFile("name: bare\npath: \(root)\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func applyLayout_name_mismatch_applies_without_prompt() {
        // Files are matched by path; a differing `name:` is expected drift
        // (project renamed since last save), never a confirmation.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state) // project name "proj"

        writeProjectFile("name: OtherApp\npath: \(root)\ntabs:\n  - {}\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error == nil)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func saveLayout_creates_central_file_declaring_the_project_path() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)

        let error = state.saveLayout(project: p)

        #expect(error == nil)
        let saved = try #require(try files.loadFull(forProjectPath: root))
        #expect(saved.name == "proj")
        #expect(saved.path == root)
        #expect(saved.tabs?.count == 1)
        #expect(files.find(forProjectPath: root)?.url.lastPathComponent == "proj.yaml")
    }

    // MARK: - A project with no folder

    @Test
    func a_project_with_no_folder_starts_its_shells_in_the_scratch_folder() throws {
        let state = makeAppState()
        let p = Project(name: "parent", path: "", sortOrder: 0)
        state.selectProject(p)
        let pane = try #require(state.workspaces[p.id]?.activeTab?.focusedPane)
        #expect(pane.projectPath == ScratchTabs.fallbackRoot)
    }

    @Test
    func next_project_skips_a_project_with_no_folder() {
        let state = makeAppState()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let group = Project(name: "g", path: "", sortOrder: 1)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 2)
        state.selectProject(a)
        state.selectNextProject(projects: [a, group, b])
        #expect(state.activeProjectID == b.id)
        state.selectPreviousProject(projects: [a, group, b])
        #expect(state.activeProjectID == a.id)
    }

    @Test
    func a_project_with_no_folder_has_no_layout_file() {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let store = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-no-folder-\(UUID().uuidString).json"))
        let p = store.add(Project(name: "parent", path: ""))
        state.selectProject(p)

        func isNoFolder(_ error: Error?) -> Bool {
            if case .noFolder? = error as? LayoutFileError { true } else { false }
        }
        #expect(isNoFolder(state.saveLayout(project: p)))
        #expect(isNoFolder(state.applyLayout(project: p)))
        #expect(files.scan().isEmpty)
        let ctx = AppCommandContext(appState: state, projectStore: store)
        #expect(AppCommand.saveLayout.action(in: ctx) == nil)
        #expect(AppCommand.applyLayout.action(in: ctx) == nil)
    }

    // MARK: - panesToWarm (eager process start for focused project)

    @Test
    func panesToWarm_excludes_active_tab_includes_the_rest() {
        let pid = UUID()
        // Tab A (active): 1 pane. Tab B: 2-pane split. Tab C: 1 pane.
        let a = Pane(projectPath: "/p", projectID: pid)
        let (bTree, bIDs) = build(H(pane("b1"), pane("b2")))
        let c = Pane(projectPath: "/p", projectID: pid)
        let tabA = TerminalTab(id: UUID(), splitRoot: .pane(a), focusedPaneID: a.id)
        let tabB = TerminalTab(id: UUID(), splitRoot: bTree, focusedPaneID: nil)
        let tabC = TerminalTab(id: UUID(), splitRoot: .pane(c), focusedPaneID: c.id)
        let ws = Workspace(id: pid, tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        let warm = Set(AppState.panesToWarm(in: ws).map(\.id))
        // Active tab A's pane is NOT warmed (SwiftUI starts it); B's two + C are.
        #expect(!warm.contains(a.id))
        #expect(warm == Set([bIDs["b1"], bIDs["b2"], c.id].compactMap(\.self)))
        #expect(warm.count == 3)
    }

    @Test
    func panesToWarm_single_tab_workspace_warms_nothing() {
        let pid = UUID()
        let only = Pane(projectPath: "/p", projectID: pid)
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(only), focusedPaneID: only.id)
        let ws = Workspace(id: pid, tabs: [tab], activeTabID: tab.id)
        #expect(AppState.panesToWarm(in: ws).isEmpty)
    }

    // MARK: - Run state

    /// The run state comes from the session whatever the status indicator
    /// setting is: `pane list` reports it, and the setting only chooses what
    /// the tab row draws (#705).
    @Test
    func the_run_state_follows_the_session_with_the_status_indicator_off() throws {
        let priorIndicator = Preferences.shared.showTabStatusIndicator
        defer { Preferences.shared.showTabStatusIndicator = priorIndicator }
        Preferences.shared.showTabStatusIndicator = false
        let state = makeAppState()
        state.isAppActive = { false }
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        pane.receiveSessionStatus(MactermProtocol.Status(state: .running))
        state.settleAllPanes()
        #expect(pane.executionState == .running)
        pane.receiveSessionStatus(MactermProtocol.Status(state: .done))
        pane.receiveAttention(MactermProtocol.Attention(unseen: true))
        state.settleAllPanes()
        #expect(pane.executionState == .done)
    }

    // MARK: - zmx session lifecycle on close paths

    /// A SessionClient that records every killed session name. Remote kills are
    /// recorded into `remoteKilled` (when given) so a test can assert routing.
    private func recordingClient(
        into killed: KilledSessions,
        remoteInto remoteKilled: KilledSessions? = nil
    ) -> SessionClient {
        SessionClient(
            runsSessions: { false },
            isBundled: { true },
            killSession: { name in await killed.append(name) },
            killRemoteSession: { _, name in await (remoteKilled ?? killed).append(name) },
            listSessions: { [] },
            endV1Sessions: { _ in true }
        )
    }

    @Test
    func closeTab_kills_every_panes_session() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.sessionClient = recordingClient(into: killed)
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let names = Set(tab.splitRoot.allPanes().map(\.sessionName))
        #expect(names.count == 2)

        // Second tab so the close leaves a valid workspace.
        _ = state.workspaces[p.id].map { ModelWriter.tabCreate(in: $0, projectPath: "/tmp") }
        state.closeTab(tab.id, projectID: p.id)

        await killed.settle(expecting: names.count)
        #expect(await killed.names == names)
    }

    @Test
    func a_session_that_a_pending_pinned_record_names_is_not_killed_and_needs_no_confirmation() async throws {
        // A pinned record that waits to load reattaches its session later:
        // a close that releases a pane on that session must leave it.
        let killed = KilledSessions()
        let state = makeAppState()
        state.sessionClient = recordingClient(into: killed)
        state.paneNeedsConfirmClose = { _ in true }
        let p = seedProject(state)
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        #expect(state.closeNeedsConfirmation([pane]))

        state.pendingPinnedLiveRestores[UUID()] = TabSnapshot(
            id: UUID(),
            customTitle: nil,
            focusedPaneID: nil,
            splitRoot: .pane(PaneSnapshot(id: UUID(), projectPath: "/tmp", sessionName: pane.sessionName))
        )

        #expect(!state.closeNeedsConfirmation([pane]))
        state.releaseSessions([pane])
        await killed.settleExpectingNone()
        #expect(await killed.names.isEmpty)
    }

    @Test
    func closing_remote_pane_routes_kill_over_ssh() async throws {
        // A remote pane's session lives on the remote daemon — a local kill
        // of its name would silently no-op and strand the session (#104).
        let killed = KilledSessions()
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        state.sessionClient = recordingClient(into: killed, remoteInto: remoteKilled)
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let target = try #require(tab.focusedPaneID)
        let targetName = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.closePane(target, projectID: p.id)

        await remoteKilled.settle(expecting: 1)
        #expect(await remoteKilled.names == [targetName])
        #expect(await killed.names.isEmpty)
    }

    // MARK: - Process-exit routing (#281)

    /// A SessionClient that records remote kills.
    private func remoteKillRecordingClient(_ remoteKilled: KilledSessions) -> SessionClient {
        SessionClient(
            runsSessions: { false },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, name in await remoteKilled.append(name) },
            listSessions: { [] },
            endV1Sessions: { _ in true }
        )
    }

    @Test
    func process_exit_closes_a_local_pane() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.sessionClient = recordingClient(into: killed)
        let p = seedProject(state)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let target = try #require(tab.focusedPaneID)
        let name = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.handleProcessExit(target, projectID: p.id)

        #expect(tab.splitRoot.findPane(id: target) == nil)
        await killed.settle(expecting: 1)
        #expect(await killed.names.contains(name))
    }

    @Test
    func remote_process_exit_closes_the_pane_and_ends_its_session() async throws {
        // The client on a remote pane's tty (`macterm remote-pane`) waits
        // through a dropped connection, so it exits only when the session's
        // shell ended (0057): the pane closes with no question, and the close
        // ends the exited session on the host.
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        // A second tab so the close leaves a valid workspace shape.
        _ = state.workspaces[p.id].map { ModelWriter.tabCreate(in: $0, projectPath: "devbox:~/dev/api") }
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.sessionClient = remoteKillRecordingClient(remoteKilled)

        state.handleProcessExit(pane.id, projectID: p.id)

        #expect(state.workspaces[p.id]?.tabs.allSatisfy { $0.splitRoot.findPane(id: pane.id) == nil } == true)
        await remoteKilled.settle(expecting: 1)
        #expect(await remoteKilled.names == [pane.sessionName])
    }

    @Test
    func closePane_kills_only_that_panes_session() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.sessionClient = recordingClient(into: killed)
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id, projects: [p])
        let target = try #require(tab.focusedPaneID)
        let targetName = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.closePane(target, projectID: p.id)

        await killed.settle(expecting: 1)
        #expect(await killed.names == [targetName])
    }

    @Test
    func moveTab_kills_nothing() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.sessionClient = recordingClient(into: killed)
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let moving = try #require(state.workspaces[p1.id]?.tabs.first?.id)

        state.moveTab(moving, from: p1.id, to: p2.id, destPath: p2.path)

        await killed.settleExpectingNone()
        #expect(await killed.names.isEmpty)
    }

    @Test
    func moveTab_restamps_pane_routing_identity_but_not_session() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let tab = try #require(state.workspaces[p1.id]?.activeTab)
        // Split so the moved tab carries more than one pane to restamp.
        state.splitPane(direction: .horizontal, projectID: p1.id, projects: [p1])
        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let originalSessionNames = Set(panes.map(\.sessionName))
        let originalPaths = Set(panes.map(\.projectPath))

        state.moveTab(tab.id, from: p1.id, to: p2.id, destPath: p2.path)

        // Routing identity (projectID) is restamped to the destination so a
        // notification click navigates to the right workspace.
        #expect(tab.splitRoot.allPanes().allSatisfy { $0.projectID == p2.id })
        // Session identity is untouched — the shells keep running under their
        // original names and paths (a remote pane would still kill over ssh).
        #expect(Set(tab.splitRoot.allPanes().map(\.sessionName)) == originalSessionNames)
        #expect(Set(tab.splitRoot.allPanes().map(\.projectPath)) == originalPaths)
    }

    @Test
    func moveTab_toIndex_inserts_at_slot_in_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // Give p2 two tabs so there's a middle slot to drop into.
        let dest = try #require(state.workspaces[p2.id])
        let d0 = dest.tabs[0].id
        let d1 = ModelWriter.tabCreate(in: dest, projectPath: p2.path).id
        let moving = try #require(state.workspaces[p1.id]?.activeTab)

        state.moveTab(moving.id, from: p1.id, to: p2.id, destPath: p2.path, toIndex: 1)

        #expect(dest.tabs.map(\.id) == [d0, moving.id, d1])
        #expect(dest.activeTabID == moving.id)
        #expect(state.workspaces[p1.id]?.tabs.contains { $0.id == moving.id } == false)
    }

    @Test
    func reorderTab_moves_within_project_and_persists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let state = makeAppState(store: WorkspaceStore(fileURL: storeURL))
        let p = seedProject(state, name: "p", path: "/tmp")
        let ws = try #require(state.workspaces[p.id])
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: p.path).id

        state.reorderTab(t1, inProject: p.id, toIndex: 2)
        #expect(ws.tabs.map(\.id) == [t2, t1])

        // The reorder persisted: a fresh store reading the same file sees it.
        let reloaded = WorkspaceStore(fileURL: storeURL).load()
        let saved = try #require(reloaded.workspaces.first { $0.projectID == p.id })
        #expect(saved.tabs.map(\.id) == [t2, t1])
    }

    @Test
    func moveActiveTab_steps_one_place_and_stops_at_the_ends() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: p.path).id
        let t3 = ModelWriter.tabCreate(in: ws, projectPath: p.path).id
        ModelWriter.tabPeek(t1, in: ws)
        let ctx = AppCommandContext(appState: state, projectStore: ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-tests-move-\(UUID().uuidString).json")
        ))

        #expect(AppCommand.moveTabUp.action(in: ctx) == nil)
        state.moveActiveTab(step: 1, projectID: p.id)
        #expect(ws.tabs.map(\.id) == [t2, t1, t3])
        let moveDown = try #require(AppCommand.moveTabDown.action(in: ctx))
        moveDown()
        #expect(ws.tabs.map(\.id) == [t2, t3, t1])
        #expect(AppCommand.moveTabDown.action(in: ctx) == nil)
        state.moveActiveTab(step: 1, projectID: p.id)
        #expect(ws.tabs.map(\.id) == [t2, t3, t1])
        state.moveActiveTab(step: -1, projectID: p.id)
        #expect(ws.tabs.map(\.id) == [t2, t1, t3])
        #expect(ws.activeTabID == t1)
    }

    @Test
    func movePane_commands_swap_the_focused_pane_and_hide_without_a_neighbor() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let ctx = AppCommandContext(appState: state, projectStore: ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-tests-move-\(UUID().uuidString).json")
        ))
        #expect(AppCommand.movePaneRight.action(in: ctx) == nil)

        let first = try #require(tab.focusedPaneID)
        let second = try #require(ModelWriter.paneSplit(tab, paneID: first, direction: .horizontal))
        ModelWriter.paneFocus(tab, paneID: first)
        #expect(AppCommand.movePaneLeft.action(in: ctx) == nil)
        #expect(AppCommand.movePaneUp.action(in: ctx) == nil)
        let moveRight = try #require(AppCommand.movePaneRight.action(in: ctx))
        moveRight()
        #expect(tab.splitRoot.allPanes().map(\.id) == [second, first])
        #expect(tab.focusedPaneID == first)
    }

    // MARK: - Busy-close confirmations

    @Test
    func requestCloseTab_with_idle_panes_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")

        // No live surfaces in a unit test → needsConfirmQuit is unreachable →
        // not busy → closes without staging.
        state.requestCloseTab(tab.id, projectID: p.id)
        #expect(state.pendingDialog == nil)
        #expect(ws.tabs.count == 1)
    }

    @Test
    func requestRemoveProject_idle_runs_removal_immediately() {
        let state = makeAppState()
        let p = seedProject(state)
        var removed = false
        state.requestRemoveProject(p.id) { removed = true }
        #expect(removed)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func pendingCloseTab_confirm_and_cancel() throws {
        let state = makeAppState()
        // Every pane reads busy, so the close stages instead of running.
        state.paneNeedsConfirmClose = { _ in true }
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")

        state.requestCloseTab(tab.id, projectID: p.id)
        #expect(state.pendingDialog?.kind == .closeTab(tabID: tab.id, projectID: p.id))
        #expect(state.pendingDialog?.confirmTitle == "Close")
        state.dismissPendingDialog()
        #expect(state.pendingDialog == nil)
        #expect(ws.tabs.count == 2)

        state.requestCloseTab(tab.id, projectID: p.id)
        state.confirmPendingDialog()
        #expect(state.pendingDialog == nil)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Tab switcher candidates and live previews

    /// The limit bounds the cycle the keyboard walks, and it does so whether
    /// or not the switcher is showing — a tab's reachability must not depend
    /// on a display preference.
    @Test
    func recent_tab_candidate_limit_bounds_the_cycle_regardless_of_overlay() throws {
        let priorOverlay = Preferences.shared.showTabSwitcherOverlay
        let priorCandidates = Preferences.shared.recentTabCandidates
        defer {
            Preferences.shared.showTabSwitcherOverlay = priorOverlay
            Preferences.shared.recentTabCandidates = priorCandidates
        }
        let cases = [
            (showsOverlay: true, limit: 3, expectedCount: 3),
            (showsOverlay: true, limit: Preferences.unlimitedRecentTabCandidates, expectedCount: 6),
            (showsOverlay: false, limit: 2, expectedCount: 2),
            (showsOverlay: false, limit: Preferences.unlimitedRecentTabCandidates, expectedCount: 6),
        ]

        for testCase in cases {
            Preferences.shared.showTabSwitcherOverlay = testCase.showsOverlay
            Preferences.shared.recentTabCandidates = testCase.limit

            let state = makeAppState()
            let project = seedProject(state)
            let workspace = try #require(state.workspaces[project.id])
            for _ in 0 ..< 5 {
                state.createTab(projectID: project.id, projects: [project])
            }
            let expectedOrder = Array(workspace.recencyOrder().prefix(testCase.expectedCount))

            state.cycleRecentTab(projectID: project.id)

            #expect(state.tabCycleTabIDs == expectedOrder)
            state.commitTabCycle(projectID: project.id)
        }
    }

    /// A cycle showing the switcher wakes the renderer of every pane it
    /// offers and samples them until the modifier is released — an off-screen
    /// renderer is parked and holds no frame, so without this the cards would
    /// freeze at whatever each tab looked like when it was last left.
    @Test
    func cycling_with_the_switcher_keeps_offered_panes_rendering_until_commit() throws {
        let prior = Preferences.shared.showTabSwitcherOverlay
        defer { Preferences.shared.showTabSwitcherOverlay = prior }
        Preferences.shared.showTabSwitcherOverlay = true

        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let first = try #require(ws.activeTab?.focusedPane)
        state.createTab(projectID: project.id, projects: [project])
        let second = try #require(ws.activeTab?.focusedPane)
        let firstView = SurfaceRegistry.shared.ensureView(of: first)
        let secondView = SurfaceRegistry.shared.ensureView(of: second)

        state.cycleRecentTab(projectID: project.id)

        #expect(state.isTabCycling)
        #expect(state.isLivePreviewing)
        #expect(firstView.rendersForPreview)
        #expect(secondView.rendersForPreview)

        state.commitTabCycle(projectID: project.id)

        #expect(!state.isTabCycling)
        #expect(!state.isLivePreviewing)
        #expect(!firstView.rendersForPreview)
        #expect(!secondView.rendersForPreview)
    }

    /// With the overlay off there are no cards to keep current, so the
    /// default cycling path must not wake a single off-screen renderer.
    @Test
    func cycling_without_the_switcher_wakes_no_renderer() throws {
        let prior = Preferences.shared.showTabSwitcherOverlay
        defer { Preferences.shared.showTabSwitcherOverlay = prior }
        Preferences.shared.showTabSwitcherOverlay = false

        let state = makeAppState()
        let project = seedProject(state)
        let ws = try #require(state.workspaces[project.id])
        let first = try #require(ws.activeTab?.focusedPane)
        state.createTab(projectID: project.id, projects: [project])
        let second = try #require(ws.activeTab?.focusedPane)
        let firstView = SurfaceRegistry.shared.ensureView(of: first)
        let secondView = SurfaceRegistry.shared.ensureView(of: second)

        state.cycleRecentTab(projectID: project.id)

        #expect(state.isTabCycling)
        #expect(!state.isLivePreviewing)
        #expect(!firstView.rendersForPreview)
        #expect(!secondView.rendersForPreview)

        state.commitTabCycle(projectID: project.id)
    }

    // MARK: - Quick terminal persistence

    /// A store on disk plus an AppState adopting its own quick terminal, so
    /// nothing here writes into the panel's shared split state.
    private func makeQuickTerminalFixture(
        quick: QuickTerminalSplitState = QuickTerminalSplitState()
    ) throws -> (state: AppState, quick: QuickTerminalSplitState, storeURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: quick
        )
        return (state, quick, storeURL, dir)
    }

    /// The quick terminal's own mutations persist the moment they happen — a
    /// split in the panel is as durable as a split in a workspace, not
    /// something that waits for quit (a crash would otherwise lose the tree
    /// and orphan the new pane's session).
    @Test
    func a_quick_terminal_split_persists_its_tab_with_session_names_verbatim() throws {
        let (state, quick, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])

        try quick.split(paneID: #require(quick.focusedPaneID), direction: .vertical)
        let names = Set(quick.tab.splitRoot.allPanes().map(\.sessionName))
        #expect(names.count == 2)

        let saved = try #require(WorkspaceStore(fileURL: storeURL).load().quickTerminal)
        #expect(saved.id == quick.tab.id)
        let restored = WorkspaceSerializer.restoreTab(saved, projectID: QuickTerminalService.projectID)
        #expect(Set(restored.splitRoot.allPanes().map(\.sessionName)) == names)
    }

    /// Launch hands the persisted tab back to the panel: same tab id, same
    /// session names (the reattach identity), each pane respawning in the cwd
    /// it was in rather than the home directory a fresh tab starts from.
    @Test
    func restoreSelection_hands_the_persisted_quick_terminal_back_to_the_panel() throws {
        let (writer, writerQuick, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writerQuick.split(paneID: #require(writerQuick.focusedPaneID), direction: .horizontal)
        let expectedNames = Set(writerQuick.tab.splitRoot.allPanes().map(\.sessionName))
        writer.saveWorkspaces()

        let fresh = QuickTerminalSplitState()
        let bornWith = fresh.tab.id
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: fresh
        )
        state.restoreSelection(projects: [])

        #expect(fresh.tab.id == writerQuick.tab.id)
        #expect(fresh.tab.id != bornWith)
        #expect(Set(fresh.tab.splitRoot.allPanes().map(\.sessionName)) == expectedNames)
        #expect(fresh.tab.splitRoot.allPanes().allSatisfy { $0.projectID == QuickTerminalService.projectID })
        #expect(fresh.tab.focusedPaneID != nil)
    }

    /// A restore that arrives after the panel has already been shown this run
    /// is refused: the live tab's sessions would be orphaned by the swap, and
    /// the fresh tab is the one now worth persisting.
    @Test
    func restoreSelection_keeps_a_quick_terminal_that_is_already_on_screen() throws {
        let (writer, writerQuick, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.saveWorkspaces()
        let persistedID = writerQuick.tab.id

        let shown = QuickTerminalSplitState()
        let livePane = try #require(shown.tab.focusedPane)
        _ = SurfaceRegistry.shared.ensureView(of: livePane)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: shown
        )
        state.restoreSelection(projects: [])

        #expect(shown.tab.id != persistedID)
        #expect(shown.tab.focusedPane === livePane)
    }

    /// Until the launch restore has run, `workspaces` is empty — a save then
    /// would write that emptiness over the file about to be restored. The
    /// panel's hotkey works from the first moment of launch, so a split made
    /// in that window must wait for the next save rather than cause one.
    @Test
    func a_quick_terminal_split_before_the_launch_restore_saves_nothing() throws {
        let (_, quick, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = """
        {"version": 6, "workspaces": [], "pinned": [], "windows": []}
        """
        try sentinel.write(to: storeURL, atomically: true, encoding: .utf8)

        try quick.split(paneID: #require(quick.focusedPaneID), direction: .vertical)

        #expect(try String(contentsOf: storeURL, encoding: .utf8) == sentinel)
    }

    /// A file from before the section existed leaves the fresh tab alone.
    @Test
    func restoreSelection_without_a_quick_terminal_section_leaves_the_fresh_tab() throws {
        let (_, quick, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {"version": 6, "workspaces": [], "pinned": [], "windows": []}
        """.write(to: storeURL, atomically: true, encoding: .utf8)
        let bornWith = quick.tab.id

        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: quick
        )
        state.restoreSelection(projects: [])
        #expect(quick.tab.id == bornWith)
    }

    /// The first v2 launch ends the v1 sessions that the restored panes
    /// name, the quick terminal's included, and only once.
    @Test
    func the_first_v2_launch_ends_the_v1_sessions_that_the_restored_panes_name() async throws {
        let (writer, writerQuick, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writerQuick.split(paneID: #require(writerQuick.focusedPaneID), direction: .horizontal)
        let quickNames = Set(writerQuick.tab.splitRoot.allPanes().map(\.sessionName))
        writer.saveWorkspaces()

        let ended = KilledSessions()
        var sessionClient = SessionClient.noop
        sessionClient.endV1Sessions = { names in
            for name in names {
                await ended.append(name)
            }
            return true
        }
        let endedFlag = LockedBox(false)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: QuickTerminalSplitState()
        )
        state.sessionClient = sessionClient
        state.v1SessionsEnded = .init(read: { endedFlag.value }, write: { endedFlag.mutate { $0 = true } })
        state.restoreSelection(projects: [])

        await ended.settle(expecting: quickNames.count)
        #expect(await Set(ended.names) == quickNames)
        let deadline = Date().addingTimeInterval(5)
        while !endedFlag.value, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(endedFlag.value)

        // Once: a second launch ends nothing.
        let again = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: QuickTerminalSplitState()
        )
        let calls = LockedBox(0)
        var counting = SessionClient.noop
        counting.endV1Sessions = { _ in
            calls.mutate { $0 += 1 }
            return true
        }
        again.sessionClient = counting
        again.v1SessionsEnded = state.v1SessionsEnded
        again.restoreSelection(projects: [])
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 0)
    }

    /// A v1 session that is still running after the try leaves the flag
    /// unset, so that the next launch tries again.
    @Test
    func a_v1_session_that_did_not_end_leaves_the_flag_unset() async throws {
        let (writer, _, storeURL, dir) = try makeQuickTerminalFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.saveWorkspaces()

        let calls = LockedBox(0)
        var sessionClient = SessionClient.noop
        sessionClient.endV1Sessions = { _ in
            calls.mutate { $0 += 1 }
            return false
        }
        let endedFlag = LockedBox(false)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: makeProjectFileStore(),
            quickTerminal: QuickTerminalSplitState()
        )
        state.sessionClient = sessionClient
        state.v1SessionsEnded = .init(read: { endedFlag.value }, write: { endedFlag.mutate { $0 = true } })
        state.restoreSelection(projects: [])

        let deadline = Date().addingTimeInterval(5)
        while calls.value == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 1)
        #expect(!endedFlag.value)
    }
}

/// Actor recording killed session names across the fire-and-forget kill tasks.
private actor KilledSessions {
    private(set) var names: Set<String> = []
    func append(_ name: String) {
        names.insert(name)
    }

    /// Wait until at least `count` distinct names have been recorded (or a
    /// generous timeout elapses). Waiting for the EXPECTED count — not merely
    /// "anything arrived" — means a slow second kill can't make a positive
    /// assertion pass before all kills have landed.
    func settle(expecting count: Int) async {
        for _ in 0 ..< 200 where names.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// For negative assertions ("nothing should have been killed"): wait a
    /// deterministic window so a late kill would have shown up, then the caller
    /// asserts emptiness. Named distinctly so its intent (and its inherent
    /// fixed-wait limitation) is explicit at the call site.
    func settleExpectingNone() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}
