import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "WorkspacePersistence")

// MARK: - File envelope

/// Current schema version. Bump when the snapshot types change shape.
/// Adding an optional field does NOT require a bump — Codable decodes
/// missing fields as nil / default. Removing or renaming fields does.
/// v5 adds the `pinned` section; the bump is deliberate even though the key
/// is optional, because an older build would restore without pinned tabs and
/// then SAVE without them — the version gate turns that into refuse-to-save,
/// so a downgrade preserves pinned state instead of silently dropping it.
/// v6 adds `windows`. Same reasoning as v5's bump: the key is optional, but an
/// older build would restore ignoring the window list and then SAVE without it,
/// silently collapsing a multi-window setup back to one. The version gate turns
/// that into refuse-to-save instead.
/// v7 adds `desktopWidgets`, for v5's reason again: an older build would
/// restore without the widgets and then save without them — and its orphan
/// reaper would kill their sessions, since nothing it restored claims them.
/// Unlike v5 and v6, it is written only while there ARE widgets to protect:
/// a file with none is written as v6, so switching to an older build (the
/// stable channel after a spell on tip) keeps saving for everyone who never
/// made a widget, whom the gate would otherwise freeze for nothing.
private let currentSchemaVersion = 7
private let widgetFreeSchemaVersion = 6

/// Top-level on-disk representation. Wraps the workspace array so we can
/// evolve the file format (add fields, do migrations) without renaming the
/// file. Readers that encounter the old bare-array format still work.
struct WorkspacesFile: Codable {
    var version: Int
    var workspaces: [WorkspaceSnapshot]
    /// Pinned tabs (v5+): kept out of `workspaces` so the sentinel project ID
    /// never collides with the `validIDs` restore filter. Optional so v4
    /// files decode with nil.
    var pinned: [PinnedTabSnapshot]?
    /// The pinned workspace's selected tab (v5+) — the sentinel is excluded
    /// from `workspaces`, which is where every other workspace keeps its
    /// `activeTabID`.
    var pinnedActiveTabID: UUID?
    /// Open terminal windows (v6+), in creation order, so quitting and
    /// relaunching brings them all back rather than just one (#345). Optional
    /// so a v5 file decodes with nil, which restores the single window the
    /// scene opens by itself.
    var windows: [WindowSnapshot]?
    /// The quick terminal's one tab, so its zmx sessions reattach on relaunch
    /// exactly as workspace panes do. Optional, and deliberately NOT a schema
    /// bump, unlike `pinned` and `windows`: the version gate exists to stop an
    /// older build from saving away state it cannot see, but an older build
    /// killed every quick-terminal session on quit by design, so a downgrade
    /// losing them is that build's normal behavior rather than data loss —
    /// not worth freezing the user's whole workspace persistence over.
    var quickTerminal: TabSnapshot?
    /// Desktop widgets (v7+), in creation order. Optional so a v6 file
    /// decodes with nil — no widgets.
    var desktopWidgets: [DesktopWidgetSnapshot]?
}

/// One desktop widget's restorable state (v7+): its one tab (the session
/// identity it reattaches by) and where it sits on the desktop. Whether it
/// was being edited is deliberately absent — every widget launches locked.
struct DesktopWidgetSnapshot: Codable {
    var id: UUID
    var name: String?
    var tab: TabSnapshot?
    /// The widget's span in grid cells (`DesktopWidgetSpan`).
    var columns: Int
    var rows: Int
    /// Top-left corner in global AppKit screen coordinates — where it was at
    /// the save, which after a display change can be a projection.
    var topLeftX: Double
    var topLeftY: Double
    /// The respawn recipe (`DesktopWidget.command`/`cwd`).
    var command: String?
    var cwd: String?
    /// Where the user put it per display and resolution
    /// (`DesktopWidget.placements`). Optional, with no schema bump: a
    /// snapshot from before it existed decodes as nil and the widget's
    /// placement is taken from `topLeft`, and an older build ignores it.
    var placements: [DesktopWidgetPlacement]?
}

/// One window's restorable state (v6+).
///
/// The project, the sidebar width and its open sections. Pane and tab selection are still shared
/// across windows. The frame stays AppKit's to restore — SwiftUI's
/// `WindowGroup` already persists window frames through the system's state
/// restoration, so storing them here would be a second, competing source of
/// truth. The sidebar width is different: nothing else restores it, because
/// SwiftUI's own column autosave is unreadable by construction.
struct WindowSnapshot: Codable {
    var activeProjectID: UUID?
    /// The window's sidebar width. Optional so a snapshot written before this
    /// existed decodes as nil, and the window opens at the app-wide default.
    var sidebarWidth: Double?
    /// Whether this was the key window at save time, so a relaunch fronts the
    /// window the user was in rather than the last one to open. Optional for
    /// the same reason; nil means "no preference".
    var isKey: Bool?
    /// The tab this window was showing in `activeProjectID`. Per window since
    /// two windows on one project show different tabs (#345); nil falls back
    /// to the workspace's own `activeTabID`.
    var activeTabID: UUID?
    /// Whether the sidebar was shown. Per window, and owned here rather than
    /// left to AppKit's split-view autosave, which is per autosave slot and so
    /// leaked one window's collapsed state into the next window at that slot.
    /// nil (an older snapshot) means shown.
    var sidebarVisible: Bool?
    /// Whether the window showed the Project Insights panel
    /// (`WindowState.projectMemoryPanelVisible`). An older snapshot has no
    /// value. It gets the retired app-wide value
    /// (`adoptingLegacyPanelVisibility`).
    var projectMemoryPanelVisible: Bool?
    /// The window's frame, as AppKit's own `frameDescriptor` string (the frame
    /// plus the screen it was on, so `setFrame(from:)` can fit it to a display
    /// that has since changed). Owned here rather than left to SwiftUI's
    /// `WindowGroup` autosave, whose key embeds runtime addresses and so is
    /// written fresh and never read back on every launch (#496). nil (an older
    /// snapshot, or a window that never reported a frame) opens at the
    /// scene's default size.
    var frame: String?
    /// The projects whose sidebar sections were open, sorted so that an
    /// unchanged set writes the same file. nil (an older snapshot) opens only
    /// the active project, as before.
    var expandedProjectIDs: [UUID]?
    /// Whether the window showed the project screen of `activeProjectID`
    /// (`WindowState.showsProjectScreen`). nil (an older snapshot) means a tab.
    var showsProjectScreen: Bool?

    /// The saved windows with the retired app-wide panel value
    /// (`Preferences.takeLegacyProjectMemoryPanelVisible`) in each window
    /// that saved no value of its own. A user who had the panel on sees it
    /// again in each restored window, once; the next save writes each
    /// window's own value.
    static func adoptingLegacyPanelVisibility(_ snapshots: [WindowSnapshot], legacyVisible: Bool) -> [WindowSnapshot] {
        guard legacyVisible else { return snapshots }
        return snapshots.map { snapshot in
            var snapshot = snapshot
            if snapshot.projectMemoryPanelVisible == nil { snapshot.projectMemoryPanelVisible = true }
            return snapshot
        }
    }
}

// MARK: - Snapshot types

struct WorkspaceSnapshot: Codable {
    let projectID: UUID
    let activeTabID: UUID?
    let tabs: [TabSnapshot]
}

struct TabSnapshot: Codable {
    let id: UUID
    let customTitle: String?
    let focusedPaneID: UUID?
    let splitRoot: SplitNodeSnapshot
}

indirect enum SplitNodeSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(SplitBranchSnapshot)

    private enum CodingKeys: String, CodingKey { case type, pane, split }
    private enum NodeType: String, Codable { case pane, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(NodeType.self, forKey: .type) {
        case .pane: self = try .pane(c.decode(PaneSnapshot.self, forKey: .pane))
        case .split: self = try .split(c.decode(SplitBranchSnapshot.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(p):
            try c.encode(NodeType.pane, forKey: .type)
            try c.encode(p, forKey: .pane)
        case let .split(b):
            try c.encode(NodeType.split, forKey: .type)
            try c.encode(b, forKey: .split)
        }
    }
}

struct PaneSnapshot: Codable {
    let id: UUID
    let projectPath: String
    /// No `needsAttention` or `completionFailed`: the session keeps a pane's
    /// attention flags across a quit (`Pane.attention`). An older file's keys
    /// are ignored on decode.
    /// The pane's session id, which the restored pane takes as its id. An
    /// older build saved a different `id`; this key wins. Nil in a very old
    /// file: the pane then takes `id`.
    var sessionID: UUID?
    /// The pane's zmx session name, persisted VERBATIM — never re-derived. The
    /// name embeds the project slug at creation time, so re-deriving it after
    /// a project rename would target a session that doesn't exist.
    var sessionName: String?
    /// The pane's live working directory at snapshot time, so a session that
    /// did NOT survive (reboot, external kill) respawns where the user was.
    /// A surviving session reattaches with its own live cwd regardless.
    var workingDirectory: String?
    /// A REMOTE pane's host folder, once its session ran on the host's
    /// server (`Pane.hostSessionDirectory`, 0057): the shell's own folder at
    /// save time. A pane with it whose session is gone on the host (a host
    /// restart) asks before it starts a new shell there; a pane without it
    /// (from before v2) starts one with no question. Optional, so older
    /// files decode it as nil.
    var hostSessionDirectory: String?
    // No `title`: the tab name is derived live from the pane's foreground
    // process, so there's nothing per-pane to persist. (An older snapshot's
    // `title` key is harmlessly ignored on decode.)

    /// Memberwise init with defaults for the optional fields, so call sites
    /// and tests that build old-shape snapshots keep compiling. (SwiftLint
    /// forbids `= nil` on the stored declarations.)
    init(
        id: UUID,
        projectPath: String,
        sessionID: UUID? = nil,
        sessionName: String? = nil,
        workingDirectory: String? = nil,
        hostSessionDirectory: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
        self.hostSessionDirectory = hostSessionDirectory
    }
}

struct SplitBranchSnapshot: Codable {
    /// `SplitBranch.id`, so a restored branch keeps its id. Optional: an
    /// older file decodes nil, and the branch gets a new id.
    var id: UUID?
    let direction: SplitDirection
    let ratio: Double
    let first: SplitNodeSnapshot
    let second: SplitNodeSnapshot
}

/// One pinned tab (v5+): its durable declaration plus — while it was live at
/// save time — the ordinary tab snapshot that lets its sessions reattach on
/// relaunch. `live == nil` is an unloaded record (sessions died; the
/// declaration is the respawn recipe).
struct PinnedTabSnapshot: Codable {
    let id: UUID
    let declaration: LayoutTab
    let originProjectID: UUID?
    let live: TabSnapshot?
}

// MARK: - Persistence

/// v1's `workspaces_v3.json`. The import reads it one time (design/010
/// §8). Nothing writes it after the cut-over, so a return to v1 finds it as
/// it was.
final class WorkspaceStore {
    private let fileURL: URL
    /// Set when `load()` found a present-but-undecodable file. While set,
    /// `save()` refuses to overwrite — a single corrupt field (or a snapshot
    /// written by a newer build) must never let the next autosave clobber the
    /// user's persisted tabs/sessions with empty state.
    /// Exposed read-only (#281): the orphan reapers infer "unclaimed" from the
    /// set of restored session names, so a failed load would present an empty
    /// claim set and mark every live session an orphan. Both reapers skip
    /// entirely while this is set — same fail-closed stance as `save`.
    private(set) var loadFailed = false

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    /// What `load()` recovered: the ordinary per-project snapshots plus the
    /// pinned section (empty for pre-v5 files).
    struct Loaded {
        var workspaces: [WorkspaceSnapshot] = []
        var pinned: [PinnedTabSnapshot] = []
        var pinnedActiveTabID: UUID?
        /// Windows to reopen (v6+); empty for an older file, which means the
        /// one window the scene opens by itself.
        var windows: [WindowSnapshot] = []
        /// The quick terminal's tab; nil for a file written before it was
        /// persisted.
        var quickTerminal: TabSnapshot?
        /// Desktop widgets (v7+); empty for an older file.
        var desktopWidgets: [DesktopWidgetSnapshot] = []
    }

    func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Loaded() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Could not even read the bytes (transient I/O). Preserve the file:
            // don't let the next save overwrite what we couldn't read.
            logger.error("Failed to read workspaces file: \(error, privacy: .public)")
            loadFailed = true
            return Loaded()
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return Loaded() }
        let decoder = JSONDecoder()
        // Envelope format first (version + workspaces).
        do {
            let file = try decoder.decode(WorkspacesFile.self, from: data)
            guard file.version <= currentSchemaVersion else {
                // A newer build wrote this. Decoding dropped keys it doesn't
                // know, so re-saving would silently downgrade + lose data.
                // Refuse to persist over it this session.
                logger.error("""
                Workspaces file schema v\(file.version, privacy: .public) is newer than \
                supported v\(currentSchemaVersion, privacy: .public); not overwriting
                """)
                loadFailed = true
                return Loaded(file)
            }
            return Loaded(file)
        } catch let envelopeError {
            // Fallback: pre-envelope format where the file was a bare array of
            // WorkspaceSnapshot. Upgrade on next save.
            if let bare = try? decoder.decode([WorkspaceSnapshot].self, from: data) {
                return Loaded(workspaces: bare)
            }
            // Present but decodable as neither shape → corrupt or a format we
            // don't understand. Log the PRIMARY (envelope) error and preserve
            // the file rather than clobbering it with the next save.
            logger.error("Failed to decode workspaces file: \(envelopeError, privacy: .public)")
            loadFailed = true
            return Loaded()
        }
    }
}

extension WorkspaceStore.Loaded {
    init(_ file: WorkspacesFile) {
        self.init(
            workspaces: file.workspaces,
            pinned: file.pinned ?? [],
            pinnedActiveTabID: file.pinnedActiveTabID,
            windows: file.windows ?? [],
            quickTerminal: file.quickTerminal,
            desktopWidgets: file.desktopWidgets ?? []
        )
    }
}

// MARK: - Snapshot / Restore

/// The checks of v1's snapshot that the import runs (design/010 §8).
enum WorkspaceSerializer {
    /// The tree with each pane that names a session already seen left out.
    /// One pane is one session. Older builds had `pane mirror`, which put a
    /// second pane on a session. Only the first pane restores, and the
    /// sibling of a later one takes its space.
    static func withoutRepeatedSessions(_ node: SplitNodeSnapshot, seen: inout Set<String>) -> SplitNodeSnapshot? {
        switch node {
        case let .pane(p):
            // The restored pane id must be new too: two panes never share one.
            let newID = seen.insert((p.sessionID ?? p.id).uuidString).inserted
            guard let name = p.sessionName else { return newID ? node : nil }
            return seen.insert(name).inserted && newID ? node : nil
        case let .split(b):
            let first = withoutRepeatedSessions(b.first, seen: &seen)
            let second = withoutRepeatedSessions(b.second, seen: &seen)
            guard let first else { return second }
            guard let second else { return first }
            return .split(SplitBranchSnapshot(id: b.id, direction: b.direction, ratio: b.ratio, first: first, second: second))
        }
    }

    /// The loaded file with each session on its first pane only, across every
    /// section, in restore order: project workspaces, pinned tabs, the quick
    /// terminal, desktop widgets. A file from a build with `pane mirror` can
    /// put one session on a project pane and a pinned or widget pane, and a
    /// close of one pane then kills the session under the other.
    /// - A workspace whose project is not in `validIDs` does not restore, so
    ///   its sessions do not count.
    /// - A pinned tab with no pane left has no live snapshot: it starts from
    ///   its declaration.
    /// - A quick terminal tab with no pane left is dropped: the panel keeps
    ///   its fresh tab.
    /// - A widget with no pane left gets a fresh session, and
    ///   `materializeRestoredDesktopWidgets` starts it from its recipe.
    static func withoutRepeatedSessions(_ loaded: WorkspaceStore.Loaded, validIDs: Set<UUID>) -> WorkspaceStore.Loaded {
        var seen: Set<String> = []
        var result = loaded
        result.workspaces = loaded.workspaces.map { snap in
            guard validIDs.contains(snap.projectID) else { return snap }
            return WorkspaceSnapshot(
                projectID: snap.projectID,
                activeTabID: snap.activeTabID,
                tabs: snap.tabs.compactMap { withoutRepeatedSessions($0, seen: &seen) }
            )
        }
        result.pinned = loaded.pinned.map { snap in
            PinnedTabSnapshot(
                id: snap.id,
                declaration: snap.declaration,
                originProjectID: snap.originProjectID,
                live: snap.live.flatMap { withoutRepeatedSessions($0, seen: &seen) }
            )
        }
        result.quickTerminal = loaded.quickTerminal.flatMap { withoutRepeatedSessions($0, seen: &seen) }
        result.desktopWidgets = loaded.desktopWidgets.map { widget in
            var widget = widget
            widget.tab = widget.tab.map { withoutRepeatedSessions($0, seen: &seen) ?? withFreshSessions($0) }
            return widget
        }
        return result
    }

    /// The tab with each pane whose session `seen` holds left out. Nil when
    /// no pane is left.
    static func withoutRepeatedSessions(_ t: TabSnapshot, seen: inout Set<String>) -> TabSnapshot? {
        guard let kept = withoutRepeatedSessions(t.splitRoot, seen: &seen) else { return nil }
        return TabSnapshot(id: t.id, customTitle: t.customTitle, focusedPaneID: t.focusedPaneID, splitRoot: kept)
    }

    /// The tab with no session identity, so each pane restores in a new
    /// session.
    private static func withFreshSessions(_ t: TabSnapshot) -> TabSnapshot {
        func fresh(_ node: SplitNodeSnapshot) -> SplitNodeSnapshot {
            switch node {
            case let .pane(p):
                // A new id too: the pane id is the session id.
                .pane(PaneSnapshot(
                    id: UUID(),
                    projectPath: p.projectPath,
                    workingDirectory: p.workingDirectory,
                    hostSessionDirectory: p.hostSessionDirectory
                ))
            case let .split(b):
                .split(SplitBranchSnapshot(
                    id: b.id,
                    direction: b.direction,
                    ratio: b.ratio,
                    first: fresh(b.first),
                    second: fresh(b.second)
                ))
            }
        }
        return TabSnapshot(id: t.id, customTitle: t.customTitle, focusedPaneID: t.focusedPaneID, splitRoot: fresh(t.splitRoot))
    }
}
