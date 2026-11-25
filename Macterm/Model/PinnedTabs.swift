import Foundation

/// The pinned tabs: a hidden project of the model (design/010 §11) with
/// `sidebar: top` (its tabs are rows above the tree), `removable: false` and
/// the alias `pinned`. The app makes it at the first pin, or at a launch that
/// has `pinned.yaml` entries. Code finds it by its alias, never by an id.
enum PinnedTabs {
    /// The alias of the pinned project: `--project pinned` resolves it.
    static let alias = "pinned"

    static let displayName = "Pinned"

    /// Whether `name` is this workspace's, which no project may carry:
    /// `ControlHandler.resolveProject` reads `pinned` as the pinned workspace
    /// before it looks at any project, so a project given the name could be
    /// reached by UUID or `project:N` but never by name. Case-insensitive like
    /// that lookup, and blind to surrounding whitespace: a padded name reads
    /// as the bare one in the sidebar and `project list`, and the bare one is
    /// what anyone would type to reach it.
    ///
    /// The one test every naming path applies. A name somebody typed is
    /// refused where they typed it (`project create --name`,
    /// `project rename`, the sidebar's rename, the New Project intent); a
    /// name nobody chose — the folder's own, which most
    /// creation paths default to — is suffixed instead (`ProjectStore.create`).
    static func reservesName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == displayName.lowercased()
    }

    /// Why a typed name was refused, as the app says it. The CLI words its
    /// `bad_request` the same (`ControlHandler.reservedNameError`).
    /// `displayName` stays as it is in every language, because it is the
    /// name that the user must not type.
    static let reservedNameMessage = String(
        localized: "“\(displayName)” is a reserved name for the pinned tabs. Select another name."
    )

    /// The reserved `path:` literal that marks `pinned.yaml` as the pinned
    /// set rather than a project declaration. The angle brackets make the
    /// sentinel VISIBLY impossible as a real path: they are illegal in
    /// hostnames (so no `host:dir` spec can ever start this way), a local
    /// path must start with `/` or `~`, and `<` is not a YAML indicator, so
    /// the value needs no quoting. `ProjectPath.parse` returns nil for it,
    /// so `ProjectPath.matches` can never pair it with a project's path.
    static let pathMarker = "<pinned>"

    /// Where a NEW pinned tab (Cmd+T while the pinned workspace is active, a
    /// declared cwd-less leaf) starts: the user's home. Pinned tabs carry no
    /// project directory; each pane's own `projectPath` is its cwd.
    /// `$HOME`-env-first so the benchmark harness's throwaway home isolates it.
    static var fallbackRoot: String { ProjectPath.currentHome }

    /// The request of the pinned project (design/010 §11, §2).
    static func newProject(id: String) -> MactermProtocol.Project {
        .init(id: id, name: displayName, path: "", sidebar: .top, removable: false, alias: alias)
    }

    /// The pinned project as the app makes it: a new id.
    static func newProject() -> Project {
        var project = Project(id: UUID(), name: displayName, path: "")
        project.sidebar = .top
        project.removable = false
        project.alias = alias
        return project
    }
}

/// One pinned tab's durable identity: a declaration (splits + per-pane
/// cwd/run/shell — the respawn recipe) that outlives the live tab. A record
/// with a matching live `TerminalTab` in the pinned workspace is "loaded";
/// one without is "unloaded" (its sessions died) and is rebuilt from the
/// declaration when selected.
struct PinnedTabRecord: Identifiable, Equatable {
    /// Stable across load/unload cycles; equals the live `TerminalTab.id`
    /// while loaded. Internal only — `pinned.yaml` entries deliberately carry
    /// no id (see `PinnedLayoutMatcher`).
    let id: UUID
    /// The respawn recipe. Captured at pin time, refreshed from live state at
    /// quit, and replaced by hand-edits to `pinned.yaml`. Leaf `cwd`s are
    /// self-contained (absolute / `~` / scp-spec) — there is no project root.
    var declaration: LayoutTab
    /// The project the tab was pinned from — where "Unpin" returns it.
    /// nil for tabs born pinned (Cmd+T in the pinned workspace, a hand-added
    /// file entry); unpin then falls back to the first project.
    var originProjectID: UUID?

    /// Sidebar title for an UNLOADED record (a loaded one shows its live
    /// tab's `displayTitle`): the declared name, else the first declared
    /// command, else the first leaf's cwd, else a generic label.
    var displayTitle: String {
        if let name = declaration.name, !name.isEmpty { return name }
        let panes = Self.leaves(of: declaration.layout)
        if let run = panes.compactMap(\.run).first(where: { !$0.isEmpty }) { return run }
        if let cwd = panes.compactMap(\.cwd).first(where: { !$0.isEmpty }) {
            return (cwd as NSString).lastPathComponent
        }
        return String(localized: "Pinned Tab", comment: "Sidebar title of a pinned tab that has no name")
    }

    private static func leaves(of node: LayoutNode) -> [LayoutPane] {
        switch node {
        case let .pane(p): [p]
        case let .split(b): leaves(of: b.first) + leaves(of: b.second)
        }
    }
}
