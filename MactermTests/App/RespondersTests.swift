import AppKit
@testable import Macterm
import Testing

/// `MainAppResponder` answers every configurable binding by running the
/// `AppCommand` that owns it, so these drive real key events through the
/// responder and assert on the model, not on which branch fired.
@MainActor
struct MainAppResponderTests {
    private struct Fixture {
        let state: AppState
        let projects: ProjectStore
        let responder: MainAppResponder
    }

    private func makeFixture() -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-responder-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("workspaces.json")),
            projectFiles: ProjectFileStore(directoryURL: tmp.appendingPathComponent("projects", isDirectory: true))
        )
        let projects = ProjectStore(fileURL: tmp.appendingPathComponent("projects.json"))
        return Fixture(state: state, projects: projects, responder: MainAppResponder(appState: state, projectStore: projects))
    }

    /// A key-down for `action`'s currently bound chord, built from the same
    /// parsed shortcut the responder matches against.
    private func keyDown(for action: HotkeyAction) throws -> NSEvent {
        let shortcut = try #require(HotkeyRegistry.selectedShortcut(for: action))
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: shortcut.keyToken,
            charactersIgnoringModifiers: shortcut.keyToken,
            isARepeat: false,
            keyCode: shortcut.keyCode
        ))
    }

    @Test
    func a_bound_chord_runs_its_commands_action_against_the_active_project() throws {
        let fx = makeFixture()
        let project = Project(name: "proj", path: "/tmp", sortOrder: 0)
        // In the store as well as selected: the command resolves the project
        // directory for the new pane from `projectStore.projects`.
        fx.projects.add(project)
        fx.state.selectProject(project)
        let tab = try #require(fx.state.workspaces[project.id]?.activeTab)
        #expect(tab.splitRoot.allPanes().count == 1)

        #expect(try fx.responder.handle(keyDown(for: .splitDown)) == .handled)
        #expect(tab.splitRoot.allPanes().count == 2)

        _ = fx.state.workspaces[project.id].map { ModelWriter.tabCreate(in: $0, projectPath: "/tmp") }
        let before = fx.state.workspaces[project.id]?.activeTabID
        #expect(try fx.responder.handle(keyDown(for: .nextTabInProject)) == .handled)
        #expect(fx.state.workspaces[project.id]?.activeTabID != before)
    }

    /// A hidden toolbar takes the traffic lights and the window drag with it,
    /// so its chord must bring the toolbar back from anywhere: it needs no
    /// project and no window.
    @Test
    func the_toolbar_chord_hides_and_shows_the_toolbar_without_a_project() throws {
        let fx = makeFixture()
        let preferences = Preferences.shared
        let original = preferences.hideTitleBar
        defer { preferences.hideTitleBar = original }
        preferences.hideTitleBar = false

        #expect(try fx.responder.handle(keyDown(for: .toggleToolbar)) == .handled)
        #expect(preferences.hideTitleBar)
        #expect(try fx.responder.handle(keyDown(for: .toggleToolbar)) == .handled)
        #expect(!preferences.hideTitleBar)
    }

    @Test
    func a_files_chord_in_a_remote_project_says_so_instead_of_reaching_the_terminal() throws {
        let fx = makeFixture()
        let action = HotkeyAction.files
        let prior = Preferences.defaults.string(forKey: action.defaultsKey)
        defer { HotkeyRegistry.setShortcutString(prior ?? action.defaultShortcut, for: action) }
        HotkeyRegistry.setShortcutString("cmd+opt+ctrl+shift+k", for: action)

        // Set directly, not selected: selecting a remote project starts ssh.
        let project = Project(name: "devbox", path: "devbox:/srv/app", sortOrder: 0)
        fx.projects.add(project)
        fx.state.activeProjectID = project.id

        #expect(try fx.responder.handle(keyDown(for: action)) == .handled)
        #expect(fx.state.activeToast?.title == "The Files screen is not available for remote projects")
    }

    @Test
    func a_chord_whose_command_does_not_apply_passes_through() throws {
        let fx = makeFixture()
        // No project selected: every project-scoped command's action is nil,
        // and the responder must not claim the keystroke — the same rule that
        // hides the palette row.
        #expect(fx.state.activeProjectID == nil)
        #expect(try fx.responder.handle(keyDown(for: .splitDown)) == .passThrough)
        #expect(try fx.responder.handle(keyDown(for: .nextTabInProject)) == .passThrough)
    }

    @Test
    func an_unbound_key_passes_through() throws {
        let fx = makeFixture()
        fx.state.selectProject(Project(name: "proj", path: "/tmp", sortOrder: 0))
        let plainX = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7
        ))
        #expect(fx.responder.handle(plainX) == .passThrough)
    }

    @Test
    func every_binding_has_an_owning_command_to_dispatch_to() {
        // The dispatch is `action.appCommand.action(in:)`; a `HotkeyAction`
        // without an owning `AppCommand` would trap there in debug builds.
        for action in HotkeyAction.allCases {
            #expect(action.appCommand.hotkeyAction == action)
        }
    }
}

/// While the palette is up, a chord whose command opens a palette screen
/// switches the palette to it; every other binding does nothing, and a key
/// that is no binding is the palette's.
@MainActor
struct PaletteResponderTests {
    private struct Fixture {
        let state: AppState
        let window: WindowState
        let project: Project
        let responder: PaletteResponder
    }

    private func makeFixture() -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-palette-responder-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("workspaces.json")),
            projectFiles: ProjectFileStore(directoryURL: tmp.appendingPathComponent("projects", isDirectory: true))
        )
        let window = WindowState()
        state.registerWindow(window)
        let projects = ProjectStore(fileURL: tmp.appendingPathComponent("projects.json"))
        let project = Project(name: "proj", path: "/tmp", sortOrder: 0)
        projects.add(project)
        state.selectProject(project)
        state.isCommandPaletteVisible = true
        return Fixture(
            state: state,
            window: window,
            project: project,
            responder: PaletteResponder(appState: state, projectStore: projects)
        )
    }

    private func keyDown(_ chord: String) throws -> NSEvent {
        let shortcut = try #require(HotkeyRegistry.parseShortcut(chord))
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: shortcut.keyToken,
            charactersIgnoringModifiers: shortcut.keyToken,
            isARepeat: false,
            keyCode: shortcut.keyCode
        ))
    }

    /// Binds `action` to `chord` for the test. The closure restores the
    /// user's own binding.
    private func bind(_ action: HotkeyAction, to chord: String) -> () -> Void {
        let prior = Preferences.defaults.string(forKey: action.defaultsKey)
        HotkeyRegistry.setShortcutString(chord, for: action)
        return { HotkeyRegistry.setShortcutString(prior ?? action.defaultShortcut, for: action) }
    }

    @Test
    func rename_tabs_chord_on_the_root_opens_the_rename_screen() throws {
        let fx = makeFixture()
        let restore = bind(.renameTab, to: "cmd+r")
        defer { restore() }
        let tab = try #require(fx.state.workspaces[fx.project.id]?.activeTab)
        let rename = try #require(PaletteInput.renameTab(tab.id, in: fx.project.id, appState: fx.state))
        #expect(fx.window.paletteScope == nil)

        #expect(try fx.responder.handle(keyDown("cmd+r")) == .handled)
        #expect(fx.window.paletteScope == .input(rename))
        #expect(fx.state.isCommandPaletteVisible)
    }

    /// ⌘T, ⌘W and a split do nothing while the palette is up. The chord is
    /// consumed: passed through, it would reach the menu item with the same
    /// key equivalent and change the tabs behind the palette.
    @Test(arguments: [
        (HotkeyAction.newTab, "cmd+t"),
        (HotkeyAction.closePane, "cmd+w"),
        (HotkeyAction.splitRight, "cmd+d"),
    ])
    func a_binding_that_opens_no_screen_does_nothing(action: HotkeyAction, chord: String) throws {
        let fx = makeFixture()
        let restore = bind(action, to: chord)
        defer { restore() }
        let workspace = try #require(fx.state.workspaces[fx.project.id])
        let tabs = workspace.tabs.map(\.id)
        let panes = workspace.activeTab?.splitRoot.allPanes().map(\.id)

        #expect(try fx.responder.handle(keyDown(chord)) == .handled)
        #expect(workspace.tabs.map(\.id) == tabs)
        #expect(workspace.activeTab?.splitRoot.allPanes().map(\.id) == panes)
        #expect(fx.window.paletteScope == nil)
        #expect(fx.state.isCommandPaletteVisible)
    }

    /// A key that is no binding (⌘C) is the palette field's.
    @Test
    func a_key_that_is_no_binding_passes_through() throws {
        let fx = makeFixture()
        let copy = try keyDown("cmd+c")
        try #require(!HotkeyAction.allCases.contains { HotkeyRegistry.matches(copy, action: $0) })
        #expect(fx.responder.handle(copy) == .passThrough)
    }

    @Test
    func cmd_r_is_retry_while_the_screen_shows_a_failed_listing() throws {
        let fx = makeFixture()
        let restore = bind(.renameTab, to: "cmd+r")
        defer { restore() }
        let failed = FailedListing()
        fx.window.pushPaletteFrame(PaletteFrame(.files, scope: failed))

        #expect(try fx.responder.handle(keyDown("cmd+r")) == .passThrough)
        #expect(fx.window.paletteScope == .files)

        failed.failure = nil
        #expect(try fx.responder.handle(keyDown("cmd+r")) == .handled)
        guard case .input = fx.window.paletteScope else {
            Issue.record("expected the rename screen, got \(String(describing: fx.window.paletteScope))")
            return
        }
    }
}

/// A screen whose listing failed, so it shows Retry.
@MainActor
private final class FailedListing: PaletteScope {
    var failure: PaletteFailure? = PaletteFailure(title: "The listing failed")
    var placeholder: String { "" }
    func sections(for _: PaletteQuery, context _: PaletteContext) -> [PaletteSection] {
        []
    }
}
