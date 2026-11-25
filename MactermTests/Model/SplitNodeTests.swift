import Foundation
@testable import Macterm
import Testing

@MainActor
struct SplitNodeTests {
    // MARK: - PaneDropZone

    @Test
    func dropZone_picks_nearest_edge() {
        let size = CGSize(width: 100, height: 100)
        #expect(PaneDropZone.calculate(at: CGPoint(x: 10, y: 50), in: size) == .left)
        #expect(PaneDropZone.calculate(at: CGPoint(x: 90, y: 50), in: size) == .right)
        #expect(PaneDropZone.calculate(at: CGPoint(x: 50, y: 10), in: size) == .top)
        #expect(PaneDropZone.calculate(at: CGPoint(x: 50, y: 90), in: size) == .bottom)
    }

    @Test
    func dropZone_maps_to_split_direction_and_position() {
        #expect(PaneDropZone.left.splitDirection == .horizontal)
        #expect(PaneDropZone.left.splitPosition == .first)
        #expect(PaneDropZone.right.splitDirection == .horizontal)
        #expect(PaneDropZone.right.splitPosition == .second)
        #expect(PaneDropZone.top.splitDirection == .vertical)
        #expect(PaneDropZone.top.splitPosition == .first)
        #expect(PaneDropZone.bottom.splitDirection == .vertical)
        #expect(PaneDropZone.bottom.splitPosition == .second)
    }

    // MARK: - findPane / contains / allPanes

    @Test
    func findPane_returns_same_instance() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let tree: SplitNode = .split(SplitBranch(
            direction: .horizontal,
            first: .pane(p),
            second: .pane(Pane(projectPath: "/", projectID: UUID()))
        ))
        #expect(tree.findPane(id: p.id) === p)
    }

    @Test
    func findPane_returns_nil_for_missing() {
        let (tree, _) = build(pane("a"))
        #expect(tree.findPane(id: UUID()) == nil)
    }

    @Test
    func contains_matches_allPanes() {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let all = Set(tree.allPanes().map(\.id))
        for (_, id) in ids {
            #expect(tree.contains(paneID: id))
            #expect(all.contains(id))
        }
        #expect(!tree.contains(paneID: UUID()))
    }

    @Test
    func allPanes_count_matches_leaf_count() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), V(pane("c"), pane("d")))))
        #expect(tree.allPanes().count == 4)
    }
}
