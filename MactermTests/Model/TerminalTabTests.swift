import Foundation
@testable import Macterm
import Testing

/// The reads of a tab: its titles, its status dot and its agent icon. The
/// server changes the tree (`server/src/model/`), so these tests make a tab
/// from a tree and read it.
@MainActor
struct TerminalTabTests {
    private func makeTab(_ spec: TreeSpec, focused: String? = nil, title: String? = nil) -> (TerminalTab, [String: UUID]) {
        let (tree, ids) = build(spec)
        let tab = TerminalTab(
            id: UUID(),
            splitRoot: tree,
            focusedPaneID: focused.flatMap { ids[$0] } ?? tree.allPanes().first?.id,
            customTitle: title
        )
        return (tab, ids)
    }

    private func paneNamed(_ name: String, in tab: TerminalTab, _ ids: [String: UUID]) throws -> Pane {
        let id = try #require(ids[name])
        return try #require(tab.splitRoot.findPane(id: id))
    }

    // MARK: - executionState

    @Test
    func executionState_prefers_running_then_unseen_then_idle() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        let b = try paneNamed("b", in: tab, ids)
        let c = try paneNamed("c", in: tab, ids)
        b.receiveAttention(MactermProtocol.Attention(unseen: true))
        c.receiveSessionStatus(MactermProtocol.Status(state: .running))
        #expect(tab.executionState == .running)
        c.receiveSessionStatus(MactermProtocol.Status(state: .done))
        #expect(tab.executionState == .done)
        b.receiveAttention(MactermProtocol.Attention())
        #expect(tab.executionState == .idle)
    }

    @Test
    func completionFailed_ranks_below_running_and_above_done() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        let a = try paneNamed("a", in: tab, ids)
        let b = try paneNamed("b", in: tab, ids)
        let c = try paneNamed("c", in: tab, ids)
        b.receiveAttention(MactermProtocol.Attention(unseen: true))
        c.receiveAttention(MactermProtocol.Attention(unseen: true, failed: true))
        // One pane passed and one failed: the failure shows.
        #expect(tab.executionState == .done)
        #expect(tab.completionFailed)
        // Work still under way outranks both.
        a.receiveSessionStatus(MactermProtocol.Status(state: .running))
        #expect(tab.executionState == .running)
        #expect(!tab.completionFailed)
        a.receiveSessionStatus(MactermProtocol.Status(state: .done))
        #expect(tab.completionFailed)
        // Seeing the failed pane leaves the passing one's green dot.
        c.markSeen()
        #expect(tab.executionState == .done)
        #expect(!tab.completionFailed)
    }

    @Test
    func markSeen_clears_every_pane_of_the_tab() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let a = try paneNamed("a", in: tab, ids)
        let b = try paneNamed("b", in: tab, ids)
        a.receiveAttention(MactermProtocol.Attention(unseen: true, failed: true))
        b.receiveAttention(MactermProtocol.Attention(bell: true))
        #expect(tab.hasUnseenBell)
        tab.markSeen()
        #expect(tab.executionState == .idle)
        #expect(!tab.completionFailed)
        #expect(!tab.hasUnseenBell)
    }

    // MARK: - focusedPane

    @Test
    func focusedPane_is_the_pane_of_the_focused_id() {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "b")
        #expect(tab.focusedPane?.id == ids["b"])
        let (unfocused, _) = build(H(pane("c"), pane("d")))
        #expect(TerminalTab(id: UUID(), splitRoot: unfocused, focusedPaneID: nil).focusedPane == nil)
        #expect(TerminalTab(id: UUID(), splitRoot: unfocused, focusedPaneID: UUID()).focusedPane == nil)
    }

    // MARK: - sidebarRowTitle (#227)

    @Test
    func sidebarRowTitle_four_or_more_panes_counts_them() {
        let (tab, _) = makeTab(H(H(pane("a"), pane("b")), H(pane("c"), pane("d"))))
        #expect(tab.sidebarRowTitle == "4 panes")
    }

    @Test
    func sidebarRowTitle_rename_wins_over_pane_count() {
        let (tab, _) = makeTab(H(H(pane("a"), pane("b")), H(pane("c"), pane("d"))), title: "my workbench")
        #expect(tab.sidebarRowTitle == "my workbench")
    }

    @Test
    func sidebarRowTitle_below_four_panes_keeps_normal_title() {
        let (tab, _) = makeTab(H(pane("a"), H(pane("b"), pane("c"))))
        #expect(tab.sidebarRowTitle == tab.sidebarTitle)
    }

    // MARK: - autoTitle / sidebarTitle / customTitle

    @Test
    func sidebarTitle_returns_customTitle_when_set() {
        let (tab, _) = makeTab(pane("a"), title: "My Tab")
        #expect(tab.sidebarTitle == "My Tab")
    }

    @Test
    func sidebarTitle_falls_back_to_autoTitle_when_customTitle_nil() {
        let (tab, _) = makeTab(pane("a"))
        #expect(tab.sidebarTitle == tab.autoTitle)
    }

    @Test
    func autoTitle_is_unaffected_by_customTitle() {
        let (tree, _) = build(pane("a"))
        let plain = TerminalTab(id: UUID(), splitRoot: tree, focusedPaneID: nil)
        let renamed = TerminalTab(id: UUID(), splitRoot: tree, focusedPaneID: nil, customTitle: "My Tab")
        #expect(renamed.autoTitle == plain.autoTitle)
    }

    @Test
    func autoTitle_joins_multiple_pane_titles_with_separator() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")))
        // Both panes have the same title in a test, so the test checks
        // only that the title has two segments.
        let parts = tab.autoTitle.components(separatedBy: " | ")
        #expect(parts.count == 2)
    }

    // MARK: - Agent icon

    @Test
    func tab_agentIcon_prefers_focused_pane() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "b")
        try paneNamed("a", in: tab, ids).applyForegroundName("codex")
        try paneNamed("b", in: tab, ids).applyForegroundName("claude")
        #expect(tab.agentIcon == .claude)
    }

    @Test
    func tab_agentIcon_falls_back_to_any_pane_running_an_agent() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "b")
        try paneNamed("a", in: tab, ids).applyForegroundName("grok")
        try paneNamed("b", in: tab, ids).applyForegroundName("zsh")
        #expect(tab.agentIcon == .grok)
    }

    @Test
    func tab_agentIcon_is_nil_when_no_agent_runs() throws {
        let (tab, ids) = makeTab(pane("a"))
        try paneNamed("a", in: tab, ids).applyForegroundName("zsh")
        #expect(tab.agentIcon == nil)
    }
}
