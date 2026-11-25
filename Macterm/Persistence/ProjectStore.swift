import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    /// The projects of the sidebar tree (`Project.isTreeProject`), in tree
    /// order: depth first, a parent before its children, and the children
    /// of each parent in `sortOrder` (design 013). A project can have no
    /// folder (`Project.hasFolder`). The server holds them (design/010 §11):
    /// this is the mirror's list, and each change is a request.
    var projects: [Project] { treeOrder(under: nil) }

    private let writer: ModelWriter
    private var mirror: ModelMirror { writer.mirror }
    /// The tree projects, as the mirror has them.
    private var rows: [Project] { mirror.treeProjects }

    /// Whether the model could not be read. Nothing is ended or removed on
    /// a list that is not the user's.
    var loadFailed: Bool { mirror.data == nil || mirror.readonly }
    /// Whether `create` tags a new project. Injectable so tests don't mutate
    /// the shared preference — swift-testing runs suites in parallel.
    @ObservationIgnored
    var autoAssignsColors: () -> Bool = { Preferences.shared.autoAssignProjectColors }
    /// Called with the list after each change of the projects of the model,
    /// by any client, and when the model is installed (the Spotlight index,
    /// `ProjectSpotlightIndex`).
    @ObservationIgnored
    var onSave: (([Project]) -> Void)?
    /// Called with each project that `add` stored. `AppState.projectAdded`
    /// gives it its first tab, so a project has tabs from the moment it is
    /// added, whichever path added it.
    @ObservationIgnored
    var onAdd: ((Project) -> Void)?

    init(writer: ModelWriter) {
        self.writer = writer
        writer.mirror.onProjectsChanged = { [weak self] in
            guard let self else { return }
            onSave?(projects)
        }
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
    func findOrCreate(name: String, path: String) -> Project? {
        if let existing = project(matchingPath: path) {
            return existing
        }
        return create(name: name, path: path)
    }

    /// Always add a new project, even when one already backs this directory.
    /// A directory is not an identity: two projects may share a `path` and
    /// keep wholly independent tabs (keyed on `Project.id`) and sessions
    /// (named with per-pane entropy). This is the entry point for
    /// user-initiated creation (folder picker, remote sheet, `project create`).
    ///
    /// A name that `Project.nameRefusal` refuses is stored changed (see
    /// `allowedName`). Most callers pass the folder's own name — the
    /// picker, Finder, Open With, the palette, a bare `project create` — which
    /// nobody chose, so refusing it would make a folder called Pinned
    /// impossible to add. The `name:` of a layout file is changed the same
    /// way. A caller holding a name someone typed refuses it before calling
    /// this, where it can say why. nil when the server refused it.
    @discardableResult
    func create(name: String, path: String, parent: UUID? = nil) -> Project? {
        var project = Project(name: Self.allowedName(name), path: path, parent: parent)
        if autoAssignsColors() {
            project.colorName = ProjectColor.leastUsed(among: projects.map(\.color)).rawValue
        }
        return add(project)
    }

    /// Add a project at the end of its parent, and return it as stored. A
    /// parent that is not a project of the tree becomes nil (top level).
    @discardableResult
    func add(_ project: Project) -> Project? {
        var project = project
        project.path = ProjectPath.normalizedForStorage(project.path)
        if !isPlace(project.parent) { project.parent = nil }
        guard writer.projectCreate(project), let stored = mirror.project(project.id) else { return nil }
        onAdd?(stored)
        return stored
    }

    // MARK: - Tree

    /// The projects whose parent is `parent` (nil: the top level), in
    /// `sortOrder`.
    func children(of parent: UUID?) -> [Project] {
        rows.filter { $0.parent == parent }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Move a project into the project `parent` (nil: the top level), at its
    /// end. A project that is already in `parent` does not move. Returns
    /// false when `parent` is not a project of the tree, or is the project
    /// itself or a project inside it.
    @discardableResult
    func move(_ id: UUID, into parent: UUID?) -> Bool {
        guard let project = row(id), isPlace(parent) else { return false }
        if let parent, parent == id || ancestors(of: parent).contains(id) { return false }
        guard project.parent != parent else { return true }
        let oldParent = project.parent
        guard writer.projectSet(id, parent: .some(parent)) else { return false }
        // The server keeps the order number: put the project at the end, and
        // number the rows that it left from 0 again.
        writer.projectReorder(parent: parent, ids: children(of: parent).map(\.id).filter { $0 != id } + [id])
        let left = children(of: oldParent).map(\.id)
        if !left.isEmpty { writer.projectReorder(parent: oldParent, ids: left) }
        return true
    }

    /// Put the rows of `parent` in the order of `ids`. An id that is not a
    /// row of `parent` is ignored. A row of `parent` that `ids` does not
    /// name keeps its order after the named ones.
    func reorder(parent: UUID?, ids: [UUID]) {
        let siblings = children(of: parent).map(\.id)
        var order = ids.filter(siblings.contains)
        order = order.enumerated().filter { order.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        order += siblings.filter { !order.contains($0) }
        guard order != siblings else { return }
        writer.projectReorder(parent: parent, ids: order)
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
        guard move(id, into: grandparent) else { return }
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

    /// Whether `id` is nil (the top level) or a project of the tree: the two
    /// places a project can be.
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
        guard row(id) != nil else { return }
        writer.projectSet(id, name: newName)
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
        guard let project = row(id), project.colorName != color?.rawValue else { return }
        writer.projectSet(id, color: color?.rawValue ?? "")
    }

    /// Point the project at another folder.
    func setPath(id: UUID, to newPath: String) {
        let normalized = ProjectPath.normalizedForStorage(newPath)
        guard let project = row(id), project.path != normalized else { return }
        writer.projectSet(id, path: normalized)
    }

    private func treeOrder(under parent: UUID?) -> [Project] {
        children(of: parent).flatMap { [$0] + treeOrder(under: $0.id) }
    }

    // MARK: - v1's projects.json

    /// The rows of v1's `projects.json`, for the import (design/010 §8):
    /// each path normalized, each parent that is not a row (or that makes a
    /// loop) read as the top level. `failed` when a file is there and does
    /// not read: then nothing is imported. The import never writes the file.
    static func readV1(fileURL: URL = FileStorage.fileURL(filename: "projects.json")) -> (rows: [Project], failed: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], false) }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return ([], false) }
            var rows = try JSONDecoder().decode([Project].self, from: data)
            let ids = Set(rows.map(\.id))
            for i in rows.indices {
                rows[i].path = ProjectPath.normalizedForStorage(rows[i].path)
                if let parent = rows[i].parent, !ids.contains(parent) || parent == rows[i].id { rows[i].parent = nil }
            }
            // A loop of parents reads as the top level.
            for i in rows.indices {
                var seen: Set<UUID> = [rows[i].id]
                var next = rows[i].parent
                while let current = next {
                    if !seen.insert(current).inserted {
                        rows[i].parent = nil
                        break
                    }
                    next = rows.first { $0.id == current }?.parent
                }
            }
            return (rows, false)
        } catch {
            logger.error("Failed to read projects.json: \(String(describing: error), privacy: .public)")
            return ([], true)
        }
    }
}
