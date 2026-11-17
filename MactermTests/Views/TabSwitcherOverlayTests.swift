import Foundation
@testable import Macterm
import Testing

/// The tab switcher marks the focused pane of a split tab with an outline,
/// and dims no pane (0327).
@MainActor
struct TabSwitcherOverlayTests {
    @Test
    func split_tab_marks_its_focused_pane() throws {
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let focused = try #require(ids["r"])
        #expect(TabSwitcherMosaic.markedPaneID(in: tree, focusedPaneID: focused) == focused)
    }

    @Test
    func single_pane_tab_marks_nothing() throws {
        let (tree, ids) = build(pane("a"))
        let focused = try #require(ids["a"])
        #expect(TabSwitcherMosaic.markedPaneID(in: tree, focusedPaneID: focused) == nil)
    }

    @Test
    func split_tab_with_no_focus_marks_nothing() {
        let (tree, _) = build(H(pane("l"), pane("r")))
        #expect(TabSwitcherMosaic.markedPaneID(in: tree, focusedPaneID: nil) == nil)
    }
}
