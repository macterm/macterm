import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    /// The projects in tree order: depth first, and the rows of each parent
    /// in `sortOrder`. It never holds a group, so a caller that needs a path
    /// or a workspace reads this list. `normalize` derives it from `rows`
    /// after each change. It is stored because many view bodies read it.
    private(set) var projects: [Project] = []
    /// Every row of projects.json: the projects and the groups (design 013).
    private var rows: [Project] = []
    private let fileURL: URL
    /// Set when `load()` found a present-but-undecodable projects.json. While
    /// set, `save()` refuses to overwrite — a transient read/decode failure
    /// must never let the next mutation wipe the user's entire project list.
    @ObservationIgnored
    private(set) var loadFailed = false
    /// Whether `create` tags a new project. Injectable so tests don't mutate
    /// the shared preference — swift-testing runs suites in parallel.
    @ObservationIgnored
    var autoAssignsColors: () -> Bool = { Preferences.shared.autoAssignProjectColors }
    /// Called with the list after each save that wrote it (the Spotlight
    /// index, `ProjectSpotlightIndex`). Not called while `loadFailed` refuses
    /// to save, because that list is not the user's.
    @ObservationIgnored
    var onSave: (([Project]) -> Void)?

    init(fileURL: URL = FileStorage.fileURL(filename: "projects.json")) {
        self.fileURL = fileURL
        load()
    }

    func project(matchingPath path: String) -> Project? {
        projects.first { ProjectPath.matches($0.path, path) }
    }

    /// Return the first project whose path matches, else add a new one. The
    /// create-or-select entry point for idempotent callers — the benchmark
    /// harness (which may replay `open-project`) and any script that expects
    /// re-running to be a no-op. Interactive project creation goes through
    /// `create` instead, so the same directory can back several projects.
    @discardableResult
    func findOrCreate(name: String, path: String) -> Project {
        if let existing = project(matchingPath: path) {
            return existing
        }
        return create(name: name, path: path)
    }

    /// Always add a new project, even when one already backs this directory.
    /// A directory is not an identity: two projects may share a `path` and
    /// keep wholly independent workspaces (keyed on `Project.id`) and zmx
    /// sessions (named with per-pane entropy). This is the entry point for
    /// user-initiated creation (folder picker, remote sheet, `project create`).
    ///
    /// A name the pinned workspace reserves is stored suffixed (see
    /// `unreservedName`). Most callers pass the folder's own name — the
    /// picker, Finder, Open With, the palette, a bare `project create` — which
    /// nobody chose, so refusing it would make a folder called Pinned
    /// impossible to add. A caller holding a name someone typed refuses it
    /// before calling this, where it can say why.
    @discardableResult
    func create(name: String, path: String) -> Project {
        var project = Project(name: Self.unreservedName(name), path: path)
        if autoAssignsColors() {
            project.colorName = ProjectColor.leastUsed(among: projects.map(\.color)).rawValue
        }
        return add(project)
    }

    /// Append a row at the end of its parent, and return it as stored. A
    /// group's path is cleared. A parent that is not a group of this store
    /// becomes nil (top level).
    @discardableResult
    func add(_ project: Project) -> Project {
        var project = project
        project.path = project.isGroup ? "" : ProjectPath.normalizedForStorage(project.path)
        if !isGroup(project.parent) { project.parent = nil }
        project.sortOrder = children(of: project.parent).count
        rows.append(project)
        changed()
        return project
    }

    /// Remove a row. The rows of a removed group go to the end of the top
    /// level.
    func remove(id: UUID) {
        rows.removeAll { $0.id == id }
        changed()
    }

    // MARK: - Tree

    /// Every row, the groups too, in the order of the file. The model of
    /// design/010 holds both (`ModelShadow`).
    var allRows: [Project] {
        rows
    }

    /// The rows whose parent is `parent` (nil: the top level), projects and
    /// groups, in `sortOrder`.
    func children(of parent: UUID?) -> [Project] {
        rows.filter { $0.parent == parent }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Move a row into the group `parent` (nil: the top level), at its end.
    /// A row that is already in `parent` does not move. Returns false when
    /// `parent` is not a group, or is the row or a group inside the row.
    @discardableResult
    func move(_ id: UUID, into parent: UUID?) -> Bool {
        move(id, into: parent, saving: true)
    }

    /// `move(_:into:)`. With `saving` false, the caller saves after its own
    /// next change.
    private func move(_ id: UUID, into parent: UUID?, saving: Bool) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), isGroup(parent) else { return false }
        if let parent, parent == id || ancestors(of: parent).contains(id) { return false }
        guard rows[index].parent != parent else { return true }
        rows[index].sortOrder = children(of: parent).count
        rows[index].parent = parent
        if saving { changed() }
        return true
    }

    /// Put the rows of `parent` in the order of `ids`. An id that is not a
    /// row of `parent` is ignored. A row of `parent` that `ids` does not
    /// name keeps its order after the named ones.
    func reorder(parent: UUID?, ids: [UUID]) {
        setOrder(parent: parent, ids: ids)
        changed()
    }

    private func setOrder(parent: UUID?, ids: [UUID]) {
        let siblings = children(of: parent).map(\.id)
        var order = ids.filter(siblings.contains)
        order = order.enumerated().filter { order.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        order += siblings.filter { !order.contains($0) }
        for (position, id) in order.enumerated() {
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].sortOrder = position }
        }
    }

    /// The row `id`, a project or a group.
    func row(_ id: UUID) -> Project? {
        rows.first { $0.id == id }
    }

    /// Every group, in tree order (a group before the groups inside it).
    var groups: [Project] {
        func walk(_ parent: UUID?) -> [Project] {
            children(of: parent).filter(\.isGroup).flatMap { [$0] + walk($0.id) }
        }
        return walk(nil)
    }

    /// The projects inside the group `id`, at any depth, in tree order.
    func projects(inGroup id: UUID) -> [Project] {
        treeOrder(under: id)
    }

    /// Put the row `id` beside the row `target`: in the parent of `target`,
    /// at the place of `target`. In one parent, a row that moves down goes
    /// after `target` and a row that moves up goes before it. A row from
    /// another parent goes before `target`. Returns false when the move
    /// would put a group inside itself.
    @discardableResult
    func place(_ id: UUID, beside target: UUID) -> Bool {
        guard id != target, let targetRow = row(target), let moving = row(id) else { return false }
        let parent = targetRow.parent
        let sameParent = moving.parent == parent
        var siblings = children(of: parent).map(\.id)
        let wasBefore = sameParent && (siblings.firstIndex(of: id) ?? 0) < (siblings.firstIndex(of: target) ?? 0)
        guard move(id, into: parent, saving: false) else { return false }
        siblings = children(of: parent).map(\.id).filter { $0 != id }
        let index = siblings.firstIndex(of: target) ?? siblings.endIndex
        siblings.insert(id, at: wasBefore ? index + 1 : index)
        reorder(parent: parent, ids: siblings)
        return true
    }

    /// Move the row `id` out of its group, to the place after that group.
    /// A row at the top level does not move.
    func moveOut(_ id: UUID) {
        guard let parent = row(id)?.parent else { return }
        let grandparent = row(parent)?.parent
        _ = move(id, into: grandparent, saving: false)
        var siblings = children(of: grandparent).map(\.id).filter { $0 != id }
        let index = siblings.firstIndex(of: parent).map { $0 + 1 } ?? siblings.endIndex
        siblings.insert(id, at: index)
        reorder(parent: grandparent, ids: siblings)
    }

    /// Move the row `id` one place up (`offset` -1) or down (+1) among the
    /// rows of its parent.
    func moveAmongSiblings(_ id: UUID, by offset: Int) {
        guard let parent = row(id).map(\.parent) else { return }
        var siblings = children(of: parent).map(\.id)
        guard let index = siblings.firstIndex(of: id), siblings.indices.contains(index + offset) else { return }
        siblings.swapAt(index, index + offset)
        reorder(parent: parent, ids: siblings)
    }

    /// The place of `id` among the rows of its parent, and their count.
    func siblingPosition(of id: UUID) -> (index: Int, count: Int)? {
        guard let parent = row(id).map(\.parent) else { return nil }
        let siblings = children(of: parent)
        return siblings.firstIndex { $0.id == id }.map { ($0, siblings.count) }
    }

    /// Add a new group. With `beside`, the group goes after that row, in its
    /// parent. Without it, the group goes at the end of the top level.
    @discardableResult
    func createGroup(name: String, beside: UUID? = nil) -> Project {
        let parent = beside.flatMap { row($0)?.parent }
        let group = add(.group(name: name, parent: parent))
        if let beside {
            var siblings = children(of: parent).map(\.id).filter { $0 != group.id }
            let index = siblings.firstIndex(of: beside).map { $0 + 1 } ?? siblings.endIndex
            siblings.insert(group.id, at: index)
            reorder(parent: parent, ids: siblings)
        }
        return group
    }

    /// Remove the group `id` and keep its rows: they go to the parent of the
    /// group, at its place, in their order.
    func ungroup(_ id: UUID) {
        guard let group = row(id), group.isGroup else { return }
        let inside = children(of: id).map(\.id)
        var siblings = children(of: group.parent).map(\.id)
        let index = siblings.firstIndex(of: id) ?? siblings.endIndex
        siblings.replaceSubrange(index ..< min(index + 1, siblings.endIndex), with: inside)
        for child in inside {
            if let at = rows.firstIndex(where: { $0.id == child }) { rows[at].parent = group.parent }
        }
        rows.removeAll { $0.id == id }
        setOrder(parent: group.parent, ids: siblings)
        changed()
    }

    /// Remove the group `id` and every row inside it, at any depth. The
    /// caller ends the sessions of `projects(inGroup:)` first.
    func removeGroup(_ id: UUID) {
        guard row(id)?.isGroup == true else { return }
        let removed = Set(rows.map(\.id).filter { $0 == id || ancestors(of: $0).contains(id) })
        rows.removeAll { removed.contains($0.id) }
        changed()
    }

    /// Whether `id` is nil (the top level) or a group of this store: the
    /// two places a row can be.
    private func isGroup(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return rows.contains { $0.id == id && $0.isGroup }
    }

    /// The groups above `id`, nearest first. Stops at a loop.
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var next = rows.first { $0.id == id }?.parent
        while let current = next, current != id, !result.contains(current) {
            result.append(current)
            next = rows.first { $0.id == current }?.parent
        }
        return result
    }

    /// Rename a project, unless `Project.reservesName` matches the new
    /// name: then the project keeps its old one. Every caller holds a name
    /// someone typed and says why first (the CLI's `bad_request`, the
    /// sidebar's notice); this only stops one that forgot to.
    func rename(id: UUID, to newName: String) {
        guard !Project.reservesName(newName) else {
            logger.error("Refusing to rename project \(id, privacy: .public) to reserved name \(newName, privacy: .public)")
            return
        }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].name = newName
        changed()
    }

    /// `name`, or — when a sentinel workspace reserves it — the name a second
    /// one would get: `Pinned 2`, the suffix its layout file already takes
    /// (`pinned_2.yaml`, see `ProjectFileStore.write`). The case is kept; it
    /// is still the folder's name. Only the bare name is reserved, so the
    /// suffixed one is always reachable, and a second project from the same
    /// folder is a second `Pinned 2`, as a second `api` is a second `api`.
    private static func unreservedName(_ name: String) -> String {
        guard Project.reservesName(name) else { return name }
        let suffixed = "\(name.trimmingCharacters(in: .whitespacesAndNewlines)) 2"
        logger.info("Project name \(name, privacy: .public) is reserved; creating \(suffixed, privacy: .public)")
        return suffixed
    }

    /// Set (or clear, with nil) the project's color tag.
    func setColor(id: UUID, to color: ProjectColor?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        guard rows[index].colorName != color?.rawValue else { return }
        rows[index].colorName = color?.rawValue
        changed()
    }

    /// Set a project's path. A group has no path, so it is refused.
    func setPath(id: UUID, to newPath: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].isGroup else { return }
        let normalized = ProjectPath.normalizedForStorage(newPath)
        guard rows[index].path != normalized else { return }
        rows[index].path = normalized
        changed()
    }

    /// After each change: normalize the rows, derive `projects`, save.
    private func changed() {
        normalize()
        save()
    }

    /// Repair the rows, then derive `projects`. Load calls it too. It writes
    /// nothing to disk; the next save writes the repaired rows.
    /// - A group has no path.
    /// - A parent that is not a group of this list (a removed group, a hand
    ///   edit, a project) becomes nil, and the row goes to the end of the
    ///   top level. A parent link in a loop becomes nil too.
    /// - The rows of each parent get `sortOrder` 0, 1, 2 in their order.
    private func normalize() {
        let groups = Set(rows.filter(\.isGroup).map(\.id))
        for index in rows.indices {
            if rows[index].isGroup {
                rows[index].path = ""
            }
            if let parent = rows[index].parent, !groups.contains(parent) {
                moveToEndOfTopLevel(index)
            }
        }
        for index in rows.indices {
            if let parent = rows[index].parent, ancestors(of: parent).contains(rows[index].id) || parent == rows[index].id {
                moveToEndOfTopLevel(index)
            }
        }
        // Stable: rows with equal `sortOrder` keep their order.
        rows = rows.enumerated()
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
        var next: [UUID?: Int] = [:]
        for index in rows.indices {
            rows[index].sortOrder = next[rows[index].parent, default: 0]
            next[rows[index].parent, default: 0] += 1
        }
        projects = treeOrder(under: nil)
    }

    private func moveToEndOfTopLevel(_ index: Int) {
        rows[index].parent = nil
        rows[index].sortOrder = rows.count + index
    }

    private func treeOrder(under parent: UUID?) -> [Project] {
        children(of: parent).flatMap { $0.isGroup ? treeOrder(under: $0.id) : [$0] }
    }

    private func save() {
        guard !loadFailed else {
            logger.error("Refusing to save projects: prior load failed, file preserved")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rows)
            try data.write(to: fileURL, options: .atomic)
            onSave?(projects)
        } catch {
            logger.error("Failed to save projects: \(error, privacy: .public)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.error("Failed to read projects file: \(error, privacy: .public)")
            loadFailed = true
            return
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return }
        do {
            rows = try JSONDecoder().decode([Project].self, from: data)
            // Migrate paths stored before normalization existed (e.g. with the
            // trailing slash `URL.path(percentEncoded:)` keeps on directories).
            // In-memory only; the cleaned form persists on the next mutation.
            for i in rows.indices where !rows[i].isGroup {
                rows[i].path = ProjectPath.normalizedForStorage(rows[i].path)
            }
            normalize()
        } catch {
            // Present but undecodable — a corrupt entry or a future format.
            // Preserve the file: refuse to overwrite it until this session
            // restarts and reads it cleanly (or the user fixes it).
            logger.error("Failed to decode projects file: \(error, privacy: .public)")
            loadFailed = true
        }
    }
}
