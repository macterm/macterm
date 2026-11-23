import Foundation
@testable import Macterm
import Testing

@MainActor
struct SidebarTreeTests {
    private func makeStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-sidebar-tree-tests-\(UUID().uuidString).json"))
    }

    /// Top level: `a`, group `g` (holds `b` and group `inner` with `c`), `d`.
    /// A group is a project with no folder.
    private struct Fixture {
        let store: ProjectStore
        let a: Project
        let g: Project
        let b: Project
        let inner: Project
        let c: Project
        let d: Project
    }

    private func makeFixture() -> Fixture {
        let store = makeStore()
        let a = store.create(name: "a", path: "/tmp/a")
        let g = store.add(Project(name: "g", path: ""))
        let b = store.add(Project(name: "b", path: "/tmp/b", parent: g.id))
        let inner = store.add(Project(name: "inner", path: "", parent: g.id))
        let c = store.add(Project(name: "c", path: "/tmp/c", parent: inner.id))
        let d = store.create(name: "d", path: "/tmp/d")
        return Fixture(store: store, a: a, g: g, b: b, inner: inner, c: c, d: d)
    }

    private func names(_ nodes: [SidebarNode]) -> [String] {
        nodes.map { node in
            switch node {
            case let .group(group, children): "\(group.name)(\(names(children).joined(separator: ",")))"
            case let .project(project): project.name
            }
        }
    }

    @Test
    func nodes_nest_groups_in_store_order() {
        let f = makeFixture()
        #expect(names(SidebarTree.nodes(in: f.store)) == ["a", "g(b,inner(c))", "d"])
    }

    @Test
    func selectable_items_skip_groups_and_the_rows_of_closed_groups() {
        let f = makeFixture()
        let nodes = SidebarTree.nodes(in: f.store)
        let tab = UUID()
        let tabs: (UUID) -> [UUID] = { $0 == f.b.id ? [tab] : [] }

        let closed = SidebarTree.selectableItems(nodes, expanded: [], tabs: tabs)
        #expect(closed == [.project(f.a.id), .project(f.d.id)])

        let open = SidebarTree.selectableItems(nodes, expanded: [f.g.id, f.b.id], tabs: tabs)
        #expect(open == [
            .project(f.a.id), .project(f.b.id), .tab(projectID: f.b.id, tabID: tab), .project(f.d.id),
        ], "the closed inner group hides c, and no group is an item")

        let all = SidebarTree.selectableItems(nodes, expanded: [f.g.id, f.inner.id], tabs: tabs)
        #expect(all == [.project(f.a.id), .project(f.b.id), .project(f.c.id), .project(f.d.id)])
    }

    @Test
    func groups_to_open_are_every_group_above_the_project() {
        let f = makeFixture()
        #expect(Set(SidebarTree.groupsToOpen(for: f.c.id, in: f.store)) == [f.g.id, f.inner.id])
        #expect(SidebarTree.groupsToOpen(for: f.a.id, in: f.store).isEmpty)
    }

    @Test
    func drop_on_a_group_header_moves_the_project_in() {
        let f = makeFixture()
        #expect(SidebarTree.drop(f.a.id, onto: f.inner, in: f.store))
        #expect(f.store.row(f.a.id)?.parent == f.inner.id)
        #expect(f.store.children(of: f.inner.id).map(\.name) == ["c", "a"])
    }

    @Test
    func drop_on_a_project_header_puts_the_project_beside_it() {
        let f = makeFixture()
        // From another parent: before the target, in the target's parent.
        #expect(SidebarTree.drop(f.d.id, onto: f.b, in: f.store))
        #expect(f.store.children(of: f.g.id).map(\.name) == ["d", "b", "inner"])
        // In one parent, downward: after the target.
        #expect(SidebarTree.drop(f.d.id, onto: f.b, in: f.store))
        #expect(f.store.children(of: f.g.id).map(\.name) == ["b", "d", "inner"])
        // Upward: before the target.
        #expect(SidebarTree.drop(f.inner.id, onto: f.b, in: f.store))
        #expect(f.store.children(of: f.g.id).map(\.name) == ["inner", "b", "d"])
    }

    @Test
    func drop_of_a_group_into_itself_is_refused() {
        let f = makeFixture()
        #expect(!SidebarTree.drop(f.g.id, onto: f.inner, in: f.store))
        #expect(!SidebarTree.drop(f.g.id, onto: f.g, in: f.store))
        #expect(!SidebarTree.drop(f.g.id, onto: f.c, in: f.store), "beside c is inside g")
        #expect(f.store.row(f.g.id)?.parent == nil)
    }

    @Test
    func move_targets_leave_out_the_parent_and_the_groups_inside_the_row() {
        let f = makeFixture()
        #expect(SidebarTree.moveTargets(for: f.b.id, in: f.store).map(\.id) == [f.inner.id])
        #expect(SidebarTree.moveTargets(for: f.a.id, in: f.store).map(\.id) == [f.g.id, f.inner.id])
        #expect(SidebarTree.moveTargets(for: f.g.id, in: f.store).isEmpty)
    }

    @Test
    func path_name_joins_the_groups_above() {
        let f = makeFixture()
        #expect(SidebarTree.pathName(of: f.inner, in: f.store) == "g / inner")
        #expect(SidebarTree.pathName(of: f.g, in: f.store) == "g")
    }

    @Test
    func the_children_of_a_project_with_a_folder_follow_it() {
        let f = makeFixture()
        let child = f.store.add(Project(name: "child", path: "/tmp/child", parent: f.a.id))
        _ = child
        #expect(names(SidebarTree.nodes(in: f.store)).first == "a")
        #expect(Array(names(SidebarTree.nodes(in: f.store)).prefix(2)) == ["a", "child"])
    }
}
