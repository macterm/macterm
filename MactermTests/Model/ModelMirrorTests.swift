import Foundation
@testable import Macterm
import Testing

/// The mirror applies the server's batches as the server sends them
/// (`model_ipc.zig`, `diff`): what is made or changed first, then what went.
@MainActor
struct ModelMirrorTests {
    private func pane(_ id: String) -> MactermProtocol.Node {
        .pane(.init(id: id, session: "macterm-x-\(id)"))
    }

    private func tab(_ id: String, _ paneID: String) -> MactermProtocol.Tab {
        .init(id: id, root: pane(paneID), focused: paneID)
    }

    private func state(seq: UInt64, model: MactermProtocol.ModelData?) -> MactermProtocol.StateSubscribe.Result {
        .init(epoch: 7, seq: seq, model: model, sessions: [], client: 1)
    }

    private func batch(_ seq: UInt64, _ events: [MactermProtocol.EventKind]) -> ServerEventBatch {
        ServerEventBatch(seq: seq, events: events.map { .model($0) })
    }

    private let project = MactermProtocol.Project(id: "p1", name: "One", path: "/a")

    @Test
    func a_new_tab_takes_the_order_of_its_workspace_at_the_end_of_the_batch() {
        let mirror = ModelMirror()
        mirror.install(state(
            seq: 3,
            model: .init(projects: [project], workspaces: [.init(id: "p1", kind: .project, tabs: [tab("t1", "a")])])
        ))
        mirror.apply(batch(4, [
            .tabOrder(.init(workspace: "p1", kind: .project, ids: ["t2", "t1"], activeTab: "t2")),
            .tabChanged(.init(workspace: "p1", tab: tab("t2", "b"), zoomed: "b")),
        ]))

        let ws = mirror.data?.workspaces.first
        #expect(ws?.tabs.map(\.id) == ["t2", "t1"])
        #expect(ws?.activeTab == "t2")
        #expect(mirror.zoomed == ["t2": "b"])
        #expect(mirror.seq == 4)
    }

    @Test
    func a_tab_that_moves_leaves_its_old_workspace() {
        let mirror = ModelMirror()
        mirror.install(state(
            seq: 1,
            model: .init(projects: [project], workspaces: [.init(id: "p1", kind: .project, tabs: [tab("t1", "a")], activeTab: "t1")])
        ))
        mirror.apply(batch(2, [
            .tabOrder(.init(workspace: "pin", kind: .pinned, ids: ["t1"], activeTab: "t1")),
            .tabOrder(.init(workspace: "p1", kind: .project, ids: [])),
            .tabChanged(.init(workspace: "pin", tab: tab("t1", "a"))),
        ]))

        let spaces = Dictionary(uniqueKeysWithValues: (mirror.data?.workspaces ?? []).map { ($0.id, $0) })
        #expect(spaces["p1"]?.tabs.isEmpty == true)
        #expect(spaces["p1"]?.activeTab == nil)
        #expect(spaces["pin"]?.kind == .pinned)
        #expect(spaces["pin"]?.tabs.map(\.id) == ["t1"])
    }

    @Test
    func a_removed_project_takes_its_workspace_and_removed_objects_go() {
        let mirror = ModelMirror()
        let model = MactermProtocol.ModelData(
            projects: [project],
            workspaces: [
                .init(id: "p1", kind: .project, tabs: [tab("t1", "a"), tab("t2", "b")]),
                .init(id: "w1", kind: .widget, tabs: [tab("t3", "c")]),
            ],
            selection: .init(activeProject: "p1")
        )
        mirror.install(state(seq: 1, model: model))
        mirror.apply(batch(2, [
            .tabOrder(.init(workspace: "p1", kind: .project, ids: ["t1"])),
            .tabRemoved(.init(workspace: "p1", id: "t2")),
            .paneRemoved(.init(id: "b", session: "macterm-x-b")),
        ]))
        #expect(mirror.data?.workspaces.first?.tabs.map(\.id) == ["t1"])

        mirror.apply(batch(3, [
            .workspaceRemoved(.init(id: "w1")),
            .projectRemoved(.init(id: "p1")),
            .selectionChanged(.init(activeProject: nil)),
        ]))
        #expect(mirror.data == MactermProtocol.ModelData())
    }

    @Test
    func batches_before_the_state_wait_and_old_ones_are_skipped() {
        let mirror = ModelMirror()
        let renamed = MactermProtocol.Project(id: "p1", name: "Two", path: "/a")
        // Seq 2 is in the state already; seq 3 is newer.
        mirror.apply(batch(2, [.projectChanged(.init(project: .init(id: "p1", name: "Old", path: "/a")))]))
        mirror.apply(batch(3, [.projectChanged(.init(project: renamed))]))
        #expect(mirror.data == nil)

        mirror.install(state(seq: 2, model: .init(projects: [project], workspaces: [.init(id: "p1", kind: .project)])))
        #expect(mirror.data?.projects == [renamed])
        #expect(mirror.seq == 3)

        mirror.apply(batch(3, [.projectChanged(.init(project: project))]))
        #expect(mirror.data?.projects == [renamed])

        mirror.reset()
        #expect(mirror.data == nil)
        #expect(mirror.epoch == nil)
    }

    @Test
    func a_server_with_no_model_gives_no_data() {
        let mirror = ModelMirror()
        mirror.install(state(seq: 0, model: nil))
        mirror.apply(batch(1, [.projectChanged(.init(project: project))]))
        #expect(mirror.data == nil)
    }
}
