import AppIntents
import AppKit
import Foundation
@testable import Macterm
import Testing

/// The intents' `perform()` paths, driven against injected stores the way
/// `ControlHandlerTests` drives the CLI's handler.
///
/// Serialized as a suite: `MactermIntentHost.shared` and
/// `IntentPermissionGate.shared` are singletons (App Intents are instantiated
/// by the system, so they cannot be handed anything), and swift-testing runs
/// suites in parallel. Panes here never build a surface — there is no window —
/// so every action that needs one asserts the `noSurface` contract instead.
@Suite(.serialized)
@MainActor
struct MactermIntentsTests {
    // MARK: - Fixtures

    private func makeAppState() -> AppState {
        TestModel.appState()
    }

    private func makeProjectStore(_ appState: AppState) -> ProjectStore {
        let store = TestModel.projectStore(appState)
        store.onAdd = { [weak appState] in appState?.projectAdded($0) }
        return store
    }

    /// Attach the host and open the permission gate — the state a running app
    /// is in once `installResponders` has run and the user has allowed.
    private func makeHost() -> (AppState, ProjectStore) {
        let appState = makeAppState()
        let projectStore = makeProjectStore(appState)
        MactermIntentHost.shared.attachForTesting(appState: appState, projectStore: projectStore)
        IntentPermissionGate.shared.resetForTesting()
        IntentPermissionGate.shared.access = { .allow }
        return (appState, projectStore)
    }

    private func teardown() {
        IntentPermissionGate.shared.resetForTesting()
    }

    private func seedProject(
        _ appState: AppState,
        _ projectStore: ProjectStore,
        name: String = "demo",
        path: String = "/tmp"
    ) -> Project {
        guard let project = projectStore.add(Project(name: name, path: path)) else {
            preconditionFailure("the test server refused the project")
        }
        appState.selectProject(project)
        return project
    }

    /// A delegate shaped like the one `MainWindow.onAppear` leaves behind, with
    /// no real windows so nothing on the developer's screen is touched.
    ///
    /// The caller must hold the return value: `AppState.appDelegate` is weak
    /// (in production the delegate is owned by
    /// `@NSApplicationDelegateAdaptor`), so a discarded one deallocates
    /// immediately and the intent reports `.appUnavailable`.
    private func attachDelegate(_ appState: AppState, _ projectStore: ProjectStore) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.appState = appState
        delegate.projectStore = projectStore
        delegate.windowLister = { [] }
        delegate.openInitialWindow = {}
        appState.appDelegate = delegate
        return delegate
    }

    // MARK: - The permission gate is in front of every intent

    @Test
    func a_denied_intent_never_touches_the_app() async {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        _ = seedProject(appState, projectStore)
        IntentPermissionGate.shared.access = { .deny }
        let before = projectStore.projects.count

        let intent = FocusMactermProjectIntent()
        intent.project = MactermProjectEntity(projectStore.projects[0])

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
        #expect(projectStore.projects.count == before)
    }

    // MARK: - Projects

    @Test
    func new_project_creates_and_selects_it() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-new-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let intent = NewMactermProjectIntent()
        intent.folder = IntentFile(fileURL: dir)
        _ = try await intent.perform()

        #expect(projectStore.projects.count == 1)
        // The folder's own basename, like the picker and `project create` —
        // never a friendlier invented name.
        #expect(projectStore.projects[0].name == dir.lastPathComponent)
        #expect(appState.activeProjectID == projectStore.projects[0].id)
    }

    @Test
    func new_project_takes_an_explicit_name_over_the_folder_basename() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-named-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let intent = NewMactermProjectIntent()
        intent.folder = IntentFile(fileURL: dir)
        intent.name = "  API  "
        _ = try await intent.perform()

        // Trimmed, because a stray space in a Shortcuts text field is invisible.
        #expect(projectStore.projects[0].name == "API")
        #expect(appState.activeProjectID == projectStore.projects[0].id)
    }

    @Test
    func new_project_refuses_a_typed_reserved_name_but_suffixes_the_folders() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-pinned-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent("Pinned", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        // Typed into the action: refused, like the CLI's `--name`.
        let named = NewMactermProjectIntent()
        named.folder = IntentFile(fileURL: dir)
        named.name = " pinned "
        let refusal = await #expect(throws: MactermIntentError.self) { try await named.perform() }
        if case let .badInput(detail)? = refusal {
            #expect(detail == PinnedTabs.reservedNameMessage)
        } else {
            Issue.record("expected badInput, got \(String(describing: refusal))")
        }
        #expect(projectStore.projects.isEmpty)

        // The folder's own name, which nobody typed: suffixed, not refused.
        let unnamed = NewMactermProjectIntent()
        unnamed.folder = IntentFile(fileURL: dir)
        _ = try await unnamed.perform()
        #expect(projectStore.projects.map(\.name) == ["Pinned 2"])
        #expect(appState.activeProjectID == projectStore.projects.first?.id)
    }

    @Test
    func new_project_refuses_a_typed_name_with_a_slash() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-slash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let named = NewMactermProjectIntent()
        named.folder = IntentFile(fileURL: dir)
        named.name = "Work/api"
        let refusal = await #expect(throws: MactermIntentError.self) { try await named.perform() }
        if case let .badInput(detail)? = refusal {
            #expect(detail == Project.slashMessage)
        } else {
            Issue.record("expected badInput, got \(String(describing: refusal))")
        }
        #expect(projectStore.projects.isEmpty)
        #expect(appState.activeProjectID == nil)
    }

    @Test
    func new_project_on_a_missing_folder_is_bad_input() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-absent-\(UUID().uuidString)", isDirectory: true)

        let intent = NewMactermProjectIntent()
        intent.folder = IntentFile(fileURL: missing)

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
        #expect(projectStore.projects.isEmpty)
        #expect(appState.model.projects.isEmpty)
    }

    @Test
    func a_project_entity_naming_a_removed_project_is_not_found() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let entity = MactermProjectEntity(project)
        appState.removeProject(project.id)

        let intent = FocusMactermProjectIntent()
        intent.project = entity

        // An entity is a token, not a handle: a shortcut written weeks ago has
        // to be able to say the thing is gone.
        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func the_spotlight_open_intent_shows_the_project_like_focus_project() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let first = seedProject(appState, projectStore, name: "first")
        _ = seedProject(appState, projectStore, name: "second")

        let intent = OpenMactermProjectIntent()
        intent.target = MactermProjectEntity(first)
        _ = try await intent.perform()

        #expect(appState.activeProjectID == first.id)
    }

    @Test
    func the_spotlight_open_intent_is_behind_the_permission_gate() async {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let first = seedProject(appState, projectStore, name: "first")
        let second = seedProject(appState, projectStore, name: "second")
        IntentPermissionGate.shared.access = { .deny }

        let intent = OpenMactermProjectIntent()
        intent.target = MactermProjectEntity(first)

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
        #expect(appState.activeProjectID == second.id)
    }

    @Test
    func a_project_is_indexed_under_its_name_and_its_folder() {
        guard #available(macOS 15.0, *) else { return }
        let project = Project(name: "Website", path: "/Users/me/dev/acme-site", sortOrder: 0)
        let set = MactermProjectEntity(project).attributeSet

        #expect(set.title == "Website")
        #expect(set.contentDescription == "/Users/me/dev/acme-site")
        #expect(set.keywords == ["Website", "acme-site"])
    }

    /// Spotlight gets the tree projects only: the hidden projects of the
    /// model (Pinned, Scratch Tabs, the quick terminal, the widgets) are
    /// never in the list that `ProjectSpotlightIndex` indexes.
    @Test
    func the_spotlight_list_has_no_hidden_project() throws {
        let appState = makeAppState()
        appState.desktopScreens = { [DesktopScreen(name: "Test", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))] }
        appState.nativeDesktopWidgetFrames = { [] }
        let projectStore = makeProjectStore(appState)
        var saved: [[String]] = []
        projectStore.onSave = { saved.append($0.map(\.name)) }
        _ = try #require(appState.ensurePinnedProject())
        _ = try #require(appState.createScratchTab(focus: false))
        _ = try #require(appState.quickTerminal.ensureTab())
        _ = appState.createDesktopWidget()
        #expect(appState.model.projects.count == 4)

        _ = try #require(projectStore.create(name: "api", path: "/tmp"))

        #expect(saved == [["api"]])
        #expect(projectStore.projects.map(\.name) == ["api"])
    }

    @Test
    func a_save_hands_the_saved_list_to_the_spotlight_hook() throws {
        let appState = makeAppState()
        let projectStore = makeProjectStore(appState)
        var saved: [[String]] = []
        projectStore.onSave = { saved.append($0.map(\.name)) }

        let project = try #require(projectStore.create(name: "api", path: "/tmp"))
        projectStore.rename(id: project.id, to: "backend")
        appState.removeProject(project.id, store: projectStore)

        #expect(saved == [["api"], ["backend"], []])
    }

    @Test
    func a_test_run_never_writes_the_spotlight_index() {
        #expect(ProjectSpotlightIndex.isHermetic)
    }

    // MARK: - Tabs

    @Test
    func new_tab_lands_in_the_named_project_and_returns_it() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let before = appState.liveTabs[project.id]?.tabs.count ?? 0

        let intent = NewMactermTabIntent()
        intent.project = MactermProjectEntity(project)
        let result = try await intent.perform()

        let tabs = try #require(appState.liveTabs[project.id]?.tabs)
        #expect(tabs.count == before + 1)
        #expect(result.value?.id == tabs.last?.id)
    }

    @Test
    func new_tab_passes_the_command_through_as_spawn_time_input() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)

        let intent = NewMactermTabIntent()
        intent.project = MactermProjectEntity(project)
        intent.command = "  npm run dev  "
        _ = try await intent.perform()

        let tab = try #require(appState.liveTabs[project.id]?.tabs.last)
        let pane = try #require(tab.splitRoot.allPanes().first)
        // The command is a typed `PaneStartCommand`, the layout `run:`
        // path, not a paste — trimmed, because a trailing space in a Shortcuts
        // text field is invisible.
        #expect(pane.start == .typed("npm run dev"))
    }

    @Test
    func new_tab_with_a_blank_command_spawns_a_plain_shell() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)

        let intent = NewMactermTabIntent()
        intent.project = MactermProjectEntity(project)
        intent.command = "   "
        _ = try await intent.perform()

        let pane = try #require(appState.liveTabs[project.id]?.tabs.last?.splitRoot.allPanes().first)
        #expect(pane.start == nil)
    }

    @Test
    func focus_tab_selects_it_in_its_own_project() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        _ = appState.createTab(projectID: project.id, projects: projectStore.projects)
        let workspace = try #require(appState.liveTabs[project.id])
        let first = try #require(workspace.tabs.first)
        try appState.selectTab(#require(workspace.tabs.last).id, projectID: project.id)

        let intent = FocusMactermTabIntent()
        intent.tab = MactermTabEntity(
            first,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )
        _ = try await intent.perform()

        #expect(workspace.activeTabID == first.id)
    }

    @Test
    func close_tab_ends_it_when_nothing_is_running() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        _ = appState.createTab(projectID: project.id, projects: projectStore.projects)
        let workspace = try #require(appState.liveTabs[project.id])
        let doomed = try #require(workspace.tabs.last)
        let before = workspace.tabs.count

        let intent = CloseMactermTabIntent()
        intent.tab = MactermTabEntity(
            doomed,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )
        _ = try await intent.perform()

        #expect(workspace.tabs.count == before - 1)
        #expect(!workspace.tabs.contains { $0.id == doomed.id })
    }

    @Test
    func the_close_refusal_reads_the_same_busy_verdict_the_app_guards_on() {
        // The intent's guard is `Pane.needsConfirmClose`, i.e. this function —
        // the one every busy-close guard in the app reads (pane/tab close,
        // project unload, the CLI's `busy` error, the quit dialog). A shortcut
        // can run unattended, so a busy tab gets that typed refusal rather than
        // the confirmation dialog the UI stages, exactly like `tab close`
        // without `--force`.
        //
        // It is asserted here rather than through `perform()` because
        // `needsConfirmClose` short-circuits on a missing surface: a pane in a
        // windowless test never builds a surface and so always reads idle,
        // which is why the close test above closes instead of refusing.
        let busy = ForegroundSample(
            name: "btop",
            isIdleShell: false,
            sampledAt: Date()
        )
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: busy,
            executionState: .running,
            isRemote: false,
            confirmClose: .true,
            surfaceBusy: { true }
        ))
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: busy,
            executionState: .running,
            isRemote: false,
            confirmClose: .true,
            surfaceBusy: nil
        ))
    }

    // MARK: - Panes

    @Test
    func a_pane_entity_is_keyed_on_the_restart_stable_session_name() throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)

        let entity = MactermPaneEntity(pane, projectID: project.id, in: ctx)

        // NOT `pane.id`: pane UUIDs are fresh on every restore, so a shortcut
        // keyed on one would break silently at the first relaunch.
        #expect(entity.id == pane.sessionName)
        #expect(entity.id != pane.id.uuidString)
        #expect(try IntentTargets.pane(session: entity.id, in: ctx).pane === pane)
    }

    @Test
    func a_workspace_panes_view_names_its_pane_entity_for_siri() throws {
        guard #available(macOS 15.4, *) else { return }
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)
        let view = NSView()

        MactermPaneEntity.annotate(view, for: pane, addressable: true)

        let identifier = try #require(view.appEntityIdentifier)
        #expect(identifier == MactermPaneEntity.identifier(forSession: pane.sessionName))
        // The identifier resolves through the same lookup as every pane intent.
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
        #expect(try IntentTargets.pane(session: identifier.identifier, in: ctx).pane === pane)
    }

    @Test
    func quick_terminal_and_widget_panes_name_no_entity() throws {
        guard #available(macOS 15.4, *) else { return }
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        appState.desktopScreens = { [DesktopScreen(name: "Test", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))] }
        appState.nativeDesktopWidgetFrames = { [] }
        let quick = try #require(appState.quickTerminal.ensureTab()?.focusedPane)
        let widget = try #require(appState.createDesktopWidget().pane)
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
        for pane in [quick, widget] {
            // `PaneSurface` asks whether a window can show the pane's
            // project. The hidden projects of these panes are not.
            let project = try #require(appState.model.project(pane.projectID))
            #expect(!project.isSelectable)
            let view = NSView()
            MactermPaneEntity.annotate(view, for: pane, addressable: project.isSelectable)
            // `allPanes` walks the projects that Shortcuts can address only,
            // so an identifier here would name a pane that every pane intent
            // reports as not found.
            #expect(view.appEntityIdentifier == nil)
            #expect(!IntentTargets.allPanes(in: ctx).contains { $0.pane === pane })
        }
    }

    @Test
    func running_a_command_in_a_pane_with_no_surface_reports_no_surface() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)

        let intent = RunCommandInMactermPaneIntent()
        intent.command = "ls"
        intent.submit = true
        intent.pane = MactermPaneEntity(pane, projectID: project.id, in: ctx)

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func running_an_empty_command_is_rejected_before_the_pane_is_resolved() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)

        let intent = RunCommandInMactermPaneIntent()
        intent.command = ""
        intent.submit = true
        intent.pane = MactermPaneEntity(
            pane,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func an_unparseable_key_chord_is_bad_input_not_a_silent_no_op() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)

        let intent = SendKeyToMactermPaneIntent()
        intent.key = "ctrl+nonsense"
        intent.pane = MactermPaneEntity(
            pane,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func the_key_chord_grammar_is_the_keybind_grammar() {
        // The whole point of routing through `HotkeyRegistry.parseShortcut` is
        // that a shortcut can send what a user could bind.
        for chord in ["ctrl+c", "escape", "up", "ctrl+\\", "j", "space"] {
            #expect(HotkeyRegistry.parseShortcut(chord) != nil, "\(chord) should parse")
        }
    }

    @Test
    func pane_details_answer_from_the_pane_without_a_surface() throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)
        pane.foregroundProcessName = "hx"

        #expect(GetMactermPaneDetailsIntent.value(of: .id, for: pane) == pane.id.uuidString)
        #expect(GetMactermPaneDetailsIntent.value(of: .session, for: pane) == pane.sessionName)
        // No live pwd without a surface, so the project's own path stands in —
        // the same pair `pane list` reports.
        #expect(GetMactermPaneDetailsIntent.value(of: .workingDirectory, for: pane) == pane.projectPath)
        #expect(GetMactermPaneDetailsIntent.value(of: .foregroundProcess, for: pane) == "hx")
        // A nil is a real answer ("no surface yet"), not a failure.
        #expect(GetMactermPaneDetailsIntent.value(of: .size, for: pane) == nil)
    }

    @Test
    func reading_a_pane_with_no_surface_reports_no_surface() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.liveTabs[project.id]?.tabs.first?.splitRoot.allPanes().first)

        let intent = GetMactermPaneContentsIntent()
        intent.scrollback = false
        intent.pane = MactermPaneEntity(
            pane,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    // MARK: - Keybinds and commands

    @Test
    func the_keybind_picker_covers_every_hotkey_action_exactly() {
        let picker = Set(MactermKeybind.allCases.map(\.rawValue))
        let actions = Set(HotkeyAction.allCases.map(\.rawValue))
        // The list is a hand-written copy by necessity (the metadata extractor
        // rejects a computed `caseDisplayRepresentations`), so this is what
        // keeps it honest: a new keybind fails here rather than quietly missing
        // from Shortcuts.
        #expect(picker == actions)
        #expect(MactermKeybind.allCases.allSatisfy { $0.hotkeyAction != nil })
    }

    @Test
    func every_keybind_label_is_its_own_command_title() throws {
        for keybind in MactermKeybind.allCases {
            let action = try #require(keybind.hotkeyAction)
            let label = MactermKeybind.caseDisplayRepresentations[keybind]?.title.key
            #expect(label == action.appCommand.title, "label for \(keybind.rawValue)")
        }
    }

    @Test
    func invoking_a_keybind_runs_the_shared_app_command_action() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let delegate = attachDelegate(appState, projectStore)
        let before = appState.liveTabs[project.id]?.tabs.count ?? 0

        let intent = InvokeMactermKeybindIntent()
        intent.keybind = .newTab
        let result = try await intent.perform()

        #expect(result.value == true)
        // The action ran through `AppCommand.newTab.action(in:)` — the same
        // closure the palette, the menu bar and the Dock menu run.
        #expect(appState.liveTabs[project.id]?.tabs.count == before + 1)
        #expect(appState.appDelegate === delegate)
    }

    @Test
    func a_keybind_that_does_not_apply_returns_false_instead_of_failing() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let delegate = attachDelegate(appState, projectStore)
        // No project, so `AppCommand.newTab.action(in:)` is nil.
        #expect(appState.activeProjectID == nil)

        let intent = InvokeMactermKeybindIntent()
        intent.keybind = .newTab
        let result = try await intent.perform()

        // A shortcut branches on this rather than erroring out — the command
        // simply didn't apply, which is not the same as a failure.
        #expect(result.value == false)
        #expect(appState.appDelegate === delegate)
    }

    @Test
    func the_quick_terminal_prepares_nothing_and_the_palette_fronts_a_window() {
        // Shared with the Dock menu (`DockMenu.Preparation`) rather than
        // decided again: an intent arrives in exactly the state a Dock pick
        // does — app not activated, no window fronted.
        #expect(DockMenu.preparation(for: .toggleQuickTerminal) == DockMenu.Preparation.none)
        #expect(DockMenu.preparation(for: .toggleCommandPalette) == .frontTerminalWindow)
        #expect(DockMenu.preparation(for: .newTab) == .frontTerminalWindow)
    }

    // MARK: - Where Did I Leave Off reads project memory

    @Test
    func where_did_i_leave_off_answers_from_the_log_and_refuses_while_memory_or_the_model_is_off() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let store = ProjectMemoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intent-tests-memory-\(UUID().uuidString)", isDirectory: true))
        let memory = ProjectMemory(store: store)
        MactermIntentHost.shared.projectMemory = { memory }
        defer { MactermIntentHost.shared.projectMemory = { .shared } }
        let wasOn = Preferences.shared.projectMemory
        let wasReader = ProjectMemory.shared.modelReader
        defer {
            Preferences.shared.projectMemory = wasOn
            ProjectMemory.shared.modelReader = wasReader
            ProjectMemory.shared.refreshModelAvailability()
        }

        let intent = GetMactermProjectMemoryIntent()
        intent.project = MactermProjectEntity(project)

        ProjectMemory.shared.modelReader = { .available }
        ProjectMemory.shared.refreshModelAvailability()
        Preferences.shared.projectMemory = false
        await #expect(throws: MactermIntentError.self) { try await intent.perform() }

        // Project Insights needs Apple Intelligence, also with its switch on,
        // and the refusal says why.
        Preferences.shared.projectMemory = true
        func refusal() async -> String? {
            do {
                _ = try await intent.perform()
                return nil
            } catch let MactermIntentError.unavailable(message) {
                return message
            } catch {
                return nil
            }
        }
        ProjectMemory.shared.modelReader = { .notReady }
        ProjectMemory.shared.refreshModelAvailability()
        #expect(await refusal() == String(localized: "Project Insights needs Apple Intelligence. Turn it on in System Settings."))
        ProjectMemory.shared.modelReader = { .unsupported }
        ProjectMemory.shared.refreshModelAvailability()
        #expect(await refusal() == String(localized: "Project Insights needs a Mac with Apple Intelligence."))

        ProjectMemory.shared.modelReader = { .available }
        ProjectMemory.shared.refreshModelAvailability()
        store.append(MemoryEntry(command: "make test", directory: "/tmp", exitCode: 2, finishedAt: Date(), duration: 1), to: project.id)
        let result = try await intent.perform()
        #expect(String(describing: result.value).contains("The last command, make test, failed with exit code 2"))

        // The pinned workspace is not a project, so it has no memory.
        let pinned = GetMactermProjectMemoryIntent()
        let pinnedID = try #require(appState.ensurePinnedProject())
        pinned.project = try MactermProjectEntity(#require(appState.model.project(pinnedID)))
        await #expect(throws: MactermIntentError.self) { try await pinned.perform() }
    }
}
