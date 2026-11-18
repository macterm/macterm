import Foundation
@testable import Macterm
import Observation
import Testing

@MainActor
private final class ObservationFlag {
    var wasInvalidated = false
}

@MainActor
struct WorkspaceTests {
    private func makeWorkspace() -> Workspace {
        Workspace(id: UUID(), projectPath: "/tmp")
    }

    @Test
    func the_kind_comes_from_the_workspace_id() {
        #expect(Workspace(id: PinnedTabs.workspaceID, tabs: [], activeTabID: nil).kind == .pinned)
        #expect(Workspace(id: ScratchTabs.workspaceID, tabs: [], activeTabID: nil).kind == .scratch)
        #expect(makeWorkspace().kind == .project)
    }

    @Test
    func a_remote_workspace_has_a_lost_link_while_any_of_its_panes_is_lost() throws {
        let ws = Workspace(id: UUID(), projectPath: "box:/srv")
        let second = ModelWriter.tabCreate(in: ws, projectPath: "box:/srv", focus: false)
        let first = try #require(second.splitRoot.allPanes().first)
        let splitID = try #require(ModelWriter.paneSplit(second, paneID: first.id, direction: .vertical))
        let nested = try #require(second.splitRoot.findPane(id: splitID))
        #expect(!ws.hasLostRemoteLink)
        nested.isRemoteLinkLost = true
        #expect(ws.hasLostRemoteLink)
        first.isRemoteLinkLost = true
        nested.isRemoteLinkLost = false
        #expect(ws.hasLostRemoteLink)
        first.isRemoteLinkLost = false
        #expect(!ws.hasLostRemoteLink)
    }

    @Test
    func the_lost_link_of_a_workspace_notifies_an_observer_when_it_drops_and_when_it_heals() throws {
        let ws = Workspace(id: UUID(), projectPath: "box:/srv")
        let pane = try #require(ws.tabs.first?.splitRoot.allPanes().first)
        func observe() -> ObservationFlag {
            let flag = ObservationFlag()
            withObservationTracking { _ = ws.hasLostRemoteLink } onChange: {
                MainActor.assumeIsolated { flag.wasInvalidated = true }
            }
            return flag
        }
        let drop = observe()
        pane.isRemoteLinkLost = true
        #expect(drop.wasInvalidated)
        let heal = observe()
        pane.isRemoteLinkLost = false
        #expect(heal.wasInvalidated)
    }

    @Test
    func a_local_workspace_never_has_a_lost_link() {
        let ws = makeWorkspace()
        ws.tabs[0].splitRoot.allPanes()[0].isRemoteLinkLost = true
        #expect(!ws.hasLostRemoteLink)
    }

    @Test
    func init_creates_one_tab_and_selects_it() {
        let ws = makeWorkspace()
        #expect(ws.tabs.count == 1)
        #expect(ws.activeTabID == ws.tabs[0].id)
    }

    @Test
    func createTab_appends_and_selects() {
        let ws = makeWorkspace()
        let original = ws.tabs[0].id
        let new = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        #expect(ws.tabs.count == 2)
        #expect(ws.activeTabID == new.id)
        #expect(original != new.id)
    }

    @Test
    func createTab_without_focus_never_visits_or_records_the_new_tab() {
        let ws = makeWorkspace()
        let previous = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let current = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let recency = ws.recencyOrder()
        var selections = 0
        ws.onActiveTabChanged = { selections += 1 }

        let background = ModelWriter.tabCreate(in: ws, projectPath: "/tmp", focus: false)

        #expect(ws.activeTabID == current.id)
        #expect(selections == 0)
        #expect(ws.recencyOrder() == recency + [background.id])
        ModelWriter.tabClose(current.id, in: ws)
        #expect(ws.activeTabID == previous.id)
    }

    @Test
    func createTab_without_focus_adopts_first_tab_when_workspace_empty() {
        let ws = makeWorkspace()
        ModelWriter.tabClose(ws.tabs[0].id, in: ws)
        #expect(ws.tabs.isEmpty)
        #expect(ws.activeTabID == nil)

        let background = ModelWriter.tabCreate(in: ws, projectPath: "/tmp", focus: false)

        #expect(ws.tabs.count == 1)
        #expect(ws.activeTabID == background.id)
        // Adoption records no history entry: the new tab is active on its own.
        #expect(ws.recencyOrder() == [background.id])
    }

    @Test
    func createTab_without_focus_publishes_selection_when_adopting_into_empty_workspace() {
        let ws = makeWorkspace()
        ModelWriter.tabClose(ws.tabs[0].id, in: ws)
        var selections = 0
        ws.onActiveTabChanged = { selections += 1 }

        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp", focus: false)

        #expect(selections == 1)
    }

    @Test
    func adoptTab_appends_existing_tab_and_selects_it() {
        let ws = makeWorkspace()
        let original = ws.tabs[0].id
        let incoming = TerminalTab(projectPath: "/elsewhere", projectID: UUID())
        ModelWriter.tabInsert(incoming, into: ws)
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.last?.id == incoming.id)
        #expect(ws.activeTabID == incoming.id)
        _ = original
    }

    @Test
    func adoptTab_pushes_previous_active_onto_history() {
        let ws = makeWorkspace()
        let original = ws.tabs[0].id
        let incoming = TerminalTab(projectPath: "/elsewhere", projectID: UUID())
        ModelWriter.tabInsert(incoming, into: ws)
        // Closing the adopted (active) tab should fall back to the prior active.
        ModelWriter.tabClose(incoming.id, in: ws)
        #expect(ws.activeTabID == original)
    }

    @Test
    func closeTab_active_selects_most_recent_from_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        let t3 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        #expect(ws.activeTabID == t3)
        ModelWriter.tabClose(t3, in: ws)
        #expect(ws.activeTabID == t2)
        #expect(!ws.tabs.contains(where: { $0.id == t3 }))
        _ = t1
    }

    @Test
    func closeTab_nonactive_leaves_active_alone() {
        let ws = makeWorkspace()
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        let before = ws.activeTabID
        ModelWriter.tabClose(ws.tabs[0].id, in: ws)
        #expect(ws.activeTabID == before)
        _ = t2
    }

    @Test
    func closeTab_invalid_id_is_noop() {
        let ws = makeWorkspace()
        ModelWriter.tabClose(UUID(), in: ws)
        #expect(ws.tabs.count == 1)
    }

    @Test
    func closeTab_empties_activeTabID_when_no_tabs_left() {
        let ws = makeWorkspace()
        let only = ws.tabs[0].id
        ModelWriter.tabClose(only, in: ws)
        #expect(ws.activeTabID == nil)
    }

    @Test
    func selectNextTab_wraps() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        #expect(ws.activeTabID == t2)
        ModelWriter.tabSelectNext(in: ws)
        #expect(ws.activeTabID == t1)
        ModelWriter.tabSelectNext(in: ws)
        #expect(ws.activeTabID == t2)
    }

    @Test
    func selectPreviousTab_wraps() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        ModelWriter.tabSelectPrevious(in: ws)
        #expect(ws.activeTabID == t1)
        ModelWriter.tabSelectPrevious(in: ws)
        #expect(ws.activeTabID == t2)
    }

    @Test
    func selectNextTab_single_tab_is_noop() {
        let ws = makeWorkspace()
        let only = ws.tabs[0].id
        ModelWriter.tabSelectNext(in: ws)
        #expect(ws.activeTabID == only)
    }

    @Test
    func selectTab_ignores_unknown_id() {
        let ws = makeWorkspace()
        let before = ws.activeTabID
        ModelWriter.tabSelect(UUID(), in: ws)
        #expect(ws.activeTabID == before)
    }

    @Test
    func selectTab_marks_only_the_selected_tab_seen() {
        let ws = makeWorkspace()
        let selected = ws.tabs[0]
        let other = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let unseen = MactermProtocol.Attention(unseen: true)
        selected.splitRoot.allPanes().first?.receiveAttention(unseen)
        other.splitRoot.allPanes().first?.receiveAttention(unseen)
        let selectedID = selected.id
        ModelWriter.tabSelect(selectedID, in: ws)
        #expect(ws.activeTabID == selectedID)
        #expect(selected.executionState == .idle)
        #expect(other.executionState == .done)
    }

    @Test
    func recencyOrder_active_first_then_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        let t3 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        ModelWriter.tabSelect(t1, in: ws)
        let order = ws.recencyOrder()
        #expect(order.first == t1)
        #expect(order.count == 3)
        _ = (t2, t3)
    }

    @Test
    func recencyOrder_includes_unvisited_tabs_at_tail() {
        let ws = makeWorkspace()
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let order = ws.recencyOrder()
        #expect(Set(order) == Set(ws.tabs.map(\.id)))
    }

    @Test
    func peekTab_does_not_record_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        ModelWriter.tabPeek(t1, in: ws)
        #expect(ws.activeTabID == t1)
        ModelWriter.tabClose(t1, in: ws)
        #expect(ws.activeTabID == t2)
    }

    @Test
    func selectTabByIndex_selects_tab_at_index() {
        let ws = makeWorkspace()
        _ = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let t3 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        ModelWriter.tabSelect(index: 2, in: ws)
        #expect(ws.activeTabID == t3)
    }

    @Test
    func selectTabByIndex_out_of_range_is_noop() {
        let ws = makeWorkspace()
        let before = ws.activeTabID
        ModelWriter.tabSelect(index: 99, in: ws)
        #expect(ws.activeTabID == before)
    }

    @Test
    func reorderTabs_moves_tabs() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        ModelWriter.tabReorder(in: ws, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(ws.tabs.map(\.id) == [t2, t1])
    }

    // MARK: - Drag-and-drop insert/move by absolute index

    @Test
    func adoptTab_inserts_at_index() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        let incoming = TerminalTab(projectPath: "/elsewhere", projectID: UUID())
        ModelWriter.tabInsert(incoming, into: ws, at: 1)
        #expect(ws.tabs.map(\.id) == [t1, incoming.id, t2])
        #expect(ws.activeTabID == incoming.id)
    }

    @Test
    func adoptTab_out_of_range_index_appends() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let incoming = TerminalTab(projectPath: "/elsewhere", projectID: UUID())
        ModelWriter.tabInsert(incoming, into: ws, at: 99)
        #expect(ws.tabs.map(\.id) == [t1, incoming.id])
    }

    @Test
    func moveTab_toIndex_reorders_within_project() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        let t3 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        // Drop t1 at the end (offset 3, pre-removal coordinates).
        ModelWriter.tabReorder(t1, in: ws, toIndex: 3)
        #expect(ws.tabs.map(\.id) == [t2, t3, t1])
        // Drop t1 back to the front.
        ModelWriter.tabReorder(t1, in: ws, toIndex: 0)
        #expect(ws.tabs.map(\.id) == [t1, t2, t3])
    }

    @Test
    func moveTab_toIndex_same_slot_is_noop() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ModelWriter.tabCreate(in: ws, projectPath: "/tmp").id
        ModelWriter.tabReorder(t1, in: ws, toIndex: 0)
        #expect(ws.tabs.map(\.id) == [t1, t2])
    }

    @Test
    func moveTab_toIndex_unknown_tab_is_noop() {
        let ws = makeWorkspace()
        let before = ws.tabs.map(\.id)
        ModelWriter.tabReorder(UUID(), in: ws, toIndex: 0)
        #expect(ws.tabs.map(\.id) == before)
    }
}
