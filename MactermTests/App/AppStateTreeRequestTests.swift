import Foundation
@testable import Macterm
import Testing

/// The verbs of `AppState` that change a tree, on a real model: each one is
/// one request of the server, and the mirror shows the server's tree.
@MainActor
struct AppStateTreeRequestTests {
    private func leaves(_ node: SplitNode) -> [UUID] {
        node.allPanes().map(\.id)
    }

    @Test
    func move_pane_swaps_the_focused_pane_with_its_neighbor_and_keeps_the_shape() throws {
        let state = TestModel.appState()
        let project = TestModel.project(state)
        let tab = try #require(state.model.activeTab(of: project.id))
        let left = try #require(tab.focusedPaneID)
        let right = try #require(state.splitPane(left, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"))
        state.focusPane(left, projectID: project.id)

        #expect(state.canMoveFocusedPane(.right, projectID: project.id))
        state.moveFocusedPane(.right, projectID: project.id)

        #expect(leaves(tab.splitRoot) == [right, left])
        #expect(tab.focusedPaneID == left, "the focus moves with its pane")
        #expect(!state.canMoveFocusedPane(.right, projectID: project.id))
    }

    @Test
    func a_pane_with_no_size_splits_side_by_side() throws {
        let state = TestModel.appState()
        let project = TestModel.project(state)
        let tab = try #require(state.model.activeTab(of: project.id))
        let source = try #require(tab.focusedPaneID)

        state.autoSplitPane(projectID: project.id, projects: [project])

        guard case let .split(branch) = tab.splitRoot else {
            Issue.record("no split")
            return
        }
        #expect(branch.direction == .horizontal)
        #expect(leaves(tab.splitRoot).first == source)
        #expect(tab.focusedPaneID != source, "the new pane has the focus")
    }

    @Test
    func zoom_toggles_on_the_focused_pane() throws {
        let state = TestModel.appState()
        let project = TestModel.project(state)
        let tab = try #require(state.model.activeTab(of: project.id))
        let source = try #require(tab.focusedPaneID)
        _ = try #require(state.splitPane(source, direction: .vertical, projectID: project.id, projectDirectory: "/tmp"))
        let focused = try #require(tab.focusedPaneID)

        state.toggleZoom(projectID: project.id)
        #expect(tab.zoomedPaneID == focused)
        state.toggleZoom(projectID: project.id)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func a_grid_is_one_change_in_the_order_of_the_cells() throws {
        let state = TestModel.appState()
        let project = TestModel.project(state)
        let tab = try #require(state.model.activeTab(of: project.id))
        let source = try #require(tab.focusedPaneID)

        let created = state.makeGrid(source, rows: 2, columns: 3, projectID: project.id, projectDirectory: "/tmp")

        #expect(created.count == 5)
        // The column of row heads first, then each row left to right.
        #expect(leaves(tab.splitRoot) == [source, created[1], created[2], created[0], created[3], created[4]])
        #expect(tab.focusedPaneID == source)
        // Every cell is even: a row of three gives the first cell a third.
        guard case let .split(rows) = tab.splitRoot, case let .split(top) = rows.first else {
            Issue.record("no grid")
            return
        }
        #expect(abs(rows.ratio - 0.5) < 0.001)
        #expect(abs(top.ratio - 1.0 / 3.0) < 0.001)
    }

    @Test
    func a_degenerate_grid_changes_nothing() throws {
        let state = TestModel.appState()
        let project = TestModel.project(state)
        let tab = try #require(state.model.activeTab(of: project.id))
        let source = try #require(tab.focusedPaneID)

        #expect(state.makeGrid(source, rows: 1, columns: 1, projectID: project.id, projectDirectory: "/tmp").isEmpty)
        #expect(leaves(tab.splitRoot) == [source])
    }

    @Test
    func the_palette_lists_no_hidden_project() throws {
        let state = TestModel.appState()
        let store = TestModel.projectStore(state)
        let project = try #require(store.create(name: "alpha", path: "/tmp"))
        _ = state.ensurePinnedProject()
        _ = state.ensureScratchProject()
        _ = state.quickTerminal.ensureTab()
        state.createDesktopWidget()
        #expect(state.model.projects.count == 5)

        let context = PaletteContext(appState: state, projectStore: store)
        for query in ["", "Pinned", "Scratch", "Quick", "Widget"] {
            let ids = ProjectSource().items(query: query, context: context).map(\.id)
            #expect(ids.allSatisfy { $0.contains(project.id.uuidString) }, "query \(query)")
        }
    }
}
