import AppKit
import SwiftUI

/// Projects settings: the runtime project list and the layout files on disk,
/// each manageable without touching a file or the CLI.
///
/// The two lists are deliberately separate because the model is: `projects.json`
/// owns which projects exist, and `~/.config/macterm/projects/*.yaml` owns their
/// declared layouts — matched by path, not identity. A layout file can exist
/// with no project backing it (hand-authored, or left behind by a removed
/// project); those orphans are invisible anywhere else in the UI, so the
/// Layouts list shows every file and offers to turn one into a project.
struct ProjectsSettings: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    /// Layout files, re-read on appear and after every mutation. There's no
    /// file watcher anywhere in the app by design (hand-edits surface on next
    /// use), so this mirrors that: a snapshot, refreshed at the points where
    /// the user can expect it to change.
    @State private var layouts: [ProjectFileStore.Listing] = []
    @State private var layoutPendingDeletion: ProjectFileStore.Listing?
    @State private var deleteFailure: String?
    /// The layout whose Create Project checks its remote folder now.
    @State private var checkingLayout: URL?
    /// The check of `checkingLayout`. Settings closes: it stops.
    @State private var folderCheck: Task<Void, Never>?
    /// Why Create Project added nothing.
    @State private var createFailure: String?

    var body: some View {
        Form {
            Section {
                SettingsInfoPanel(
                    symbol: "folder",
                    title: String(localized: "Projects"),
                    caption: String(
                        localized: """
                        A project is a folder, on this Mac or on a remote machine. A layout is a file that says \
                        which tabs, splits and commands a project has.
                        """
                    ),
                    docs: .layouts
                )
            }

            Section {
                if projectStore.projects.isEmpty {
                    Text("No projects.")
                        .foregroundStyle(.secondary)
                } else {
                    // Rows go straight into the section — the same shape the
                    // Keymaps pane uses. A nested `List` here needed a fixed
                    // height, which capped the pane at ~6 projects: the Form's
                    // scroll view swallows the inner one's wheel events, so
                    // anything past the cap was unreachable. Plain rows grow
                    // with the content and let the Form scroll, which is the
                    // only scroll view in the pane that works.
                    //
                    // The cost is `.onMove`, which exists only on `List`, so
                    // reordering moved into the row menu.
                    //
                    // The rows are the sidebar's tree (design 013), in tree
                    // order, with one indent step for each parent above.
                    ForEach(projectStore.projects) { project in
                        projectRow(project)
                    }
                }
                Text("Change the order in the menu of a row.")
                    .settingsSecondaryText()
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    // The same two creation paths the sidebar offers, so a
                    // project can be added without leaving Settings.
                    Menu {
                        Button("Local Folder…") { addLocalProject() }
                        Button("Remote Machine…") { addRemoteProject() }
                    } label: {
                        Label("Add Project", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a project")
                }
            }

            Section {
                if layouts.isEmpty {
                    Text("No layout files.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(layouts) { layout in
                        LayoutRow(
                            layout: layout,
                            hasProject: hasProject(for: layout),
                            isChecking: checkingLayout == layout.id,
                            canCreate: checkingLayout == nil,
                            onCreateProject: { createProject(from: layout) },
                            onRemove: { layoutPendingDeletion = layout }
                        )
                    }
                }
                LabeledContent("Folder") {
                    Button(ProjectFileStore.defaultDirectory().path(percentEncoded: false)) {
                        revealLayoutFolder()
                    }
                    .buttonStyle(.link)
                    .linkPointer()
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Text("Removing a layout deletes its file. The project stays.")
                    .settingsSecondaryText()
            } header: {
                Text("Layouts")
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadLayouts() }
        .onDisappear {
            folderCheck?.cancel()
            folderCheck = nil
            checkingLayout = nil
        }
        // Reflect a Save Layout made from this pane (or elsewhere while it's
        // open) — a save can create a file the list doesn't know about yet.
        .onChange(of: appState.layoutFilesVersion) { _, _ in reloadLayouts() }
        .alert(
            "Remove layout file?",
            isPresented: Binding(
                get: { layoutPendingDeletion != nil },
                set: { if !$0 { layoutPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { layoutPendingDeletion = nil }
                .keyboardShortcut(.cancelAction)
            Button("Remove", role: .destructive) { confirmDeletion() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("""
            Macterm deletes “\(layoutPendingDeletion?.filename ?? "")”. The projects that use it stay, \
            but they lose their saved layout.
            """)
        }
        .alert(
            "Cannot remove the layout file",
            isPresented: Binding(
                get: { deleteFailure != nil },
                set: { if !$0 { deleteFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteFailure = nil }
        } message: {
            Text(deleteFailure ?? "")
        }
        .alert(
            "Cannot create the project",
            isPresented: Binding(
                get: { createFailure != nil },
                set: { if !$0 { createFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { createFailure = nil }
        } message: {
            Text(createFailure ?? "")
        }
    }

    // MARK: - Projects

    /// One row. A function, not an inline expression: with the closures
    /// written out in the `ForEach`, the type-checker gave up on the body.
    /// Move Up and Down move a project among the rows of its parent, as
    /// the sidebar's menu does.
    private func projectRow(_ project: Project) -> some View {
        let position = projectStore.siblingPosition(of: project.id)
        return ProjectRow(
            project: project,
            canMoveUp: (position?.index ?? 0) > 0,
            canMoveDown: position.map { $0.index < $0.count - 1 } ?? false,
            onMoveUp: { projectStore.moveAmongSiblings(project.id, by: -1) },
            onMoveDown: { projectStore.moveAmongSiblings(project.id, by: 1) }
        )
        .padding(.leading, CGFloat(projectStore.ancestors(of: project.id).count) * Self.indent)
    }

    /// The indent of a project row for each parent above it: the width of
    /// the row's glyph and the gap after it, so a child's glyph is under
    /// its parent's name.
    private static let indent: CGFloat = 24

    /// Folder picker → new project → select it, the same as Select in Finder
    /// on the New Project screen. Picking a directory that already backs a project makes
    /// a second, independent one (a directory is not an identity).
    private func addLocalProject() {
        appState.newProjectFromFolderPanel(store: projectStore)
    }

    /// The remote sheet is attached to `MainWindow`, so it would open behind the
    /// settings window. Front the terminal window first — the sheet is where the
    /// host/dir get entered, and it has to be visible to be filled in.
    private func addRemoteProject() {
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            guard window.contentViewController != nil, window.canBecomeMain else { continue }
            window.makeKeyAndOrderFront(nil)
            break
        }
        appState.isNewRemoteProjectSheetPresented = true
    }

    // MARK: - Layouts

    private func reloadLayouts() {
        layouts = appState.projectFiles.listAll()
    }

    /// Whether some project in the list already backs this file's declared
    /// path. Drives the muted "Create Project" affordance: creating a second
    /// project for a path is legal (a directory is not an identity), but for a
    /// file that already has one it's rarely what's wanted, so it's labeled.
    private func hasProject(for layout: ProjectFileStore.Listing) -> Bool {
        guard let declared = layout.declaredPath else { return false }
        return projectStore.projects.contains { ProjectPath.matches($0.path, declared) }
    }

    /// Add a project for this file's declaration and select it. The new
    /// project opens with the default workspace. The file's layout takes
    /// effect through Apply Layout (the row menu beside it), never on
    /// selection. A remote path gets the folder check of New Remote Project
    /// first (`RemoteHosts.refusal`, 0366). A refusal shows in an alert and
    /// adds nothing. One check runs at a time. Settings closes: the check
    /// stops and adds nothing.
    private func createProject(from layout: ProjectFileStore.Listing) {
        guard folderCheck == nil, let path = layout.declaredPath else { return }
        guard ProjectPath.isRemote(path) else {
            appState.selectProject(Self.addProject(from: layout, path: path, in: projectStore))
            return
        }
        checkingLayout = layout.id
        folderCheck = Task {
            let outcome = await Self.createProject(from: layout, in: projectStore)
            // `onDisappear` cleared the state, and a new check can own it now.
            guard !Task.isCancelled else { return }
            checkingLayout = nil
            folderCheck = nil
            switch outcome {
            case let .created(project): appState.selectProject(project)
            case let .refused(line): createFailure = line
            case .noPath,
                 .cancelled: break
            }
        }
    }

    /// What `createProject(from:in:refusal:)` did.
    enum CreateOutcome: Equatable {
        case created(Project)
        /// The line that says why nothing is added.
        case refused(String)
        /// The file declares no path.
        case noPath
        /// The task stopped during the check.
        case cancelled
    }

    /// Create Project without the view. `refusal` gives nil when Macterm can
    /// add the path. Tests answer it.
    static func createProject(
        from layout: ProjectFileStore.Listing,
        in store: ProjectStore,
        refusal: @MainActor (String) async -> String? = { await RemoteHosts.shared.refusal(forNewProjectPath: $0) }
    ) async -> CreateOutcome {
        guard let path = layout.declaredPath else { return .noPath }
        if let line = await refusal(path) { return .refused(line) }
        guard !Task.isCancelled else { return .cancelled }
        return .created(addProject(from: layout, path: path, in: store))
    }

    private static func addProject(from layout: ProjectFileStore.Listing, path: String, in store: ProjectStore) -> Project? {
        // `name:` is optional in a project file; fall back to the filename,
        // which is the slug of a name Macterm itself wrote.
        let declared = layout.declaredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (declared?.isEmpty == false ? declared : nil)
            ?? layout.url.deletingPathExtension().lastPathComponent
        return store.create(name: name, path: path)
    }

    private func confirmDeletion() {
        guard let target = layoutPendingDeletion else { return }
        layoutPendingDeletion = nil
        do {
            try appState.projectFiles.delete(at: target.url)
        } catch {
            deleteFailure = error.localizedDescription
        }
        reloadLayouts()
    }

    private func revealLayoutFolder() {
        let dir = ProjectFileStore.defaultDirectory()
        // The directory is created lazily on the first save, so a reveal before
        // then would silently do nothing.
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path(percentEncoded: false))
    }
}

// MARK: - Project row

/// One project: its name, path, load state, and its actions. Actions live in a
/// menu rather than a row of buttons — six projects × six buttons is a wall of
/// chrome, and the menu is what the sidebar's context menu already is.
private struct ProjectRow: View {
    let project: Project
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    /// The project's ssh destination, when the user declined the server
    /// there.
    private var declinedDestination: String? {
        guard case let .remote(user, host, _) = ProjectPath.remote(from: project.path) else { return nil }
        let destination = HostCommands.destination(user: user, host: host)
        return RemoteHosts.shared.declined.contains(destination) ? destination : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            // `AnyShapeStyle` because the two arms are different style types
            // (a concrete `Color` and the hierarchical `.secondary`), which a
            // `??` can't reconcile on its own.
            Image(systemName: project.isRemote ? "network" : "folder")
                .foregroundStyle(project.color.map { AnyShapeStyle(MactermTheme.color(for: $0)) } ?? AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                if project.hasFolder {
                    Text(project.path)
                        .settingsSecondaryText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Menu {
                // Every mutation here stages its dialogs on this window
                // (`host: .settings`), so the main window's copies stay quiet —
                // see `AppState.DialogHost`.
                Button("Apply Layout") {
                    appState.applyLayoutPresentingError(project, host: .settings)
                }
                .disabled(!canApplyLayout)

                Button("Save Layout") {
                    appState.saveLayoutPresentingError(
                        project,
                        siblingProjects: projectStore.projects,
                        host: .settings
                    )
                    appState.noteLayoutFilesChanged()
                }
                // A layout file matches a project by its folder.
                .disabled(appState.workspaces[project.id] == nil || !project.hasFolder)

                // A project from a dev build's group row has no folder
                // (design 013 §1): its shells start in the home folder
                // until the user chooses one here.
                if !project.hasFolder {
                    Button("Select Folder…") { selectFolder() }
                }

                // Only after the user declined the server on this host: its
                // panes are plain ssh shells until then (0057).
                if let destination = declinedDestination {
                    Divider()

                    Button("Install Server on Host…") {
                        appState.installRemoteServer(on: destination)
                    }
                }

                Divider()

                ProjectColorMenu(selection: project.color) { color in
                    projectStore.setColor(id: project.id, to: color)
                }

                Divider()

                Button("Move Up") { onMoveUp() }
                    .disabled(!canMoveUp)

                Button("Move Down") { onMoveDown() }
                    .disabled(!canMoveDown)

                Divider()

                Button("Remove", role: .destructive) {
                    appState.requestRemoveProject(project.id, store: projectStore, host: .settings)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    /// Give a project with no folder the folder that the user selects.
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a project folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectStore.setPath(id: project.id, to: url.path(percentEncoded: false))
    }

    /// Mirrors the palette's muted state: a file that declares no tabs has
    /// nothing to apply, while an unparseable one stays enabled so invoking it
    /// surfaces the parse error instead of silently doing nothing.
    private var canApplyLayout: Bool {
        switch appState.projectFiles.applyState(
            forProjectPath: project.path,
            preferredSlug: ProjectSlug.slug(from: project.name)
        ) {
        case .applicable,
             .invalid: true
        case .none,
             .emptyTabs: false
        }
    }
}

// MARK: - Layout row

private struct LayoutRow: View {
    let layout: ProjectFileStore.Listing
    let hasProject: Bool
    /// Create Project of this row checks the remote folder now. The row
    /// shows a spinner.
    let isChecking: Bool
    /// No check runs. Create Project is off in every row during a check.
    let canCreate: Bool
    let onCreateProject: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: layout.isInvalid ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(layout.isInvalid ? AnyShapeStyle(MactermTheme.warning) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(layout.filename)
                Text(subtitle)
                    .settingsSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ProgressView()
                .controlSize(.small)
                .opacity(isChecking ? 1 : 0)
                .accessibilityHidden(!isChecking)

            Menu {
                Button(hasProject ? "Create Another Project" : "Create Project") { onCreateProject() }
                    .disabled(layout.declaredPath == nil || !canCreate)
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if layout.isInvalid {
            return String(localized: "Invalid file. Fix it in an editor to use it.")
        }
        guard let path = layout.declaredPath else {
            return String(localized: "No path declared.")
        }
        return switch layout.tabCount {
        case 0: String(localized: "\(path) — no tabs", comment: "Settings → Layouts: a layout file's path and tab count")
        case 1: String(localized: "\(path) — 1 tab", comment: "Settings → Layouts: a layout file's path and tab count")
        default: String(localized: "\(path) — \(layout.tabCount) tabs", comment: "Settings → Layouts: a layout file's path and tab count")
        }
    }
}
