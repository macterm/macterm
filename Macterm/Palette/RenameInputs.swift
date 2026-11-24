import Foundation

/// The input screens of Rename Current Tab and Rename Current Project
/// (`AppCommand.renameTab`, `.renameProject`). The user types the name in
/// the palette. The inline rename of a sidebar row (a double-click, the
/// context menu) stays as it is.
extension PaletteInput {
    /// Rename the tab `tabID` of the workspace `workspaceID`. The field
    /// starts on the name the sidebar shows. An empty commit gives back the
    /// automatic name, as the inline rename does. A commit of the automatic
    /// name, unchanged, keeps the tab automatic: the name then follows the
    /// panes as before.
    @MainActor
    static func renameTab(_ tabID: UUID, in workspaceID: UUID, appState: AppState) -> PaletteInput? {
        guard let tab = appState.workspaces[workspaceID]?.tabs.first(where: { $0.id == tabID }) else { return nil }
        let original = tab.customTitle
        let initial = tab.sidebarTitle
        return PaletteInput(
            id: "rename-tab:\(tabID.uuidString)",
            pill: PalettePill(title: AppCommand.renameTab.title, icon: "pencil"),
            prompt: String(localized: "Tab name", comment: "Placeholder of the Rename Tab field in the palette"),
            initialValue: initial
        ) { text in
            let name = text.trimmingCharacters(in: .whitespaces)
            let title: String? = name.isEmpty || (original == nil && name == initial) ? nil : name
            guard title != original,
                  let tab = appState.workspaces[workspaceID]?.tabs.first(where: { $0.id == tabID })
            else { return .done }
            ModelWriter.tabSet(tab, title: title)
            appState.saveWorkspaces()
            return .done
        }
    }

    /// Rename the project `projectID`. The field starts on its name. An
    /// empty commit changes nothing, as the inline rename does. A name that
    /// a project may not have is refused, and the screen says why.
    @MainActor
    static func renameProject(_ projectID: UUID, store: ProjectStore) -> PaletteInput? {
        guard let project = store.projects.first(where: { $0.id == projectID }) else { return nil }
        return PaletteInput(
            id: "rename-project:\(projectID.uuidString)",
            pill: PalettePill(title: AppCommand.renameProject.title, icon: "pencil"),
            prompt: String(localized: "Project name", comment: "Placeholder of the Rename Project field in the palette"),
            initialValue: project.name
        ) { text in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .done }
            // The one check of a project name in this screen.
            if let refusal = Project.reservedNameMessage(for: name) { return .refused(refusal) }
            store.rename(id: projectID, to: name)
            return .done
        }
    }
}
