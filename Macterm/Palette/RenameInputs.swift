import Foundation

/// The input screens of Rename Current Tab and Rename Current Project
/// (`AppCommand.renameTab`, `.renameProject`). The user types the name in
/// the palette. The inline rename of a sidebar row (a double-click, the
/// context menu) stays as it is.
extension PaletteInput {
    /// Rename the tab `tabID` of the workspace `workspaceID`. The field
    /// starts on the name the sidebar shows. An empty commit gives back the
    /// automatic name, as the inline rename does. A commit of the automatic
    /// name, unchanged, keeps the tab automatic, so that the name continues
    /// to follow the panes.
    @MainActor
    static func renameTab(_ tabID: UUID, in workspaceID: UUID, appState: AppState) -> PaletteInput? {
        guard let tab = appState.workspaces[workspaceID]?.tabs.first(where: { $0.id == tabID }) else { return nil }
        let wasAutomatic = tab.customTitle == nil
        let initial = tab.sidebarTitle
        return PaletteInput(
            id: "rename-tab:\(tabID.uuidString)",
            title: AppCommand.renameTab.title,
            prompt: String(localized: "Tab name", comment: "Placeholder of the Rename Tab field in the palette"),
            initialValue: initial
        ) { text in
            let name = text.trimmingCharacters(in: .whitespaces)
            let title: String? = name.isEmpty || (wasAutomatic && name == initial) ? nil : name
            guard let tab = appState.workspaces[workspaceID]?.tabs.first(where: { $0.id == tabID }),
                  title != tab.customTitle
            else { return .done }
            appState.setTabTitle(tab, title: title)
            return .done
        }
    }

    /// Rename the project `projectID`. The field starts on its name. An
    /// empty commit changes nothing, as the inline rename does. A name that
    /// a project may not have is refused, and the screen says why.
    @MainActor
    static func renameProject(_ projectID: UUID, appState: AppState, store: ProjectStore) -> PaletteInput? {
        guard let project = store.projects.first(where: { $0.id == projectID }) else { return nil }
        return PaletteInput(
            id: "rename-project:\(projectID.uuidString)",
            title: AppCommand.renameProject.title,
            prompt: String(localized: "Project name", comment: "Placeholder of the Rename Project field in the palette"),
            initialValue: project.name
        ) { text in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .done }
            if let refusal = appState.applyProjectRename(projectID, to: name, store: store) { return .refused(refusal) }
            return .done
        }
    }
}
