import Foundation

/// The model of design/010 §1 and §11, made from v1's files: the rows of
/// `projects.json` and the snapshots of `workspaces_v3.json`. The import of
/// the cut-over (§8) sends it in `model.import`, one time. It is migration
/// code: 0228 removes it with the rest of the v1 import.
///
/// The model has one type, the project: v1's pinned and scratch
/// workspaces, the quick terminal's tab and each widget's tab become hidden
/// projects (`hiddenProject`).
enum ModelConversion {
    /// v1's ids of its two sentinel workspaces, as `workspaces_v3.json`
    /// holds them. Only the import reads them: the model finds the pinned
    /// and the scratch project by its alias.
    enum V1 {
        static let pinnedID = UUID(uuid: (
            0xF1, 0xE0, 0xD0, 0xD0, 0x00, 0x00, 0x40, 0x00,
            0x80, 0x00, 0x4D, 0x61, 0x63, 0x50, 0x6E, 0x64
        ))
        static let scratchID = UUID(uuid: (
            0xF1, 0xE0, 0xD0, 0xD0, 0x00, 0x00, 0x40, 0x00,
            0x80, 0x00, 0x4D, 0x61, 0x63, 0x53, 0x63, 0x72
        ))
    }

    /// What a v1 workspace held tabs for.
    enum Kind {
        case project
        case pinned
        case scratch
        case quick
        case widget
    }

    /// One workspace of v1, with its tabs as snapshots.
    struct WorkspaceInput {
        var id: UUID
        var kind: Kind
        var tabs: [TabSnapshot]
        var activeTabID: UUID?
    }

    /// The model. Each project holds the tabs of its workspace. A workspace
    /// of kind `project` with no project is not in the model: the model has
    /// no place for its tabs. A selection that names no project of the model
    /// is not sent.
    static func model(projects: [Project], workspaces: [WorkspaceInput], activeProjectID: UUID?) -> MactermProtocol.ModelData {
        let spaces = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = projects.map { project($0, workspace: spaces[$0.id]) }
        let known = Set(projects.map(\.id))
        for w in workspaces where !known.contains(w.id) {
            if let hidden = hiddenProject(w) { out.append(hidden) }
        }
        let selected = activeProjectID.map(id).flatMap { selection in
            out.contains { $0.id == selection && $0.sidebar != .none } ? selection : nil
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
        case .pinned: p = PinnedTabs.newProject(id: id(w.id))
        case .scratch: p = ScratchTabs.newProject(id: id(w.id))
        case .quick: p = QuickTerminalService.newProject(id: id(w.id))
        case .widget: p = DesktopWidget.newProject(id: id(w.id))
        }
        p.tabs = w.tabs.map(tab)
        p.activeTab = w.activeTabID.map(id) ?? p.tabs.first?.id
        return p
    }

    static func tab(_ t: TabSnapshot) -> MactermProtocol.Tab {
        let root = node(t.splitRoot)
        // The saved focus names a pane by its v1 id: its session id when it
        // has one.
        let focus = t.focusedPaneID.flatMap { focused in paneID(of: focused, in: t.splitRoot) }
        return .init(id: id(t.id), customTitle: t.customTitle, root: root, focused: focus.map(id) ?? firstPane(root))
    }

    private static func paneID(of id: UUID, in node: SplitNodeSnapshot) -> UUID? {
        switch node {
        case let .pane(p): p.id == id || p.sessionID == id ? (p.sessionID ?? p.id) : nil
        case let .split(b): paneID(of: id, in: b.first) ?? paneID(of: id, in: b.second)
        }
    }

    private static func firstPane(_ node: MactermProtocol.SplitNode) -> String {
        switch node {
        case let .pane(p): p.id
        case let .split(s): firstPane(s.first)
        }
    }

    static func node(_ n: SplitNodeSnapshot) -> MactermProtocol.SplitNode {
        switch n {
        case let .pane(p): .pane(pane(p))
        case let .split(b):
            .split(.init(
                // An older file has no branch id.
                id: id(b.id ?? UUID()),
                dir: b.direction == .horizontal ? .horizontal : .vertical,
                ratio: b.ratio,
                first: node(b.first),
                second: node(b.second)
            ))
        }
    }

    /// A pane's id is its session id (design/004). The session name stays
    /// as it was saved. A pane with no session name (a snapshot from before
    /// persistence) gets a new session (design/008 Q3 A).
    static func pane(_ p: PaneSnapshot) -> MactermProtocol.Pane {
        let location = ProjectPath.parse(p.projectPath)
        let host: String? = switch location {
        case let .remote(user, host, _): user.map { "\($0)@\(host)" } ?? host
        default: nil
        }
        let paneID = p.sessionName == nil ? UUID() : (p.sessionID ?? p.id)
        let session = p.sessionName ?? ZmxSessionName.make(
            projectName: (p.projectPath as NSString).lastPathComponent,
            paneSessionID: paneID
        )
        // The session keeps a pane's attention flags (`Pane.attention`), so
        // the model's `attention` stays `none`.
        return .init(
            id: id(paneID),
            session: session,
            host: host,
            slug: ZmxSessionName.slug(fromName: session) ?? "",
            originPath: p.projectPath,
            cwd: host == nil ? p.workingDirectory : nil,
            hostSessionDir: host == nil ? nil : p.hostSessionDirectory
        )
    }

    /// A tab of one new pane in `path`, for a project of v1 that had no
    /// snapshot: a project with a folder has its first tab from the start.
    static func firstTab(path: String) -> TabSnapshot {
        let paneID = UUID()
        let pane = PaneSnapshot(
            id: paneID,
            projectPath: path,
            sessionID: paneID,
            sessionName: ZmxSessionName.make(projectName: (path as NSString).lastPathComponent, paneSessionID: paneID)
        )
        return TabSnapshot(id: UUID(), customTitle: nil, focusedPaneID: paneID, splitRoot: .pane(pane))
    }

    /// v1 names with a slash: each slash becomes a hyphen, one time, and a
    /// name that another project has then gets " 2" (issue 0524). A name
    /// with no slash stays.
    static func namesWithoutSlash(_ projects: [Project]) -> [Project] {
        var taken = Set(projects.filter { !Project.hasSlash($0.name) }.map(\.name))
        return projects.map { project in
            guard Project.hasSlash(project.name) else { return project }
            var copy = project
            var name = project.name.replacingOccurrences(of: "/", with: "-")
            if taken.contains(name) { name += " 2" }
            taken.insert(name)
            copy.name = name
            return copy
        }
    }

    static func id(_ uuid: UUID) -> String {
        uuid.uuidString
    }
}
