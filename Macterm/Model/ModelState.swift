import Foundation

/// The shared tab model in one value: the workspaces of tabs. After the
/// model cut-over (design 010) the `ModelMirror` of the server's model
/// replaces this object as one unit (`AppState.model`). The project list
/// joins it then: until the cut-over removes the `ProjectStore` writers, the
/// scene owns that store and hands it to the views.
///
/// It holds no window state, no view and no runtime state of a session.
@MainActor @Observable
final class ModelState {
    /// The tabs of each workspace, by workspace id.
    var workspaces: [WorkspaceID: Workspace] = [:]
}
