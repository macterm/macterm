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

    // MARK: - The projection

    private func split(_ id: String, _ first: MactermProtocol.SplitNode, _ second: MactermProtocol.SplitNode, ratio: Double = 0.5)
        -> MactermProtocol.SplitNode
    {
        .split(.init(id: id, dir: .horizontal, ratio: ratio, first: first, second: second))
    }

    @Test
    func a_pane_a_tab_and_a_branch_keep_their_objects_across_a_batch() throws {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [.init(id: "t1", root: split("s1", pane("a"), pane("b")), focused: "a")]
        p.activeTab = "t1"
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        let tab = try #require(mirror.tab(mirror.uuid("t1")))
        let a = try #require(mirror.pane(mirror.uuid("a")))
        guard case let .split(branch) = tab.splitRoot else {
            Issue.record("expected a split")
            return
        }

        // A ratio change keeps the branch; a new pane keeps the old ones.
        mirror.apply(batch(2, [.tabChanged(.init(
            project: "p1",
            tab: .init(id: "t1", root: split("s1", pane("a"), pane("b"), ratio: 0.3), focused: "b")
        ))]))
        #expect(mirror.tab(mirror.uuid("t1")) === tab)
        #expect(mirror.pane(mirror.uuid("a")) === a)
        guard case let .split(same) = tab.splitRoot else {
            Issue.record("expected a split")
            return
        }
        #expect(same === branch)
        #expect(abs(same.ratio - 0.3) < 0.0001)
        #expect(tab.focusedPaneID == mirror.uuid("b"))

        mirror.apply(batch(3, [.tabChanged(.init(
            project: "p1",
            tab: .init(id: "t1", root: split("s1", pane("a"), split("s2", pane("b"), pane("c"))), focused: "c")
        ))]))
        #expect(mirror.pane(mirror.uuid("a")) === a)
        #expect(tab.splitRoot.allPanes().map(\.id) == ["a", "b", "c"].map(mirror.uuid))
        #expect(tab.splitRoot.findPane(id: mirror.uuid("a")) === a)
    }

    @Test
    func a_pane_that_the_app_registered_is_the_object_of_the_model() {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a")]
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        let made = Pane(projectPath: "/a", projectID: mirror.uuid("p1"), start: .typed("htop"))
        mirror.register(made)
        mirror.apply(batch(2, [.tabChanged(.init(
            project: "p1",
            tab: .init(id: "t1", root: split("s1", pane("a"), .pane(.init(id: made.id.uuidString, session: made.sessionName))))
        ))]))
        #expect(mirror.pane(made.id) === made)
        #expect(mirror.pane(made.id)?.start == .typed("htop"))
    }

    @Test
    func a_pane_that_leaves_the_model_goes_to_onPanesRemoved() throws {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a"), tab("t2", "b")]
        p.activeTab = "t1"
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        let b = try #require(mirror.pane(mirror.uuid("b")))
        var gone: [Pane] = []
        var records: [MactermProtocol.PaneRemoved] = []
        mirror.onPanesRemoved = { panes, removed in
            gone += panes
            records += removed
        }

        mirror.apply(batch(2, [
            .tabOrder(.init(project: "p1", ids: ["t1"], activeTab: "t1")),
            .tabRemoved(.init(project: "p1", id: "t2")),
            .paneRemoved(.init(id: "b", session: "macterm-x-b")),
        ]))

        #expect(gone.count == 1)
        #expect(gone.first === b)
        #expect(records.map(\.id) == ["b"])
        #expect(mirror.pane(mirror.uuid("b")) == nil)
        #expect(mirror.tab(mirror.uuid("t2")) == nil)
        #expect(mirror.pane(mirror.uuid("a")) != nil)

        // A batch where no pane goes calls nothing.
        gone = []
        mirror.apply(batch(3, [.projectChanged(.init(project: info("p1", "Renamed")))]))
        #expect(gone.isEmpty)
    }

    @Test
    func the_panes_of_a_moved_tab_are_rebound_to_the_new_project() throws {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [.init(id: "t1", root: split("s1", pane("a"), pane("b")), focused: "a")]
        p.activeTab = "t1"
        let other = MactermProtocol.Project(id: "p2", name: "Two", path: "/b")
        mirror.install(state(seq: 1, model: .init(projects: [p, other])))
        let tab = try #require(mirror.tab(mirror.uuid("t1")))
        let a = try #require(mirror.pane(mirror.uuid("a")))
        #expect(a.projectID == mirror.uuid("p1"))

        mirror.apply(batch(2, [
            .tabOrder(.init(project: "p2", ids: ["t1"], activeTab: "t1")),
            .tabOrder(.init(project: "p1", ids: [])),
            .tabChanged(.init(project: "p2", tab: .init(id: "t1", root: split("s1", pane("a"), pane("b")), focused: "a"))),
        ]))

        #expect(mirror.tab(mirror.uuid("t1")) === tab, "the tab keeps its object")
        #expect(mirror.projectID(ofTab: tab.id) == mirror.uuid("p2"))
        #expect(mirror.pane(mirror.uuid("a")) === a)
        #expect(tab.splitRoot.allPanes().allSatisfy { $0.projectID == mirror.uuid("p2") })
        #expect(mirror.tabs(of: mirror.uuid("p1")).isEmpty)
        #expect(mirror.activeTabID(of: mirror.uuid("p1")) == nil)
        #expect(mirror.locate(pane: a.id)?.projectID == mirror.uuid("p2"))
    }

    @Test
    func the_reads_find_projects_by_alias_and_the_tree_projects_leave_out_hidden_ones() {
        let mirror = ModelMirror()
        let pinned = MactermProtocol.Project(id: "pin", name: "Pinned", path: "", sidebar: .top, removable: false, alias: "pinned")
        let widget = MactermProtocol.Project(id: "w1", name: "Widget", path: "", sidebar: .none, singleTab: true)
        mirror.install(state(seq: 1, model: .init(projects: [pinned, project, widget])))
        #expect(mirror.projects.count == 3)
        #expect(mirror.project(alias: "pinned")?.id == mirror.uuid("pin"))
        #expect(mirror.project(alias: "scratch") == nil)
        #expect(mirror.treeProjects.map(\.id) == [mirror.uuid("p1")])
    }

    // MARK: - Tab history

    private func select(_ mirror: ModelMirror, _ seq: UInt64, _ active: String, of ids: [String] = ["t1", "t2", "t3"]) {
        mirror.apply(batch(seq, [.tabOrder(.init(project: "p1", ids: ids, activeTab: active))]))
    }

    private func threeTabs() -> ModelMirror {
        let mirror = ModelMirror()
        var p = project
        p.tabs = [tab("t1", "a"), tab("t2", "b"), tab("t3", "c")]
        p.activeTab = "t1"
        mirror.install(state(seq: 1, model: .init(projects: [p])))
        return mirror
    }

    @Test
    func recencyOrder_is_the_active_tab_then_history_then_unvisited_tabs() {
        let mirror = threeTabs()
        let p1 = mirror.uuid("p1")
        #expect(mirror.recencyOrder(of: p1) == ["t1", "t2", "t3"].map(mirror.uuid), "no history: the tab order")
        select(mirror, 2, "t3")
        select(mirror, 3, "t2")
        #expect(mirror.recencyOrder(of: p1) == ["t2", "t3", "t1"].map(mirror.uuid))
        select(mirror, 4, "t1")
        #expect(mirror.recencyOrder(of: p1) == ["t1", "t2", "t3"].map(mirror.uuid))
        #expect(mirror.recencyOrder(of: UUID()).isEmpty)
    }

    @Test
    func a_tab_that_closed_leaves_the_recency_order() {
        let mirror = threeTabs()
        select(mirror, 2, "t2")
        select(mirror, 3, "t3")
        mirror.apply(batch(4, [
            .tabOrder(.init(project: "p1", ids: ["t1", "t3"], activeTab: "t3")),
            .tabRemoved(.init(project: "p1", id: "t2")),
        ]))
        #expect(mirror.recencyOrder(of: mirror.uuid("p1")) == ["t3", "t1"].map(mirror.uuid))
    }

    @Test
    func a_peek_records_no_history() {
        let mirror = threeTabs()
        select(mirror, 2, "t2")
        mirror.peeking = true
        select(mirror, 3, "t3")
        mirror.peeking = false
        // t2 was active before the peek, and the peek did not push it.
        #expect(mirror.recencyOrder(of: mirror.uuid("p1")) == ["t3", "t1", "t2"].map(mirror.uuid))
    }

    @Test
    func a_change_of_the_active_tab_calls_onActiveTabChanged() {
        let mirror = threeTabs()
        var changed: [UUID] = []
        mirror.onActiveTabChanged = { changed.append($0) }
        select(mirror, 2, "t2")
        #expect(changed == [mirror.uuid("p1")])
        mirror.apply(batch(3, [.projectChanged(.init(project: info("p1", "Renamed")))]))
        #expect(changed.count == 1, "a batch that keeps the active tab calls nothing")
    }
}

/// The requests of the tab verbs, through a real server: the mirror has the
/// change when the request returns.
@MainActor
struct ModelMirrorRequestTests {
    private func setup() -> (AppState, UUID, UUID) {
        let state = TestModel.appState()
        let project = TestModel.project(state, name: "p", path: "/tmp")
        let first = state.model.activeTabID(of: project.id)!
        return (state, project.id, first)
    }

    @Test
    func a_new_tab_is_appended_and_selected() throws {
        let (state, projectID, first) = setup()
        let new = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        #expect(state.model.tabs(of: projectID).map(\.id) == [first, new])
        #expect(state.model.activeTabID(of: projectID) == new)
        #expect(state.model.recencyOrder(of: projectID) == [new, first])
    }

    @Test
    func a_tab_made_without_focus_is_not_visited() throws {
        let (state, projectID, first) = setup()
        let current = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        let recency = state.model.recencyOrder(of: projectID)
        let background = try #require(state.createTab(projectID: projectID, projectPath: "/tmp", focus: false))
        #expect(state.model.activeTabID(of: projectID) == current)
        #expect(state.model.recencyOrder(of: projectID) == recency + [background])
        _ = first
    }

    @Test
    func a_tab_made_without_focus_in_a_project_with_no_tab_becomes_active() throws {
        let (state, projectID, first) = setup()
        #expect(state.writer.tabClose(first))
        #expect(state.model.tabs(of: projectID).isEmpty)
        #expect(state.model.activeTabID(of: projectID) == nil)
        let background = try #require(state.createTab(projectID: projectID, projectPath: "/tmp", focus: false))
        #expect(state.model.activeTabID(of: projectID) == background)
        #expect(state.model.recencyOrder(of: projectID) == [background])
    }

    @Test
    func a_close_of_an_unknown_tab_changes_nothing() {
        let (state, projectID, first) = setup()
        #expect(!state.writer.tabClose(UUID()))
        #expect(state.model.tabs(of: projectID).map(\.id) == [first])
    }

    @Test
    func a_close_of_a_tab_that_is_not_active_keeps_the_active_tab() throws {
        let (state, projectID, first) = setup()
        let second = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        #expect(state.writer.tabClose(first))
        #expect(state.model.activeTabID(of: projectID) == second)
    }

    @Test
    func a_select_marks_only_the_selected_tab_seen() throws {
        let (state, projectID, first) = setup()
        let other = try #require(state.createTab(projectID: projectID, projectPath: "/tmp").flatMap { state.model.tab($0) })
        let selected = try #require(state.model.tab(first))
        let unseen = MactermProtocol.Attention(unseen: true)
        selected.splitRoot.allPanes().first?.receiveAttention(unseen)
        other.splitRoot.allPanes().first?.receiveAttention(unseen)
        state.writer.tabSelect(first, in: projectID)
        #expect(state.model.activeTabID(of: projectID) == first)
        #expect(selected.executionState == .idle)
        #expect(other.executionState == .done)
    }

    @Test
    func a_select_of_an_unknown_tab_changes_nothing() {
        let (state, projectID, first) = setup()
        state.writer.tabSelect(UUID(), in: projectID)
        #expect(state.model.activeTabID(of: projectID) == first)
    }

    @Test
    func a_peek_selects_and_records_no_history() throws {
        let (state, projectID, first) = setup()
        let second = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        let third = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        state.writer.tabPeek(first, in: projectID)
        #expect(state.model.activeTabID(of: projectID) == first)
        // third was active before the peek: the peek did not push it.
        #expect(state.model.recencyOrder(of: projectID) == [first, second, third])
    }

    @Test
    func a_reorder_moves_the_tab_to_its_final_index() throws {
        let (state, projectID, t1) = setup()
        let t2 = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        let t3 = try #require(state.createTab(projectID: projectID, projectPath: "/tmp"))
        state.writer.tabReorder(t1, in: projectID, toIndex: 2)
        #expect(state.model.tabs(of: projectID).map(\.id) == [t2, t3, t1])
        state.writer.tabReorder(t1, in: projectID, toIndex: 0)
        #expect(state.model.tabs(of: projectID).map(\.id) == [t1, t2, t3])
        state.writer.tabReorder(UUID(), in: projectID, toIndex: 0)
        #expect(state.model.tabs(of: projectID).map(\.id) == [t1, t2, t3])
    }

    @Test
    func a_rename_sets_and_clears_the_custom_title() throws {
        let (state, _, first) = setup()
        let tab = try #require(state.model.tab(first))
        let auto = tab.autoTitle
        state.writer.tabSet(first, title: "My Tab")
        #expect(tab.sidebarTitle == "My Tab")
        state.writer.tabSet(first, title: nil)
        #expect(tab.customTitle == nil)
        #expect(tab.sidebarTitle == auto)
    }
}
