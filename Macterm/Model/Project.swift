import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var sortOrder: Int
    var createdAt: Date
    /// Color tag — the `rawValue` of a `ProjectColor`. A String, not the enum,
    /// so an unknown value (hand-edited json, newer build) reads as untagged
    /// instead of failing the row's decode. Absent in older projects.json.
    var colorName: String?
    /// The group that holds this row, or nil at the top level (design 013).
    /// `sortOrder` orders the rows of one parent. Absent in older
    /// projects.json. `ProjectStore` reads a parent that is not one of its
    /// groups as nil.
    var parent: UUID?
    /// A project, or a group: a row that only holds other rows. A group has
    /// an empty `path` and never gets a workspace, so `ProjectStore.projects`
    /// never returns one. Absent in older projects.json, where every row is
    /// a project.
    var kind: ProjectKind

    init(
        name: String,
        path: String,
        sortOrder: Int = 0,
        colorName: String? = nil,
        parent: UUID? = nil
    ) {
        id = UUID()
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.colorName = colorName
        self.parent = parent
        kind = .project
        createdAt = Date()
    }

    /// A new group. It has no path.
    static func group(name: String, sortOrder: Int = 0, parent: UUID? = nil) -> Project {
        var group = Project(name: name, path: "", sortOrder: sortOrder, parent: parent)
        group.kind = .group
        return group
    }

    /// Explicit-id variant for SYNTHETIC projects only (`PinnedTabs.project`,
    /// `ScratchTabs.project`).
    /// Real projects always mint a fresh id above — a directory is not an
    /// identity, and two projects may share a path.
    init(id: UUID, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
        sortOrder = 0
        colorName = nil
        parent = nil
        kind = .project
        createdAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case sortOrder
        case createdAt
        case colorName
        case parent
        case kind
    }

    /// `parent` and `kind` are optional keys, so a file from before groups
    /// decodes as before. A file with no group writes neither key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        parent = try container.decodeIfPresent(UUID.self, forKey: .parent)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .project
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(colorName, forKey: .colorName)
        try container.encodeIfPresent(parent, forKey: .parent)
        if kind != .project { try container.encode(kind, forKey: .kind) }
    }
}

/// What a `ProjectStore` row is. An unknown value fails the decode of the
/// file, and the store then refuses to save over it: a newer build's row
/// is never read as a project.
enum ProjectKind: String, Codable {
    case project
    case group
}

extension Project {
    /// nil when untagged, or tagged with a value this build doesn't know.
    var color: ProjectColor? { colorName.flatMap(ProjectColor.init(rawValue:)) }

    var isGroup: Bool { kind == .group }

    /// Parsed location: `.local` for a directory path, `.remote` for an
    /// scp-style `[user@]host:dir` spec (#104). nil when `path` parses as
    /// neither (a hand-corrupted projects.json entry).
    var location: ProjectPath? { ProjectPath.parse(path) }

    /// Whether this project lives on a remote host. Remote projects spawn
    /// panes over ssh (`HostCommands`) and skip every local-cwd/local-pid
    /// feature (foreground poll, replace-path-with-cwd, live layout capture).
    var isRemote: Bool { ProjectPath.isRemote(path) }
}

/// The two workspaces that are not `ProjectStore` rows: the pinned tabs and
/// the scratch tabs. Each has a synthetic `Project` for the call sites that
/// render or route by a `Project`.
extension Project {
    /// The synthetic project behind a sentinel workspace id; nil for a real
    /// project's id.
    static func synthetic(for id: UUID) -> Project? {
        switch id {
        case PinnedTabs.workspaceID: PinnedTabs.project
        case ScratchTabs.workspaceID: ScratchTabs.project
        default: nil
        }
    }

    /// Whether `id` is a sentinel workspace: it has no directory, no layout
    /// file and no row in Settings → Projects, and it can be neither renamed
    /// nor removed.
    static func isSynthetic(_ id: UUID) -> Bool {
        synthetic(for: id) != nil
    }

    /// Why a typed project name is refused, or nil when it is free. A
    /// sentinel workspace reserves its name, because `ControlHandler`
    /// resolves it before any project (`PinnedTabs.reservesName`,
    /// `ScratchTabs.reservesName`). The one test every naming path applies.
    static func reservedNameMessage(for name: String) -> String? {
        if PinnedTabs.reservesName(name) { return PinnedTabs.reservedNameMessage }
        if ScratchTabs.reservesName(name) { return ScratchTabs.reservedNameMessage }
        return nil
    }

    /// `reservedNameMessage(for:) != nil`.
    static func reservesName(_ name: String) -> Bool {
        reservedNameMessage(for: name) != nil
    }
}
