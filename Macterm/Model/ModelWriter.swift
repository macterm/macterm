import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ModelWriter")

/// The one way to change the model: each verb is a request of design/010 §3
/// to the Mac server. A verb returns after the mirror applied the request's
/// batch (`ModelConnection.send`), so the caller reads its own change.
///
/// The app makes every id (a tab, a pane, a split) and puts it in the
/// request. A new pane is a `Pane` object that the mirror takes when the
/// batch names it (`ModelMirror.register`), so it keeps its start command
/// and its environment.
///
/// A request that the server refuses changes nothing: the verb returns nil
/// or false, and `onError` shows the reason (a toast). Nothing is undone,
/// because nothing was predicted.
@MainActor
final class ModelWriter {
    let connection: ModelConnection
    /// Shows why a request failed. `AppState` sets it to a toast.
    var onError: (String) -> Void = { _ in }

    init(connection: ModelConnection) {
        self.connection = connection
    }

    var mirror: ModelMirror { connection.mirror }

    private func w(_ id: UUID) -> String {
        mirror.wire(id)
    }

    /// Sends one request. nil when it failed.
    @discardableResult
    private func send<M: ProtocolMethod>(
        _ method: M.Type,
        _ args: M.Args,
        registering panes: [Pane] = [],
        animated: Bool = false
    ) -> M.Result? {
        for pane in panes {
            mirror.register(pane)
        }
        do {
            return try connection.send(method, args, animated: animated)
        } catch let error as ModelRequestError {
            mirror.unregister(panes.map(\.id))
            switch error {
            case .unavailable:
                logger.error("\(M.name, privacy: .public): no server")
                onError(String(localized: "The session server is not available. Macterm tries again."))
            case let .refused(_, message):
                logger.error("\(M.name, privacy: .public) refused: \(message, privacy: .public)")
                onError(message)
            }
            return nil
        } catch {
            mirror.unregister(panes.map(\.id))
            logger.error("\(M.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Values

    /// The model's record of a pane that the app makes.
    func value(of pane: Pane) -> MactermProtocol.Pane {
        let host: String? = switch pane.remoteSpec {
        case let .remote(user, host, _)?: user.map { "\($0)@\(host)" } ?? host
        default: nil
        }
        return .init(
            id: w(pane.id),
            session: pane.sessionName,
            host: host,
            slug: pane.sessionSlug,
            originPath: pane.projectPath,
            cwd: nil,
            hostSessionDir: pane.hostSessionDirectory
        )
    }

    /// The model's tree of a tree that the app builds (a layout, a tab).
    /// Every pane of it is registered for the request.
    private func value(of node: SplitNode, panes: inout [Pane]) -> MactermProtocol.SplitNode {
        switch node {
        case let .pane(pane):
            panes.append(pane)
            return .pane(value(of: pane))
        case let .split(branch):
            return .split(.init(
                id: w(branch.id),
                dir: branch.direction == .vertical ? .vertical : .horizontal,
                ratio: Double(branch.ratio),
                first: value(of: branch.first, panes: &panes),
                second: value(of: branch.second, panes: &panes)
            ))
        }
    }

    private static func zone(_ zone: PaneDropZone) -> MactermProtocol.Zone {
        switch zone {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    // MARK: project.*

    /// `project.create`. The defaults make a project of the sidebar tree.
    @discardableResult
    func projectCreate(_ project: Project) -> Bool {
        send(MactermProtocol.ProjectCreate.self, .init(
            id: w(project.id),
            name: project.name,
            path: project.path,
            color: project.colorName,
            parent: project.parent.map(w),
            createdAt: Int64((project.createdAt.timeIntervalSince1970 * 1000).rounded()),
            sidebar: project.sidebar,
            singleTab: project.singleTab,
            removable: project.removable,
            alias: project.alias
        )) != nil
    }

    /// `project.set`. A nil field stays. `color: ""` removes the color, and
    /// `parent: .some(nil)` moves the project to the top level.
    @discardableResult
    func projectSet(_ id: UUID, name: String? = nil, path: String? = nil, color: String? = nil, parent: UUID?? = nil) -> Bool {
        let parentArg: String? = switch parent {
        case .none: nil
        case let .some(.some(p)): w(p)
        case .some(.none): ""
        }
        return send(MactermProtocol.ProjectSet.self, .init(id: w(id), name: name, path: path, color: color, parent: parentArg)) != nil
    }

    /// `project.reorder`: the order of the children of `parent`.
    func projectReorder(parent: UUID?, ids: [UUID]) {
        send(MactermProtocol.ProjectReorder.self, .init(parent: parent.map(w), ids: ids.map(w)))
    }

    /// `project.remove`. The server ends the local sessions of its panes.
    @discardableResult
    func projectRemove(_ id: UUID) -> Bool {
        send(MactermProtocol.ProjectRemove.self, .init(id: w(id))) != nil
    }

    // MARK: tab.*

    /// `tab.create` with one new pane, or with a tree that the app built.
    /// Returns the new tab.
    @discardableResult
    func tabCreate(
        in projectID: UUID,
        root: SplitNode,
        id: UUID = UUID(),
        index: Int? = nil,
        title: String? = nil,
        focus: Bool = true
    ) -> TerminalTab? {
        var panes: [Pane] = []
        let tree = value(of: root, panes: &panes)
        let args = MactermProtocol.TabCreate.Args(
            project: w(projectID),
            id: w(id),
            index: index.map { UInt32(max(0, $0)) },
            root: tree,
            title: title,
            focus: focus
        )
        guard send(MactermProtocol.TabCreate.self, args, registering: panes) != nil else { return nil }
        return mirror.tab(id)
    }

    /// `tab.close`. The server ends the local sessions of its panes.
    @discardableResult
    func tabClose(_ id: UUID) -> Bool {
        send(MactermProtocol.TabClose.self, .init(id: w(id))) != nil
    }

    /// `tab.set`: rename. nil goes back to the automatic title.
    func tabSet(_ id: UUID, title: String?) {
        send(MactermProtocol.TabSet.self, .init(id: w(id), title: title))
    }

    /// `tab.layout`: a new tree for a tab (Apply Layout). A pane of the old
    /// tree that the new one holds keeps its session.
    @discardableResult
    func tabLayout(_ id: UUID, root: SplitNode, focusedPaneID: UUID?) -> Bool {
        var panes: [Pane] = []
        let tree = value(of: root, panes: &panes)
        let fresh = panes.filter { mirror.pane($0.id) == nil }
        return send(
            MactermProtocol.TabLayout.self,
            .init(id: w(id), root: tree, focused: focusedPaneID.map(w)),
            registering: fresh
        ) != nil
    }

    /// `tab.select`. Looking at the tab marks its panes seen.
    func tabSelect(_ id: UUID, in projectID: UUID) {
        guard mirror.activeTabID(of: projectID) != id else {
            mirror.tab(id)?.markSeen()
            return
        }
        send(MactermProtocol.TabSelect.self, .init(project: w(projectID), id: w(id)))
        mirror.tab(id)?.markSeen()
    }

    /// The Ctrl+Tab cycle: the active tab changes, but the tab history of
    /// the app does not (`ModelMirror.peeking`).
    func tabPeek(_ id: UUID, in projectID: UUID) {
        guard mirror.activeTabID(of: projectID) != id else { return }
        mirror.peeking = true
        defer { mirror.peeking = false }
        send(MactermProtocol.TabSelect.self, .init(project: w(projectID), id: w(id)))
    }

    /// `tab.reorder` to the tab's final index.
    func tabReorder(_ id: UUID, in projectID: UUID, toIndex index: Int) {
        send(MactermProtocol.TabReorder.self, .init(project: w(projectID), id: w(id), index: UInt32(max(0, index))))
    }

    /// `tab.move`: to another project, where it becomes the active tab.
    @discardableResult
    func tabMove(_ id: UUID, to projectID: UUID, index: Int? = nil) -> Bool {
        send(MactermProtocol.TabMove.self, .init(id: w(id), toProject: w(projectID), index: index.map { UInt32(max(0, $0)) })) != nil
    }

    /// `tab.merge`: the tree of tab `source` goes into tab `destination` at
    /// `target`, and `source` closes. A divider or a root edge makes every
    /// ratio even, as v1 did.
    @discardableResult
    func tabMerge(_ source: UUID, into destination: UUID, at target: TabDropResolution.Target) -> Bool {
        let parts = DropParts(target)
        return send(MactermProtocol.TabMerge.self, .init(
            src: w(source),
            dst: w(destination),
            targetPane: parts.pane.map(w),
            zone: Self.zone(parts.zone),
            splitId: w(UUID()),
            rebalance: parts.rebalance
        )) != nil
    }

    /// The parts of a drop target as `tab.merge` takes them. A divider or a
    /// root edge makes every ratio even, as v1 did.
    private struct DropParts {
        let pane: UUID?
        let zone: PaneDropZone
        let rebalance: Bool?

        init(_ target: TabDropResolution.Target) {
            switch target {
            case let .pane(id, zone): (pane, self.zone, rebalance) = (id, zone, nil)
            case let .divider(id, zone): (pane, self.zone, rebalance) = (id, zone, true)
            case let .rootEdge(zone): (pane, self.zone, rebalance) = (nil, zone, true)
            }
        }
    }

    /// `tab.rebalance`: every ratio of the tab even.
    func tabRebalance(_ id: UUID) {
        send(MactermProtocol.TabRebalance.self, .init(id: w(id)))
    }

    // MARK: pane.*

    /// `pane.split`: `pane` goes next to `target`. Returns the new pane's
    /// id. With `focus: false`, the focus and the zoom stay.
    @discardableResult
    func paneSplit(
        tab: UUID,
        target: UUID,
        new pane: Pane,
        direction: SplitDirection,
        position: SplitPosition = .second,
        focus: Bool = true,
        rebalance: Bool? = nil
    ) -> UUID? {
        let args = MactermProtocol.PaneSplit.Args(
            tab: w(tab),
            target: w(target),
            new: value(of: pane),
            splitId: w(UUID()),
            dir: direction == .vertical ? .vertical : .horizontal,
            position: position == .first ? .first : .second,
            focus: focus,
            rebalance: rebalance
        )
        guard send(MactermProtocol.PaneSplit.self, args, registering: [pane]) != nil else { return nil }
        return pane.id
    }

    /// `pane.close`. The last pane closes the tab. The server ends the
    /// pane's local session.
    @discardableResult
    func paneClose(_ id: UUID) -> Bool {
        send(MactermProtocol.PaneClose.self, .init(id: w(id))) != nil
    }

    /// `pane.move`: next to pane `destination` on `zone`, in this tab or in
    /// another.
    @discardableResult
    func paneMove(_ id: UUID, nextTo destination: UUID, zone: PaneDropZone, rebalance: Bool? = nil) -> Bool {
        send(MactermProtocol.PaneMove.self, .init(
            id: w(id),
            dest: w(destination),
            zone: Self.zone(zone),
            splitId: w(UUID()),
            rebalance: rebalance
        )) != nil
    }

    /// A pane's move to a resolved drop target of its own tab (the grab
    /// handle). A root edge has no request of its own: the pane goes to a
    /// tab of its own, and that tab merges back at the edge.
    @discardableResult
    func paneMove(_ id: UUID, in tab: TerminalTab, projectID: UUID, to target: TabDropResolution.Target) -> Bool {
        switch target {
        case let .pane(dest, zone):
            guard dest != id else { return false }
            return paneMove(id, nextTo: dest, zone: zone)
        case let .divider(dest, zone):
            guard dest != id else { return false }
            return paneMove(id, nextTo: dest, zone: zone, rebalance: true)
        case .rootEdge:
            guard tab.splitRoot.allPanes().count > 1 else { return false }
            let parked = UUID()
            guard paneSeparate(id, newTab: parked, in: projectID) else { return false }
            return tabMerge(parked, into: tab.id, at: target)
        }
    }

    /// `pane.swap`: Move Pane.
    @discardableResult
    func paneSwap(_ id: UUID, with other: UUID) -> Bool {
        send(MactermProtocol.PaneSwap.self, .init(id: w(id), other: w(other))) != nil
    }

    /// `pane.separate`: the pane goes to a new tab `newTab`, in `projectID`
    /// (the pane's own when nil).
    @discardableResult
    func paneSeparate(_ id: UUID, newTab: UUID = UUID(), in projectID: UUID? = nil) -> Bool {
        send(MactermProtocol.PaneSeparate.self, .init(id: w(id), tabId: w(newTab), project: projectID.map(w))) != nil
    }

    /// `pane.focus`.
    func paneFocus(_ id: UUID) {
        guard mirror.locate(pane: id)?.tab.focusedPaneID != id else { return }
        send(MactermProtocol.PaneFocus.self, .init(id: w(id)))
    }

    /// `pane.zoom`: zoom `paneID`, or with nil end the zoom.
    func paneZoom(tab: UUID, pane paneID: UUID?) {
        send(MactermProtocol.PaneZoom.self, .init(tab: w(tab), pane: paneID.map(w)))
    }

    /// `pane.replace`: a new pane in the place of `id` (Restart Session).
    @discardableResult
    func paneReplace(_ id: UUID, with pane: Pane) -> Bool {
        send(MactermProtocol.PaneReplace.self, .init(id: w(id), new: value(of: pane)), registering: [pane]) != nil
    }

    /// `pane.set`: the folders where a new session of the pane starts.
    func paneSet(_ id: UUID, cwd: String? = nil, hostSessionDirectory: String? = nil) {
        send(MactermProtocol.PaneSet.self, .init(id: w(id), cwd: cwd, hostSessionDir: hostSessionDirectory))
    }

    // MARK: split.*

    /// `split.ratio`. With `animated`, the change animates (the keyboard
    /// resize).
    func splitRatio(_ branchID: UUID, ratio: CGFloat, animated: Bool = false) {
        send(MactermProtocol.SplitRatio.self, .init(id: w(branchID), ratio: Double(ratio)), animated: animated)
    }

    // MARK: select.*

    /// `select.set`: the key window's selection.
    func selectSet(project: UUID?, tab: UUID? = nil) {
        guard let project else { return }
        guard mirror.project(project)?.isSelectable == true else { return }
        send(MactermProtocol.SelectSet.self, .init(project: w(project), tab: tab.map(w)))
    }

    // MARK: model.*

    /// `model.options`: the default `rebalance` of a request.
    func modelOptions(autoTiling: Bool) {
        send(MactermProtocol.ModelOptions.self, .init(autoTiling: autoTiling))
    }

    /// `model.import`, one time (design/010 §8).
    @discardableResult
    func modelImport(_ model: MactermProtocol.ModelData, source: String) -> Bool {
        send(MactermProtocol.ModelImport.self, .init(model: model, source: source)) != nil
    }
}
