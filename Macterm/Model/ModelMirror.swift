import Foundation
import Observation

/// The GUI's copy of the model on the Mac server (design/010 §4): the state
/// of `state.subscribe`, then each event batch, applied in one main-actor
/// turn. Nothing reads it yet: in the shadow stage (§9, step 3) `ModelShadow`
/// fills the server from `AppState` and compares this copy with what it
/// sent. The cut-over (step 6) makes the views read it.
@MainActor @Observable
final class ModelMirror {
    /// Nil until `install`, and on a server with no model.
    private(set) var data: MactermProtocol.ModelData?
    /// The zoomed pane of each tab that has one, by tab id. The server keeps
    /// zoom in memory only, so it is not in `data`.
    private(set) var zoomed: [String: String] = [:]
    /// The batch that `data` includes last. A batch with a `seq` that is not
    /// higher is in `data` already.
    private(set) var seq: UInt64 = 0
    private(set) var epoch: UInt64?
    /// Batches that came before `install`, in order.
    private var early: [ServerEventBatch] = []

    /// Forgets the state: a new connection, which can be a new server.
    func reset() {
        data = nil
        zoomed = [:]
        seq = 0
        epoch = nil
        early = []
    }

    /// Takes the state of `state.subscribe`, then the batches that came
    /// after it and before it was installed.
    func install(_ state: MactermProtocol.StateSubscribe.Result) {
        epoch = state.epoch
        seq = state.seq
        data = state.model
        zoomed = Dictionary(state.zoomed.map { ($0.tab, $0.pane) }, uniquingKeysWith: { _, last in last })
        let waiting = early
        early = []
        for batch in waiting {
            apply(batch)
        }
    }

    /// Applies one batch. A batch from before the installed state is
    /// skipped.
    func apply(_ batch: ServerEventBatch) {
        guard epoch != nil else {
            early.append(batch)
            return
        }
        guard batch.seq > seq else { return }
        seq = batch.seq
        guard var model = data else { return }
        // The server sends what was made or changed first (`tab.order`
        // before the `tab.set` of a new tab), so the order of tabs is set at
        // the end of the batch.
        var orders: [String: [String]] = [:]
        for case let .model(event) in batch.events {
            switch event {
            case let .projectChanged(e):
                if let i = model.projects.firstIndex(where: { $0.id == e.project.id }) {
                    model.projects[i] = Self.project(e.project, tabs: model.projects[i].tabs, activeTab: model.projects[i].activeTab)
                } else {
                    model.projects.append(Self.project(e.project, tabs: [], activeTab: nil))
                }
            case let .projectRemoved(e):
                model.projects.removeAll { $0.id == e.id }
            case let .tabOrder(e):
                guard let i = model.projects.firstIndex(where: { $0.id == e.project }) else { continue }
                model.projects[i].activeTab = e.activeTab
                orders[e.project] = e.ids
            case let .tabChanged(e):
                for p in model.projects.indices where model.projects[p].id != e.project {
                    model.projects[p].tabs.removeAll { $0.id == e.tab.id }
                }
                guard let i = model.projects.firstIndex(where: { $0.id == e.project }) else { continue }
                if let t = model.projects[i].tabs.firstIndex(where: { $0.id == e.tab.id }) {
                    model.projects[i].tabs[t] = e.tab
                } else {
                    model.projects[i].tabs.append(e.tab)
                }
                zoomed[e.tab.id] = e.zoomed
            case let .tabRemoved(e):
                if let i = model.projects.firstIndex(where: { $0.id == e.project }) {
                    model.projects[i].tabs.removeAll { $0.id == e.id }
                }
                zoomed[e.id] = nil
            case let .selectionChanged(e):
                model.selection = .init(activeProject: e.activeProject)
            default:
                // `project.order`: each project's `sort_order` has the
                // order. `pane.removed`: the pane's tab event has it.
                break
            }
        }
        for (id, ids) in orders {
            guard let i = model.projects.firstIndex(where: { $0.id == id }) else { continue }
            let tabs = Dictionary(model.projects[i].tabs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            model.projects[i].tabs = ids.compactMap { tabs[$0] }
        }
        data = model
    }

    /// A project with the fields of `project.set` and the tabs that the
    /// mirror has: `tab.order` and `tab.set` carry those.
    private static func project(_ info: MactermProtocol.ProjectInfo, tabs: [MactermProtocol.Tab], activeTab: String?) -> MactermProtocol
        .Project
    {
        .init(
            id: info.id,
            name: info.name,
            path: info.path,
            color: info.color,
            sortOrder: info.sortOrder,
            createdAt: info.createdAt,
            parent: info.parent,
            sidebar: info.sidebar,
            singleTab: info.singleTab,
            removable: info.removable,
            alias: info.alias,
            tabs: tabs,
            activeTab: activeTab
        )
    }
}
