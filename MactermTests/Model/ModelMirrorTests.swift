import Foundation
@testable import Macterm
import Testing

/// The mirror applies the server's batches as the server sends them
/// (`model_ipc.zig`, `diff`): what is made or changed first, then what went.
@MainActor
struct ModelMirrorTests {
    private func pane(_ id: String) -> MactermProtocol.SplitNode {
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

    private func info(_ id: String, _ name: String) -> MactermProtocol.ProjectInfo {
        .init(id: id, name: name, path: "/a")
    }

    @Test
    func a_new_tab_takes_the_order_of_its_project_at_the_end_of_the_batch() {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a")]
        mirror.install(state(seq: 3, model: .init(projects: [p])))
        mirror.apply(batch(4, [
            .tabOrder(.init(project: "p1", ids: ["t2", "t1"], activeTab: "t2")),
            .tabChanged(.init(project: "p1", tab: tab("t2", "b"), zoomed: "b")),
        ]))

        let got = mirror.data?.projects.first
        #expect(got?.tabs.map(\.id) == ["t2", "t1"])
        #expect(got?.activeTab == "t2")
        #expect(mirror.zoomed == ["t2": "b"])
        #expect(mirror.seq == 4)
    }

    @Test
    func a_tab_that_moves_leaves_its_old_project_for_a_new_hidden_one() {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a")]
        p.activeTab = "t1"
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        let pinned = MactermProtocol.ProjectInfo(id: "pin", name: "Pinned", path: "", sidebar: .top, removable: false, alias: "pinned")
        mirror.apply(batch(2, [
            .projectChanged(.init(project: pinned)),
            .tabOrder(.init(project: "pin", ids: ["t1"], activeTab: "t1")),
            .tabOrder(.init(project: "p1", ids: [])),
            .tabChanged(.init(project: "pin", tab: tab("t1", "a"))),
        ]))

        let projects = Dictionary(uniqueKeysWithValues: (mirror.data?.projects ?? []).map { ($0.id, $0) })
        #expect(projects["p1"]?.tabs.isEmpty == true)
        #expect(projects["p1"]?.activeTab == nil)
        #expect(projects["pin"]?.sidebar == .top)
        #expect(projects["pin"]?.alias == "pinned")
        #expect(projects["pin"]?.tabs.map(\.id) == ["t1"])
    }

    @Test
    func a_changed_project_keeps_its_tabs() {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a")]
        p.activeTab = "t1"
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        mirror.apply(batch(2, [.projectChanged(.init(project: info("p1", "Renamed")))]))
        #expect(mirror.data?.projects.first?.name == "Renamed")
        #expect(mirror.data?.projects.first?.tabs.map(\.id) == ["t1"])
        #expect(mirror.data?.projects.first?.activeTab == "t1")
    }

    @Test
    func a_tab_event_for_a_project_that_the_mirror_does_not_have_changes_nothing() {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a")]
        p.activeTab = "t1"
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        mirror.apply(batch(2, [
            .tabOrder(.init(project: "zz", ids: ["t1"], activeTab: "t1")),
            .tabChanged(.init(project: "zz", tab: tab("t1", "a"))),
        ]))
        #expect(mirror.data?.projects == [p])
        #expect(mirror.seq == 2)
    }

    @Test
    func a_removed_project_takes_its_tabs_and_removed_objects_go() {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a"), tab("t2", "b")]
        let widget = MactermProtocol.Project(id: "w1", name: "Widget", path: "", sidebar: .none, singleTab: true, tabs: [tab("t3", "c")])
        let model = MactermProtocol.ModelData(projects: [p, widget], selection: .init(activeProject: "p1"))
        mirror.install(state(seq: 1, model: model))
        mirror.apply(batch(2, [
            .tabOrder(.init(project: "p1", ids: ["t1"])),
            .tabRemoved(.init(project: "p1", id: "t2")),
            .paneRemoved(.init(id: "b", session: "macterm-x-b")),
        ]))
        #expect(mirror.data?.projects.first?.tabs.map(\.id) == ["t1"])

        mirror.apply(batch(3, [
            .projectRemoved(.init(id: "w1")),
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
        mirror.apply(batch(2, [.projectChanged(.init(project: info("p1", "Old")))]))
        mirror.apply(batch(3, [.projectChanged(.init(project: info("p1", "Two")))]))
        #expect(mirror.data == nil)

        mirror.install(state(seq: 2, model: .init(projects: [project])))
        #expect(mirror.data?.projects == [renamed])
        #expect(mirror.seq == 3)

        mirror.apply(batch(3, [.projectChanged(.init(project: info("p1", "One")))]))
        #expect(mirror.data?.projects == [renamed])

        mirror.reset()
        #expect(mirror.data == nil)
        #expect(mirror.epoch == nil)
    }

    @Test
    func a_server_with_no_model_gives_no_data() {
        let mirror = ModelMirror()
        mirror.install(state(seq: 0, model: nil))
        mirror.apply(batch(1, [.projectChanged(.init(project: info("p1", "One")))]))
        #expect(mirror.data == nil)
    }
}
