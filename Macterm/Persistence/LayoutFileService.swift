import Foundation

/// The project layout files in `~/.config/macterm/projects/`: find, read and
/// write them, and tell what a save collided with. It reads and writes files
/// only. Applying a layout to a workspace and the dialogs stay in `AppState`,
/// so this service survives the model cut-over unchanged.
@MainActor @Observable
final class LayoutFileService {
    let projectFiles: ProjectFileStore

    /// Bumped whenever the app itself writes a project file, so an open
    /// Projects settings pane can re-read the directory. There's no file
    /// watcher by design (hand-edits surface on next use); this covers only
    /// the changes Macterm makes, which the user does expect to see land.
    private(set) var version = 0

    init(projectFiles: ProjectFileStore) {
        self.projectFiles = projectFiles
    }

    func noteChanged() {
        version &+= 1
    }

    /// The layout that `project`'s file declares. Throws when no file matches
    /// the project's path, when the file does not parse, and when it declares
    /// no tabs: an empty declaration must never plan "close every tab".
    /// Throws for a project with no folder.
    func layout(for project: Project) throws -> LayoutFile {
        guard project.hasFolder else { throw LayoutFileError.noFolder }
        guard let file = try projectFiles.loadFull(
            forProjectPath: project.path,
            preferredSlug: ProjectSlug.slug(from: project.name)
        )
        else {
            throw LayoutFileError.noProjectFile(projectPath: project.path)
        }
        guard let layout = file.layoutFile else { throw LayoutFileError.noTabs }
        return layout
    }

    /// What a save found next to the file it wrote.
    enum SaveConflict: Equatable {
        /// Other files declare the project's path, and Macterm ignores them.
        /// The names are the file names, in quotes.
        case strayFiles(names: String)
        /// Projects in the same folder with the same name slug share the file
        /// that the save wrote. The names are the project names, in quotes.
        case sharedFile(projects: String)
    }

    struct SaveResult {
        let target: URL
        let conflict: SaveConflict?
    }

    /// Write `layout` as `project`'s file. Creates the file when none declares
    /// this path yet; realigns the filename to the current name slug when it
    /// drifted. `siblingProjects` is the full project list, used only to leave
    /// the files of other projects in the same folder alone and to find the
    /// conflicts.
    /// Throws for a project with no folder: no file can match it.
    func save(_ layout: LayoutFile, for project: Project, siblingProjects: [Project]) throws -> SaveResult {
        guard project.hasFolder else { throw LayoutFileError.noFolder }
        // Reserve the *other* same-directory projects' files so the save leaves
        // them alone. Drop our own slug: a same-*name* sibling shares our slug
        // and thus our file (last save wins — flagged below), so it must not
        // reserve that file away from us.
        let ownSlug = ProjectSlug.slug(from: project.name)
        let reservedSlugs = sameDirectorySiblingSlugs(of: project, in: siblingProjects).subtracting([ownSlug])
        let target = try projectFiles.write(
            ProjectFile(name: project.name, path: project.path, tabs: layout.tabs),
            projectName: project.name,
            reservedSlugs: reservedSlugs
        )
        noteChanged()
        // A stray-*file* conflict (an unrelated file declares this path)
        // takes priority over the shared-*project* notice.
        let conflict = strayFiles(of: project, savedTo: target, siblingProjects: siblingProjects)
            ?? sharedFile(of: project, siblingProjects: siblingProjects)
        return SaveResult(target: target, conflict: conflict)
    }

    /// Slugs of the *other* projects that back `project`'s directory — the
    /// layout files that are theirs, not this project's. Lets a save leave a
    /// sibling's file alone, and tells a sibling's legitimate file apart from a
    /// stray duplicate.
    private func sameDirectorySiblingSlugs(of project: Project, in siblingProjects: [Project]) -> Set<String> {
        Set(
            siblingProjects
                .filter { $0.id != project.id && ProjectPath.matches($0.path, project.path) }
                .map { ProjectSlug.slug(from: $0.name) }
        )
    }

    /// The *stray* files that declare the same path — ones that are neither
    /// this project's own file nor a sibling project's. The slug-preferring
    /// lookup ignores such strays (a hand-authored copy, or an old file whose
    /// realign-delete failed), so a save warns they exist rather than let
    /// them rot silently.
    private func strayFiles(of project: Project, savedTo target: URL, siblingProjects: [Project]) -> SaveConflict? {
        let siblingSlugs = sameDirectorySiblingSlugs(of: project, in: siblingProjects)
        let strays = projectFiles.matches(forProjectPath: project.path).filter { file in
            let name = file.url.lastPathComponent
            // The file we just wrote is not in conflict with itself, and a
            // sibling project's own file is expected, not a stray.
            guard name != target.lastPathComponent else { return false }
            return !siblingSlugs.contains { ProjectSlug.owns(filename: name, slug: $0) }
        }
        guard !strays.isEmpty else { return nil }
        return .strayFiles(names: strays.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", "))
    }

    /// A directory can back several projects, and a project's layout file is
    /// keyed by path **and** name-slug — so a same-path project whose name
    /// yields the *same* slug writes to the very file this save just wrote, and
    /// the last save silently wins. Flag exactly that pair: same canonical path
    /// AND same slug. Same path but distinct names is fine — those resolve to
    /// distinct slug files (`api.yaml` / `api-staging.yaml`) that load
    /// independently and never overwrite each other.
    private func sharedFile(of project: Project, siblingProjects: [Project]) -> SaveConflict? {
        let slug = ProjectSlug.slug(from: project.name)
        let colliding = siblingProjects.filter {
            $0.id != project.id
                && ProjectPath.matches($0.path, project.path)
                && ProjectSlug.slug(from: $0.name) == slug
        }
        guard !colliding.isEmpty else { return nil }
        return .sharedFile(projects: colliding.map { "“\($0.name)”" }.joined(separator: ", "))
    }
}
