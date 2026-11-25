import Foundation
@testable import Macterm
import Testing

/// The keyboard resize: the app finds the split and its new ratio
/// (`resizedRatio`, `nearestBranch`), and the server sets it.
@MainActor
struct SplitNodeResizeTests {
    private func branch(_ node: SplitNode) -> SplitBranch? {
        if case let .split(b) = node { return b }
        return nil
    }

    private func inner(_ node: SplitNode) -> SplitBranch? {
        guard case let .split(b) = node else { return nil }
        return branch(b.second)
    }

    @Test
    func resize_right_adjusts_horizontal_ancestor() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let pane = try #require(ids["a"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .right, delta: 0.1))
        #expect(result.0 == branch(tree)?.id)
        #expect(abs(result.1 - 0.6) < 0.0001)
    }

    @Test
    func resize_left_decreases_horizontal_ancestor_ratio() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let pane = try #require(ids["a"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .left, delta: 0.1))
        #expect(abs(result.1 - 0.4) < 0.0001)
    }

    @Test
    func resize_down_adjusts_vertical_ancestor() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        let pane = try #require(ids["a"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .down, delta: 0.1))
        #expect(abs(result.1 - 0.6) < 0.0001)
    }

    @Test
    func resize_skips_non_matching_axis_ancestors() throws {
        // Outer H, inner V that holds the focused pane.
        let (tree, ids) = build(H(pane("a"), V(pane("b1"), pane("b2"))))
        let pane = try #require(ids["b1"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .right, delta: 0.1))
        #expect(result.0 == branch(tree)?.id)
        #expect(abs(result.1 - 0.6) < 0.0001)
    }

    @Test
    func resize_clamps_to_upper_bound() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let pane = try #require(ids["a"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .right, delta: 10.0))
        #expect(abs(result.1 - 0.85) < 0.0001)
    }

    @Test
    func resize_clamps_to_lower_bound() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let pane = try #require(ids["a"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .left, delta: 10.0))
        #expect(abs(result.1 - 0.15) < 0.0001)
    }

    @Test
    func resize_on_root_leaf_is_noop() throws {
        let (tree, ids) = build(pane("a"))
        #expect(try tree.resizedRatio(paneID: #require(ids["a"]), direction: .right, delta: 0.1) == nil)
    }

    @Test
    func resize_with_no_split_of_the_axis_is_noop() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        #expect(try tree.resizedRatio(paneID: #require(ids["a"]), direction: .down, delta: 0.1) == nil)
    }

    @Test
    func resize_picks_deepest_matching_ancestor() throws {
        // Nested H in H: the deeper split wins.
        let (tree, ids) = build(H(pane("a"), H(pane("b"), pane("c"))))
        let pane = try #require(ids["b"])
        let result = try #require(tree.resizedRatio(paneID: pane, direction: .right, delta: 0.1))
        #expect(result.0 == inner(tree)?.id)
        #expect(abs(result.1 - 0.6) < 0.0001)
    }

    // MARK: - nearestBranch

    @Test
    func nearestBranch_finds_the_closest_split_of_the_axis() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), H(pane("c"), pane("d")))))
        let c = try #require(ids["c"])
        guard case let .split(root) = tree, case let .split(v) = root.second, case let .split(deep) = v.second else {
            Issue.record("unexpected shape")
            return
        }
        #expect(tree.nearestBranch(of: c, axis: .horizontal) === deep)
        #expect(tree.nearestBranch(of: c, axis: .vertical) === v)
        #expect(try tree.nearestBranch(of: #require(ids["a"]), axis: .horizontal) === root)
        #expect(try tree.nearestBranch(of: #require(ids["a"]), axis: .vertical) == nil)
    }

    @Test
    func nearestBranch_of_an_unknown_pane_is_nil() {
        let (tree, _) = build(H(pane("a"), pane("b")))
        #expect(tree.nearestBranch(of: UUID(), axis: .horizontal) == nil)
    }
}
