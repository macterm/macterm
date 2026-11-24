import Foundation

/// The model of design/010 §1 and §11, made from the app's projects and the
/// snapshot of its workspaces (the shape of `workspaces_v3.json`). The
/// shadow stage sends it in `model.replace` (§9, step 3); the import of the
/// cut-over (§8) uses it for the v1 files.
///
/// The model has one type, the project: the pinned and the scratch
/// workspaces become hidden projects (`hiddenProject`). The quick
/// terminal's and the widgets' tabs are not in it: they are not in
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

    /// The model. Each project holds the tabs of its workspace. A project
    /// with no workspace (a group, which has no folder) has no tabs. A workspace of kind `project` with no project
    /// is not in the model: the model has no place for its tabs. A
    /// selection that names no project of the model is not sent.
    static func model(projects: [Project], workspaces: [WorkspaceInput], activeProjectID: UUID?) -> MactermProtocol.ModelData {
        let spaces = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = projects.map { project($0, workspace: spaces[$0.id]) }
        let known = Set(projects.map(\.id))
        for w in workspaces where !known.contains(w.id) {
            if let hidden = hiddenProject(w) { out.append(hidden) }
        }
        let selected = activeProjectID.map(id).flatMap { selection in
            out.contains { $0.id == selection } ? selection : nil
        }
        return .init(projects: out, selection: .init(activeProject: selected))
    }

    static func project(_ p: Project, workspace: WorkspaceInput? = nil) -> MactermProtocol.Project {
        .init(
            id: id(p.id),
            name: p.name,
            path: p.path,
            color: p.colorName,
            sortOrder: Int64(p.sortOrder),
            createdAt: Int64((p.createdAt.timeIntervalSince1970 * 1000).rounded()),
            parent: p.parent.map(id),
            tabs: workspace?.tabs.map(tab) ?? [],
            activeTab: workspace?.activeTabID.map(id)
        )
    }

    /// The hidden project of a workspace that is not a project's, with the
    /// capability fields of design/010 §11, §2. The server's reader of a
    /// version 1 `model.json` makes the same fields (`fromVersion1`). Nil
    /// for a workspace of kind `project`.
    static func hiddenProject(_ w: WorkspaceInput) -> MactermProtocol.Project? {
        var p: MactermProtocol.Project
        switch w.kind {
        case .project: return nil
        case .pinned: p = .init(id: id(w.id), name: "Pinned", path: "", sidebar: .top, removable: false, alias: "pinned")
        case .scratch: p = .init(id: id(w.id), name: "Scratch Tabs", path: "", sidebar: .bottom, removable: false, alias: "scratch")
        case .quick: p = .init(
                id: id(w.id),
                name: "Quick Terminal",
                path: "",
                sidebar: .none,
                singleTab: true,
                removable: false,
                alias: "quick"
            )
        case .widget: p = .init(id: id(w.id), name: "Widget", path: "", sidebar: .none, singleTab: true)
        }
        p.tabs = w.tabs.map(tab)
        p.activeTab = w.activeTabID.map(id)
        return p
    }

    static func tab(_ t: TabSnapshot) -> MactermProtocol.Tab {
        .init(id: id(t.id), customTitle: t.customTitle, root: node(t.splitRoot), focused: t.focusedPaneID.map(id))
    }

    static func node(_ n: SplitNodeSnapshot) -> MactermProtocol.SplitNode {
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

    static func id(_ uuid: UUID) -> String {
        uuid.uuidString
    }

    // MARK: - Compare

    /// Where `mirror` and `sent` differ, as paths into the model, at most
    /// `limit` of them. Empty when they agree. The order of projects is not
    /// compared: the server keeps its own, and each project's `sort_order`
    /// carries the order of the sidebar.
    static func differences(mirror: MactermProtocol.ModelData, sent: MactermProtocol.ModelData, limit: Int = 5) -> [String] {
        var found: [String] = []
        func note(_ path: String) {
            if found.count < limit { found.append(path) }
        }
        if mirror.selection != sent.selection { note("selection") }
        let mirrorProjects = Dictionary(mirror.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for p in sent.projects {
            guard var m = mirrorProjects[p.id] else {
                note("projects[\(p.id)]: missing")
                continue
            }
            if m.activeTab != p.activeTab { note("projects[\(p.id)].active_tab") }
            if m.tabs.map(\.id) != p.tabs.map(\.id) { note("projects[\(p.id)].tabs: order") }
            for t in p.tabs where m.tabs.first(where: { $0.id == t.id }).map({ $0 != t }) == true {
                note("projects[\(p.id)].tabs[\(t.id)]")
            }
            // The fields apart from the tabs.
            m.tabs = p.tabs
            m.activeTab = p.activeTab
            if m != p { note("projects[\(p.id)]") }
        }
        for p in mirror.projects where !sent.projects.contains(where: { $0.id == p.id }) {
            note("projects[\(p.id)]: not sent")
        }
        return found
    }
}
