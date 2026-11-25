import Foundation
@testable import Macterm
import Testing

/// The input screens of Rename Current Tab and Rename Current Project
/// (`PaletteInput.renameTab`, `.renameProject`), driven as the palette
/// drives them: through `InputPaletteScope`, where Return runs only the
/// selected action row.
@MainActor
struct RenameInputsTests {
    private func makeState() -> (AppState, ProjectStore, Project) {
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = TestModel.appState(
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = TestModel.projectStore(state)
        store.onAdd = { [weak state] in state?.projectAdded($0) }
        let project = TestModel.project(state, name: "alpha", path: "/tmp")
        return (state, store, project)
    }

    private func scope(_ input: PaletteInput?) throws -> InputPaletteScope {
        let input = try #require(input)
        return try #require(PaletteFrame(.input(input)).scope as? InputPaletteScope)
    }

    /// The rows of `screen` for the text `text`.
    private func rows(_ screen: InputPaletteScope, _ text: String, _ state: AppState, _ store: ProjectStore) -> [PaletteItem] {
        screen.sections(for: PaletteQuery(raw: text), context: PaletteContext(appState: state, projectStore: store))
            .flatMap(\.items)
    }

    /// Type `text` on the screen of `input` in a window, then press Escape:
    /// the palette pops the frame, and nothing runs.
    private func typeThenEscape(_ input: PaletteInput?, text: String, context: PaletteContext) throws {
        let window = WindowState()
        try window.showPaletteScope(.input(#require(input)))
        let screen = try #require(window.paletteStack.last?.scope as? InputPaletteScope)
        _ = screen.sections(for: PaletteQuery(raw: text), context: context)
        window.popPaletteFrame()
        #expect(window.paletteStack.isEmpty)
    }

    // MARK: - Tab

    @Test
    func tab_screen_starts_on_the_shown_name_with_no_action_row() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let input = try #require(PaletteInput.renameTab(tab.id, in: project.id, appState: state))
        let screen = try scope(input)
        #expect(screen.placeholder == "Tab name")
        #expect(PaletteScopeID.input(input).pill == PalettePill(title: AppCommand.renameTab.title), "an input pill has no glyph")
        #expect(screen.initialQuery == tab.sidebarTitle)
        #expect(rows(screen, screen.initialQuery, state, store).isEmpty, "the name the tab has gives no row")
        #expect(screen.press(nil) == .nothing, "Return with no row does nothing")
        #expect(tab.customTitle == nil, "the tab stays automatic")
    }

    @Test
    func tab_action_row_renames() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        let items = rows(screen, "  build  ", state, store)
        #expect(items.map(\.title) == ["Rename to \"build\""])
        let action = try #require(items.first)
        #expect(action.icon == nil, "an action row has no glyph")
        #expect(screen.press(action) == .closed)
        #expect(tab.customTitle == "build")
    }

    @Test
    func tab_empty_field_gives_back_the_automatic_name() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        state.writer.tabSet(tab.id, title: "build")
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        #expect(screen.initialQuery == "build")
        let action = try #require(rows(screen, " ", state, store).first)
        #expect(action.title == "Use the automatic name \"\(tab.autoTitle)\"")
        #expect(screen.press(action) == .closed)
        #expect(tab.customTitle == nil)
    }

    @Test
    func tab_empty_field_of_an_automatic_name_gives_only_cancel() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        #expect(rows(screen, "", state, store).map(\.id) == [InputPaletteScope.cancelItemID], "an empty field has no action row")
        #expect(screen.failure == nil)
    }

    @Test
    func tab_check_reads_the_live_title() throws {
        // The screen opened on "build"; another client cleared the title
        // since. "build" is a new name again, so it has its action row.
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        state.writer.tabSet(tab.id, title: "build")
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        state.writer.tabSet(tab.id, title: nil)
        let action = try #require(rows(screen, "build", state, store).first)
        #expect(screen.press(action) == .closed)
        #expect(tab.customTitle == "build")
    }

    @Test
    func tab_that_closed_gives_no_row_and_its_row_does_nothing() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.createTab(projectID: project.id, projectPath: "/tmp", focus: false).flatMap { state.model.tab($0) })
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        let action = try #require(rows(screen, "build", state, store).first)
        state.writer.tabClose(tab.id)
        #expect(screen.press(action) == .closed, "the row of a tab that closed renames nothing")
        #expect(tab.customTitle == nil)
        #expect(rows(screen, "build", state, store).isEmpty)
    }

    @Test
    func tab_typed_automatic_name_on_a_renamed_tab_is_a_rename() throws {
        // Only the empty field gives back the automatic name. The automatic
        // name typed in full is a name like any other, so it stays fixed.
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        state.writer.tabSet(tab.id, title: "build")
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        let auto = tab.autoTitle
        let action = try #require(rows(screen, auto, state, store).first)
        #expect(action.title == "Rename to \"\(auto)\"")
        #expect(screen.press(action) == .closed)
        #expect(tab.customTitle == auto)
    }

    @Test
    func tab_escape_changes_nothing() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.liveTabs[project.id]?.activeTab)
        state.writer.tabSet(tab.id, title: "build")
        try typeThenEscape(
            .renameTab(tab.id, in: project.id, appState: state),
            text: "other",
            context: PaletteContext(appState: state, projectStore: store)
        )
        #expect(tab.customTitle == "build")
    }

    @Test
    func tab_screen_is_one_screen_for_each_tab() throws {
        let (state, _, project) = makeState()
        let ws = try #require(state.liveTabs[project.id])
        let first = try #require(ws.activeTab)
        let second = try #require(state.createTab(projectID: project.id, projectPath: "/tmp", focus: false).flatMap { state.model.tab($0) })
        let a = try #require(PaletteInput.renameTab(first.id, in: project.id, appState: state))
        let b = try #require(PaletteInput.renameTab(second.id, in: project.id, appState: state))
        #expect(a != b)
        #expect(PaletteInput.renameTab(UUID(), in: project.id, appState: state) == nil)
    }

    // MARK: - Project

    @Test
    func project_screen_starts_on_the_name_with_no_action_row() throws {
        let (state, store, project) = makeState()
        let input = try #require(PaletteInput.renameProject(project.id, appState: state, store: store))
        let screen = try scope(input)
        #expect(screen.placeholder == "Project name")
        #expect(PaletteScopeID.input(input).pill == PalettePill(title: AppCommand.renameProject.title), "an input pill has no glyph")
        #expect(screen.initialQuery == "alpha")
        #expect(rows(screen, "alpha", state, store).isEmpty)
    }

    @Test
    func project_action_row_renames() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        let items = rows(screen, " beta ", state, store)
        #expect(items.map(\.title) == ["Rename to \"beta\""])
        let rename = try #require(items.first)
        #expect(screen.press(rename) == .closed)
        #expect(store.projects.first { $0.id == project.id }?.name == "beta")
    }

    @Test
    func project_empty_field_gives_only_cancel() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(rows(screen, "", state, store).map(\.id) == [InputPaletteScope.cancelItemID], "an empty field has no action row")
        #expect(screen.failure == nil)
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }

    @Test
    func project_reserved_name_shows_the_reason_and_no_row() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(rows(screen, "Pinned", state, store).isEmpty)
        #expect(screen.failure?.title == PinnedTabs.reservedNameMessage)
        #expect(screen.failure?.retryable == false)
        #expect(state.pendingDialog == nil, "the screen says why, so no notice")
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }

    @Test
    func project_that_was_removed_gives_no_row() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        store.removeWithDescendants(project.id)
        #expect(rows(screen, "beta", state, store).isEmpty)
    }

    @Test
    func project_name_with_a_slash_shows_the_reason_and_no_row() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(rows(screen, "work/api", state, store).isEmpty)
        #expect(screen.failure?.title == Project.nameRefusal(for: "work/api"))
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }

    @Test
    func project_escape_changes_nothing() throws {
        let (state, store, project) = makeState()
        try typeThenEscape(
            .renameProject(project.id, appState: state, store: store),
            text: "beta",
            context: PaletteContext(appState: state, projectStore: store)
        )
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }
}
