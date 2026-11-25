import Foundation
@testable import Macterm
import Testing

@MainActor
struct SidebarTreeTests {
    private func makeStore() -> ProjectStore {
        let store = ProjectStore(writer: ModelWriter(connection: TestModel.connection()))
        store.autoAssignsColors = { false }
        return store
    }

    /// Top level: `a`, `g` (holds `b` and `inner`, which holds `c`), `d`.
    /// `g` and `inner` have no folder, as a dev build's old group rows; the
    /// tree treats them as every other project.
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
        func stored(_ project: Project?) -> Project {
            guard let project else { preconditionFailure("the test server refused the project") }
            return project
        }
        let a = stored(store.create(name: "a", path: "/tmp/a"))
        let g = stored(store.add(Project(name: "g", path: "")))
        let b = stored(store.add(Project(name: "b", path: "/tmp/b", parent: g.id)))
        let inner = stored(store.add(Project(name: "inner", path: "/tmp/inner", parent: g.id)))
        let c = stored(store.add(Project(name: "c", path: "/tmp/c", parent: inner.id)))
        let d = stored(store.create(name: "d", path: "/tmp/d"))
        return Fixture(store: store, a: a, g: g, b: b, inner: inner, c: c, d: d)
    }

    private func names(_ nodes: [SidebarNode]) -> [String] {
        nodes.map { node in
            node.children.isEmpty
                ? node.project.name
                : "\(node.project.name)(\(names(node.children).joined(separator: ",")))"
        }
    }

    @Test
    func nodes_nest_projects_in_store_order() {
        let f = makeFixture()
        #expect(names(SidebarTree.nodes(in: f.store)) == ["a", "g(b,inner(c))", "d"])
    }

    @Test
    func a_project_with_a_folder_holds_its_children() {
        let f = makeFixture()
        _ = f.store.add(Project(name: "child", path: "/tmp/child", parent: f.a.id))
        #expect(names(SidebarTree.nodes(in: f.store)) == ["a(child)", "g(b,inner(c))", "d"])
    }

    @Test
    func selectable_items_list_tabs_then_children_of_open_projects() {
        let f = makeFixture()
        let nodes = SidebarTree.nodes(in: f.store)
        let gTab = UUID()
        let bTab = UUID()
        let tabs: (UUID) -> [UUID] = { id in
            switch id {
            case f.g.id: [gTab]
            case f.b.id: [bTab]
            default: []
            }
        }

        let closed = SidebarTree.selectableItems(nodes, expanded: [], tabs: tabs)
        #expect(closed == [.project(f.a.id), .project(f.g.id), .project(f.d.id)])

        let open = SidebarTree.selectableItems(nodes, expanded: [f.g.id, f.b.id], tabs: tabs)
        #expect(open == [
            .project(f.a.id),
            .project(f.g.id), .tab(projectID: f.g.id, tabID: gTab),
            .project(f.b.id), .tab(projectID: f.b.id, tabID: bTab),
            .project(f.inner.id),
            .project(f.d.id),
        ], "a parent's tabs come before its children, and the closed inner hides c")

        let hidden = SidebarTree.selectableItems(nodes, expanded: [f.b.id, f.inner.id], tabs: tabs)
        #expect(hidden == [.project(f.a.id), .project(f.g.id), .project(f.d.id)], "a closed parent hides every row inside it")
    }

    @Test
    func parents_to_open_are_every_project_above() {
        let f = makeFixture()
        #expect(Set(SidebarTree.parentsToOpen(for: f.c.id, in: f.store)) == [f.g.id, f.inner.id])
        #expect(SidebarTree.parentsToOpen(for: f.a.id, in: f.store).isEmpty)
    }

    @Test
    func drop_on_a_project_header_moves_the_project_inside() {
        let f = makeFixture()
        #expect(SidebarTree.drop(f.a.id, onto: f.inner, in: f.store))
        #expect(f.store.row(f.a.id)?.parent == f.inner.id)
        #expect(f.store.children(of: f.inner.id).map(\.name) == ["c", "a"])

        #expect(SidebarTree.drop(f.d.id, onto: f.b, in: f.store), "a project with a folder takes a project too")
        #expect(f.store.row(f.d.id)?.parent == f.b.id)
    }

    @Test
    func drop_of_a_project_into_itself_is_refused() {
        let f = makeFixture()
        #expect(!SidebarTree.drop(f.g.id, onto: f.inner, in: f.store))
        #expect(!SidebarTree.drop(f.g.id, onto: f.g, in: f.store))
        #expect(!SidebarTree.drop(f.g.id, onto: f.c, in: f.store))
        #expect(f.store.row(f.g.id)?.parent == nil)
    }

    @Test
    func move_targets_leave_out_the_parent_itself_and_the_projects_inside() {
        let f = makeFixture()
        #expect(SidebarTree.moveTargets(for: f.b.id, in: f.store).map(\.id) == [f.a.id, f.inner.id, f.c.id, f.d.id])
        #expect(SidebarTree.moveTargets(for: f.g.id, in: f.store).map(\.id) == [f.a.id, f.d.id])
        #expect(SidebarTree.moveTargets(for: f.c.id, in: f.store).map(\.id) == [f.a.id, f.g.id, f.b.id, f.d.id])
    }

    @Test
    func path_name_joins_the_projects_above() {
        let f = makeFixture()
        #expect(SidebarTree.pathName(of: f.c, in: f.store) == "g/inner/c")
        #expect(SidebarTree.pathName(of: f.g, in: f.store) == "g")
    }
}
