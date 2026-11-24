import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    /// Every project in tree order: depth first, a parent before its
    /// children, and the children of each parent in `sortOrder` (design
    /// 013). A project can have no folder (`Project.hasFolder`).
    /// `normalize` derives it from `rows` after each change. It is stored
    /// because many view bodies read it.
    private(set) var projects: [Project] = []
    /// Every row of projects.json, in the order of the file.
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
    /// A name that `Project.nameRefusal` refuses is stored changed (see
    /// `allowedName`). Most callers pass the folder's own name — the
    /// picker, Finder, Open With, the palette, a bare `project create` — which
    /// nobody chose, so refusing it would make a folder called Pinned
    /// impossible to add. The `name:` of a layout file is changed the same
    /// way. A caller holding a name someone typed refuses it before calling
    /// this, where it can say why.
    @discardableResult
    func create(name: String, path: String, parent: UUID? = nil) -> Project {
        var project = Project(name: Self.allowedName(name), path: path, parent: parent)
        if autoAssignsColors() {
            project.colorName = ProjectColor.leastUsed(among: projects.map(\.color)).rawValue
        }
        return add(project)
    }

    /// Append a project at the end of its parent, and return it as stored.
    /// A parent that is not a project of this store becomes nil (top level).
    @discardableResult
    func add(_ project: Project) -> Project {
        var project = project
        project.path = ProjectPath.normalizedForStorage(project.path)
        if !isPlace(project.parent) { project.parent = nil }
        project.sortOrder = children(of: project.parent).count
        rows.append(project)
        changed()
        return project
    }

    // MARK: - Tree

    /// The projects whose parent is `parent` (nil: the top level), in
    /// `sortOrder`.
    func children(of parent: UUID?) -> [Project] {
        rows.filter { $0.parent == parent }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Move a project into the project `parent` (nil: the top level), at its
    /// end. A project that is already in `parent` does not move. Returns
    /// false when `parent` is not a project of this store, or is the project
    /// itself or a project inside it.
    @discardableResult
    func move(_ id: UUID, into parent: UUID?) -> Bool {
        move(id, into: parent, saving: true)
    }

    /// `move(_:into:)`. With `saving` false, the caller saves after its own
    /// next change.
    private func move(_ id: UUID, into parent: UUID?, saving: Bool) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), isPlace(parent) else { return false }
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

    /// The project `id`.
    func row(_ id: UUID) -> Project? {
        rows.first { $0.id == id }
    }

    /// The projects inside the project `id`, at any depth, in tree order.
    func descendants(of id: UUID) -> [Project] {
        treeOrder(under: id)
    }

    /// Move the project `id` out of its parent, to the place after that
    /// parent. A project at the top level does not move.
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

    /// Remove the project `id` and every project inside it, at any depth.
    /// The caller ends the sessions of all of them first.
    func removeWithDescendants(_ id: UUID) {
        guard row(id) != nil else { return }
        let removed = Set(rows.map(\.id).filter { $0 == id || ancestors(of: $0).contains(id) })
        rows.removeAll { removed.contains($0.id) }
        changed()
    }

    /// Whether `id` is nil (the top level) or a project of this store: the
    /// two places a project can be.
    private func isPlace(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return rows.contains { $0.id == id }
    }

    /// The projects above `id`, nearest first. Stops at a loop.
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var next = rows.first { $0.id == id }?.parent
        while let current = next, current != id, !result.contains(current) {
            result.append(current)
            next = rows.first { $0.id == current }?.parent
        }
        return result
    }

    /// Rename a project, unless `Project.nameRefusal` refuses the new
    /// name: then the project keeps its old one. Every caller holds a name
    /// someone typed and says why first (the CLI's `bad_request`, the
    /// sidebar's notice); this only stops one that forgot to.
    func rename(id: UUID, to newName: String) {
        guard Project.nameRefusal(for: newName) == nil else {
            logger.error("Refusing to rename project \(id, privacy: .public) to refused name \(newName, privacy: .public)")
            return
        }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].name = newName
        changed()
    }

    /// `name` changed so that `Project.nameRefusal` allows it. Each slash
    /// becomes a hyphen. A name that a sentinel workspace reserves becomes the
    /// name a second one would get: `Pinned 2`, the suffix its layout file
    /// already takes (`pinned_2.yaml`, see `ProjectFileStore.write`). The
    /// case is kept; it is still the folder's name. Only the bare name is
    /// reserved, so the suffixed one is always reachable, and a second project
    /// from the same folder is a second `Pinned 2`, as a second `api` is a
    /// second `api`.
    static func allowedName(_ name: String) -> String {
        var name = name
        if Project.hasSlash(name) {
            let hyphenated = name.replacingOccurrences(of: "/", with: "-")
            logger.info("Project name \(name, privacy: .public) has a slash; creating \(hyphenated, privacy: .public)")
            name = hyphenated
        }
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

    /// Set a project's path. A project with no folder gets one this way.
    func setPath(id: UUID, to newPath: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
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
    /// - A parent that is not a project of this list (a removed project, a
    ///   hand edit) becomes nil, and the project goes to the end of the top
    ///   level. A parent link in a loop becomes nil too.
    /// - The children of each parent get `sortOrder` 0, 1, 2 in their order.
    private func normalize() {
        let ids = Set(rows.map(\.id))
        for index in rows.indices {
            if let parent = rows[index].parent, !ids.contains(parent) {
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
        children(of: parent).flatMap { [$0] + treeOrder(under: $0.id) }
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
            for i in rows.indices {
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
