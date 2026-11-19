import Foundation

/// The model of design/010 §1, made from the app's projects and the snapshot
/// of its workspaces (the shape of `workspaces_v3.json`). The shadow stage
/// sends it in `model.replace` (§9, step 3); the import of the cut-over (§8)
/// uses it for the v1 files.
///
/// The quick terminal's and the widgets' tabs are not in it: they are not in
/// `AppState.workspaces` until the cut-over (design/010 Decisions,
/// 2026-11-15).
enum ModelConversion {
    /// One workspace of the app, with its tabs as snapshots.
    struct WorkspaceInput {
        var id: UUID
        var kind: WorkspaceKind
        var tabs: [TabSnapshot]
        var activeTabID: UUID?
    }

    /// The model. A project with no workspace (the app makes it when a
    /// window selects the project) gets an empty one, because the model
    /// gives every project a workspace.
    static func model(projects: [Project], workspaces: [WorkspaceInput], activeProjectID: UUID?) -> MactermProtocol.ModelData {
        var spaces = workspaces.map(workspace)
        let present = Set(workspaces.map(\.id))
        for project in projects where !project.isGroup && !present.contains(project.id) {
            spaces.append(.init(id: id(project.id), kind: .project))
        }
        return .init(
            projects: projects.map(project),
            workspaces: spaces,
            selection: .init(activeProject: activeProjectID.map(id))
        )
    }

    static func project(_ p: Project) -> MactermProtocol.Project {
        .init(
            id: id(p.id),
            name: p.name,
            path: p.isGroup ? "" : p.path,
            color: p.colorName,
            sortOrder: Int64(p.sortOrder),
            createdAt: Int64((p.createdAt.timeIntervalSince1970 * 1000).rounded()),
            parent: p.parent.map(id),
            kind: p.isGroup ? .group : .project
        )
    }

    static func workspace(_ w: WorkspaceInput) -> MactermProtocol.Workspace {
        .init(id: id(w.id), kind: kind(w.kind), tabs: w.tabs.map(tab), activeTab: w.activeTabID.map(id))
    }

    static func tab(_ t: TabSnapshot) -> MactermProtocol.Tab {
        .init(id: id(t.id), customTitle: t.customTitle, root: node(t.splitRoot), focused: t.focusedPaneID.map(id))
    }

    static func node(_ n: SplitNodeSnapshot) -> MactermProtocol.Node {
        switch n {
        case let .pane(p): .pane(pane(p))
        case let .split(b):
            .split(.init(
                // An older file has no branch id. The app gives the branch
                // one at the restore, and its snapshots carry it.
                id: id(b.id ?? UUID()),
                dir: b.direction == .horizontal ? .horizontal : .vertical,
                ratio: b.ratio,
                first: node(b.first),
                second: node(b.second)
            ))
        }
    }

    /// A pane's id is its session id (design/004). The session name stays
    /// as it was saved.
    static func pane(_ p: PaneSnapshot) -> MactermProtocol.Pane {
        let host: String? = switch ProjectPath.parse(p.projectPath) {
        case let .remote(user, host, _): user.map { "\($0)@\(host)" } ?? host
        default: nil
        }
        // The session keeps a pane's attention flags (`Pane.attention`), so
        // the model's `attention` stays `none`.
        return .init(
            id: id(p.sessionID ?? p.id),
            session: p.sessionName ?? "",
            host: host,
            slug: p.sessionName.flatMap(ZmxSessionName.slug(fromName:)) ?? "",
            originPath: p.projectPath,
            cwd: p.workingDirectory,
            hostSessionDir: p.hostSessionDirectory
        )
    }

    static func kind(_ k: WorkspaceKind) -> MactermProtocol.Kind {
        switch k {
        case .project: .project
        case .pinned: .pinned
        case .scratch: .scratch
        case .quick: .quick
        case .widget: .widget
        }
    }

    static func id(_ uuid: UUID) -> String {
        uuid.uuidString
    }

    // MARK: - Compare

    /// Where `mirror` and `sent` differ, as paths into the model, at most
    /// `limit` of them. Empty when they agree. The order of projects and of
    /// workspaces is not compared: the server keeps its own, and each
    /// project's `sort_order` carries the order of the sidebar.
    static func differences(mirror: MactermProtocol.ModelData, sent: MactermProtocol.ModelData, limit: Int = 5) -> [String] {
        var found: [String] = []
        func note(_ path: String) {
            if found.count < limit { found.append(path) }
        }
        if mirror.selection != sent.selection { note("selection") }
        let mirrorProjects = Dictionary(mirror.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for p in sent.projects where mirrorProjects[p.id] != p {
            note("projects[\(p.id)]")
        }
        for p in mirror.projects where !sent.projects.contains(where: { $0.id == p.id }) {
            note("projects[\(p.id)]: not sent")
        }
        let mirrorSpaces = Dictionary(mirror.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for w in sent.workspaces {
            guard let m = mirrorSpaces[w.id] else {
                note("workspaces[\(w.id)]: missing")
                continue
            }
            if m.kind != w.kind { note("workspaces[\(w.id)].kind") }
            if m.activeTab != w.activeTab { note("workspaces[\(w.id)].active_tab") }
            if m.tabs.map(\.id) != w.tabs.map(\.id) { note("workspaces[\(w.id)].tabs: order") }
            for t in w.tabs where m.tabs.first(where: { $0.id == t.id }).map({ $0 != t }) == true {
                note("workspaces[\(w.id)].tabs[\(t.id)]")
            }
        }
        for w in mirror.workspaces where !sent.workspaces.contains(where: { $0.id == w.id }) {
            note("workspaces[\(w.id)]: not sent")
        }
        return found
    }
}
