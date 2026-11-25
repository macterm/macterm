import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateSessionRestartTests {
    private func makeState() -> AppState {
        TestModel.appState()
    }

    private func command(_ state: AppState) -> (@MainActor () -> Void)? {
        AppCommand.restartSession.action(in: AppCommandContext(appState: state, projectStore: TestModel.projectStore(state)))
    }

    @Test
    func the_badge_shows_only_for_a_tab_with_an_older_session() throws {
        let state = makeState()
        let project = TestModel.project(state, name: "p")
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        #expect(!state.tabRunsOlderSession(tab))
        state.outdatedSessions = ["another-session"]
        #expect(!state.tabRunsOlderSession(tab))
        state.outdatedSessions = try [#require(tab.splitRoot.allPanes().first).sessionName]
        #expect(state.tabRunsOlderSession(tab))
    }

    @Test
    func the_command_is_available_only_with_an_older_session_in_the_active_tab() throws {
        let state = makeState()
        let project = TestModel.project(state, name: "p")
        #expect(command(state) == nil)
        let pane = try #require(state.liveTabs[project.id]?.activeTab?.splitRoot.allPanes().first)
        state.outdatedSessions = [pane.sessionName]
        #expect(command(state) != nil)
    }

    @Test
    func a_restart_replaces_only_the_older_panes() throws {
        let state = makeState()
        state.paneNeedsConfirmClose = { _ in false }
        let project = TestModel.project(state, name: "p")
        state.splitPane(direction: .horizontal, projectID: project.id, projects: [project])
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let old = panes[0], kept = panes[1]
        state.writer.paneFocus(old.id)
        state.outdatedSessions = [old.sessionName]

        state.requestRestartSessions(tabID: tab.id, projectID: project.id)

        let after = tab.splitRoot.allPanes()
        #expect(after.count == 2)
        #expect(after.contains { $0.id == kept.id })
        #expect(!after.contains { $0.id == old.id })
        #expect(!after.contains { $0.sessionName == old.sessionName })
        #expect(tab.focusedPaneID != old.id)
        #expect(tab.focusedPaneID.map { id in after.contains { $0.id == id } } == true)
        #expect(state.outdatedSessions.isEmpty)
        // The old pane left the model: the server ends its session.
        #expect(state.model.pane(old.id) == nil)
        #expect(state.pendingDialog == nil)
    }

    @Test
    func a_busy_pane_asks_before_the_restart() throws {
        let state = makeState()
        state.paneNeedsConfirmClose = { _ in true }
        let project = TestModel.project(state, name: "p")
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let old = try #require(tab.splitRoot.allPanes().first)
        state.outdatedSessions = [old.sessionName]

        state.requestRestartSessions(tabID: tab.id, projectID: project.id)

        #expect(state.pendingDialog?.kind == .restartSessions(tabID: tab.id, projectID: project.id, paneID: nil))
        #expect(tab.splitRoot.allPanes().first?.id == old.id)

        state.confirmPendingDialog()
        #expect(tab.splitRoot.allPanes().first?.id != old.id)
    }

    @Test
    func a_pane_shows_the_badge_only_while_its_session_is_older() throws {
        let state = makeState()
        let project = TestModel.project(state, name: "p")
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        #expect(!state.showsOutdatedSessionBadge(pane))
        state.outdatedSessions = [pane.sessionName]
        #expect(state.showsOutdatedSessionBadge(pane))
        state.outdatedSessions = []
        #expect(!state.showsOutdatedSessionBadge(pane))
    }

    /// One rule over the panes of every project of the model: a pane of the
    /// quick terminal and a pane of a desktop widget show the Outdated pill
    /// as a pane of a project tab does.
    @Test
    func a_quick_terminal_pane_and_a_widget_pane_of_an_older_build_show_the_badge() throws {
        let state = makeState()
        let quickTab = try #require(state.quickTerminal.ensureTab())
        let quickPane = try #require(quickTab.splitRoot.allPanes().first)
        let widget = state.createDesktopWidget()
        let widgetPane = try #require(widget.tab?.splitRoot.allPanes().first)
        #expect(!state.showsOutdatedSessionBadge(quickPane))
        #expect(!state.showsOutdatedSessionBadge(widgetPane))

        state.outdatedSessions = [quickPane.sessionName, widgetPane.sessionName]

        #expect(state.showsOutdatedSessionBadge(quickPane))
        #expect(state.showsOutdatedSessionBadge(widgetPane))
    }

    @Test
    func the_badge_click_restarts_only_that_pane() throws {
        let state = makeState()
        state.paneNeedsConfirmClose = { _ in false }
        let project = TestModel.project(state, name: "p")
        state.splitPane(direction: .horizontal, projectID: project.id, projects: [project])
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let panes = tab.splitRoot.allPanes()
        state.outdatedSessions = Set(panes.map(\.sessionName))

        state.requestRestartSession(of: panes[0])

        let after = tab.splitRoot.allPanes()
        #expect(!after.contains { $0.id == panes[0].id })
        #expect(after.contains { $0.id == panes[1].id })
        #expect(state.model.pane(panes[0].id) == nil)
        #expect(state.outdatedSessions == [panes[1].sessionName])
    }
}
