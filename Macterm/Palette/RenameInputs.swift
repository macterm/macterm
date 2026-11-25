import Foundation

/// The input screens of Rename Current Tab and Rename Current Project
/// (`AppCommand.renameTab`, `.renameProject`). The user types the name in
/// the palette, and the one action row `Rename to "<name>"` sets it. The
/// inline rename of a sidebar row (a double-click, the context menu) stays
/// as it is.
extension PaletteInput {
    /// Rename the tab `tabID` of the workspace `workspaceID`. The field
    /// starts on the name that the sidebar shows.
    /// - A new name has the action row `Rename to "<name>"`.
    /// - The current name has no row. Thus a tab with an automatic name
    ///   stays automatic.
    /// - An empty field on a renamed tab has the row
    ///   `Use the automatic name "<name>"`, as an empty inline rename does.
    /// - A tab that closed has no row.
    @MainActor
    static func renameTab(_ tabID: UUID, in workspaceID: UUID, appState: AppState) -> PaletteInput? {
        let find = { appState.model.tabs(of: workspaceID).first(where: { $0.id == tabID }) }
        guard let tab = find() else { return nil }
        return PaletteInput(
            id: "rename-tab:\(tabID.uuidString)",
            title: AppCommand.renameTab.title,
            prompt: String(localized: "Tab name", comment: "Placeholder of the Rename Tab field in the palette"),
            initialValue: tab.sidebarTitle
        ) { text, _ in
            guard let tab = find() else { return .nothing }
            let name = text.trimmingCharacters(in: .whitespaces)
            let title: String?
            let rowTitle: String
            if name.isEmpty {
                guard tab.customTitle != nil else { return .nothing }
                title = nil
                rowTitle = String(
                    localized: "Use the automatic name \"\(tab.autoTitle)\"",
                    comment: "The action row of the Rename Tab field in the palette when the field is empty"
                )
            } else {
                guard name != tab.sidebarTitle else { return .nothing }
                title = name
                rowTitle = renameActionTitle(name)
            }
            return .action(PaletteInputAction(title: rowTitle) {
                if let tab = find() { appState.setTabTitle(tab, title: title) }
                return .done
            })
        }
    }

    /// Rename the project `projectID`. The field starts on its name.
    /// - A new name has the action row `Rename to "<name>"`.
    /// - An empty field and the current name have no row.
    /// - A name that `Project.nameRefusal` refuses shows the reason and no
    ///   row. The action checks the name again when it runs.
    @MainActor
    static func renameProject(_ projectID: UUID, appState: AppState, store: ProjectStore) -> PaletteInput? {
        let find = { store.projects.first(where: { $0.id == projectID }) }
        guard let project = find() else { return nil }
        return PaletteInput(
            id: "rename-project:\(projectID.uuidString)",
            title: AppCommand.renameProject.title,
            prompt: String(localized: "Project name", comment: "Placeholder of the Rename Project field in the palette"),
            initialValue: project.name
        ) { text, _ in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard let project = find(), !name.isEmpty, name != project.name else { return .nothing }
            if let refusal = Project.nameRefusal(for: name) { return .notice(refusal) }
            return .action(PaletteInputAction(title: renameActionTitle(name)) {
                if let refusal = appState.applyProjectRename(projectID, to: name, store: store) { return .refused(refusal) }
                return .done
            })
        }
    }

    /// The title of the action row that renames a tab or a project to `name`.
    private static func renameActionTitle(_ name: String) -> String {
        String(
            localized: "Rename to \"\(name)\"",
            comment: "The action row of the Rename Tab and Rename Project fields in the palette"
        )
    }
}
