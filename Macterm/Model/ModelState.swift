import Foundation

/// The shared model in one place: the project list and the workspaces of
/// tabs. After the model cut-over (design 010) the `ModelMirror` of the
/// server's model replaces this object as one unit, so code that reads the
/// model reaches it through here and not through stores of its own.
///
/// It holds no window state, no view and no runtime state of a session.
@MainActor @Observable
final class ModelState {
    /// The project list (`projects.json`). The scene owns the store and
    /// attaches it at launch; nil before that and in tests that need none.
    weak var projects: ProjectStore?

    /// The tabs of each workspace, by workspace id.
    var workspaces: [WorkspaceID: Workspace] = [:]
}
