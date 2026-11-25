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
    /// The project that holds this one, or nil at the top level (design
    /// 013). `sortOrder` orders the children of one parent. Absent in older
    /// projects.json. `ProjectStore` reads a parent that is not one of its
    /// projects as nil.
    var parent: UUID?
    /// The capability fields of design/010 §11, §2. The app sets them when
    /// it makes the project, and they never change. A project of the
    /// sidebar tree has the defaults. The hidden projects (Pinned, Scratch
    /// Tabs, the quick terminal, a widget) have others.
    var sidebar: MactermProtocol.ProjectSidebar = .tree
    var singleTab = false
    var removable = true
    /// The one short word that finds a singleton: `pinned`, `scratch` or
    /// `quick`. A lookup, never a behavior.
    var alias: String?

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
        createdAt = Date()
    }

    /// A project with a known id: a row of a v1 file, or a test.
    init(id: UUID, name: String, path: String, sortOrder: Int = 0, colorName: String? = nil, parent: UUID? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.colorName = colorName
        self.parent = parent
        createdAt = Date()
    }

    /// The project of the model. `id` and `parent` are the mirror's UUIDs
    /// of the wire ids.
    init(model p: MactermProtocol.Project, id: UUID, parent: UUID?) {
        self.id = id
        name = p.name
        path = p.path
        sortOrder = Int(p.sortOrder)
        createdAt = Date(timeIntervalSince1970: TimeInterval(p.createdAt) / 1000)
        colorName = p.color
        self.parent = parent
        sidebar = p.sidebar
        singleTab = p.singleTab
        removable = p.removable
        alias = p.alias
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case sortOrder
        case createdAt
        case colorName
        case parent
        /// Read only: a dev build wrote `kind: group` (design 013).
        case kind
    }

    /// `parent` is an optional key, so a file from before nested projects
    /// decodes as before. A row of a dev build with `kind: group` decodes as
    /// a project with no folder, with its `parent`. Any other `kind` is
    /// ignored. The encoder never writes `kind`, so the next save drops it
    /// (design 013, "Ethan chose B").
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        parent = try container.decodeIfPresent(UUID.self, forKey: .parent)
        if (try? container.decodeIfPresent(String.self, forKey: .kind)) == "group" {
            path = ""
        }
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
    }
}

extension Project {
    /// nil when untagged, or tagged with a value this build doesn't know.
    var color: ProjectColor? { colorName.flatMap(ProjectColor.init(rawValue:)) }

    /// Whether the project has a folder. Only a row of a dev build that
    /// was a group has none (design 013): no command makes one. The places
    /// that read `path` skip a project with no folder.
    var hasFolder: Bool { !path.isEmpty }

    /// Parsed location: `.local` for a directory path, `.remote` for an
    /// scp-style `[user@]host:dir` spec (#104). nil when `path` parses as
    /// neither (a hand-corrupted projects.json entry).
    var location: ProjectPath? { ProjectPath.parse(path) }

    /// Whether this project lives on a remote host. Remote projects spawn
    /// panes over ssh (`HostCommands`) and skip every local-cwd/local-pid
    /// feature (foreground poll, replace-path-with-cwd, live layout capture).
    var isRemote: Bool { ProjectPath.isRemote(path) }
}

extension Project {
    /// A row of the sidebar tree: the projects that `project list`, the
    /// palette, Spotlight and Settings → Projects show (design/010 §11, §2).
    /// Only a tree project can hold child projects or be dragged as a
    /// project.
    var isTreeProject: Bool { sidebar == .tree }

    /// A window can select it (`select.set`): not the quick terminal's and
    /// not a widget's.
    var isSelectable: Bool { sidebar != .none }

    /// Why a typed project name is refused, or nil when it is allowed. The
    /// one test every naming path applies. A name cannot contain a slash
    /// (`hasSlash`). A sentinel workspace reserves its name, because
    /// `ControlHandler` resolves it before any project
    /// (`PinnedTabs.reservesName`, `ScratchTabs.reservesName`).
    static func nameRefusal(for name: String) -> String? {
        if hasSlash(name) { return slashMessage }
        if PinnedTabs.reservesName(name) { return PinnedTabs.reservedNameMessage }
        if ScratchTabs.reservesName(name) { return ScratchTabs.reservedNameMessage }
        return nil
    }

    /// Whether a sentinel workspace reserves `name`.
    static func reservesName(_ name: String) -> Bool {
        PinnedTabs.reservesName(name) || ScratchTabs.reservesName(name)
    }

    /// Whether `name` contains a slash. A nested project is named by the
    /// path of names from the top level ("Work/api/lib": the palette and
    /// Move to Project), so a slash in one name makes that path ambiguous.
    /// Names that got a slash before this rule still load.
    static func hasSlash(_ name: String) -> Bool {
        name.contains("/")
    }

    /// Why a typed name with a slash was refused, as the app says it. The
    /// CLI says the same in English (`ControlHandler.checkName`).
    static let slashMessage = String(localized: "A project name cannot contain a slash.")
}
