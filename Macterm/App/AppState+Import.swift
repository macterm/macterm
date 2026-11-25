import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "Import")

/// The import of v1's files into the model (design/010 §8): one time, at
/// the first launch whose server has a model with no `imported_v1`. The app
/// converts (`ModelConversion`), and the server validates and stores. The
/// v1 files are never written: a return to an earlier build finds them as
/// they were at the cut-over. Migration code: 0228 removes it.
extension AppState {
    func importV1Files() {
        let (rows, projectsFailed) = ProjectStore.readV1()
        let loaded = workspaceStore.load()
        guard !projectsFailed, !workspaceStore.loadFailed else {
            // Nothing is written over a file that did not read. The flag
            // stays false, so the next launch tries again.
            logger.error("import: a v1 file did not read; nothing imported")
            presentToast(
                String(localized: "Macterm could not read the projects of an earlier version"),
                subtitle: String(localized: "Macterm tries again at the next start.")
            )
            return
        }
        let projects = ModelConversion.namesWithoutSlash(rows)
        // One pane is one session, across every section.
        let valid = Set(projects.map(\.id)).union([ModelConversion.V1.scratchID])
        let clean = WorkspaceSerializer.withoutRepeatedSessions(loaded, validIDs: valid)

        var inputs: [ModelConversion.WorkspaceInput] = clean.workspaces.map { snapshot in
            ModelConversion.WorkspaceInput(
                id: snapshot.projectID,
                kind: snapshot.projectID == ModelConversion.V1.scratchID ? .scratch : .project,
                tabs: snapshot.tabs,
                activeTabID: snapshot.activeTabID
            )
        }
        // A project with a folder has its first tab from the start.
        let withTabs = Set(inputs.map(\.id))
        for project in projects where project.hasFolder && !withTabs.contains(project.id) {
            let tab = ModelConversion.firstTab(path: project.path)
            inputs.append(.init(id: project.id, kind: .project, tabs: [tab], activeTabID: tab.id))
        }
        let pinnedLive = clean.pinned.compactMap { $0.live }
        if !clean.pinned.isEmpty {
            inputs.append(.init(
                id: ModelConversion.V1.pinnedID,
                kind: .pinned,
                tabs: pinnedLive,
                activeTabID: clean.pinnedActiveTabID
            ))
        }
        if let quick = clean.quickTerminal {
            inputs.append(.init(id: UUID(), kind: .quick, tabs: [quick], activeTabID: quick.id))
        }
        for widget in clean.desktopWidgets {
            inputs.append(.init(id: widget.id, kind: .widget, tabs: widget.tab.map { [$0] } ?? [], activeTabID: widget.tab?.id))
        }
        let data = ModelConversion.model(projects: projects, workspaces: inputs, activeProjectID: Preferences.shared.activeProjectID)

        // What only a window needs goes to `gui-state.json`, before the
        // model: the restore reads both.
        if guiStateStore.load() == nil, !guiStateStore.loadFailed {
            guiStateStore.save(GUIStateFile(
                version: GUIStateStore.currentVersion,
                windows: clean.windows.isEmpty ? nil : clean.windows,
                pinned: clean.pinned.map { PinnedRecordState(id: $0.id, declaration: $0.declaration, originProjectID: $0.originProjectID) },
                desktopWidgets: clean.desktopWidgets.map(DesktopWidgetState.init)
            ))
        }
        let source = FileManager.default.fileExists(atPath: FileStorage.fileURL(filename: "workspaces_v3.json").path)
            ? "workspaces_v3.json"
            : "none"
        if writer.modelImport(data, source: source) {
            logger.info("import: \(data.projects.count, privacy: .public) projects from \(source, privacy: .public)")
        }
    }
}

extension DesktopWidgetState {
    /// A widget of v1's snapshot, without its tab.
    init(_ snapshot: DesktopWidgetSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            columns: snapshot.columns,
            rows: snapshot.rows,
            topLeftX: snapshot.topLeftX,
            topLeftY: snapshot.topLeftY,
            command: snapshot.command,
            cwd: snapshot.cwd,
            placements: snapshot.placements
        )
    }
}
