import Foundation
@testable import Macterm
import Testing

/// The input screens of Rename Current Tab and Rename Current Project
/// (`PaletteInput.renameTab`, `.renameProject`), driven as the palette
/// drives them: through `InputPaletteScope`.
@MainActor
struct RenameInputsTests {
    private func makeState() -> (AppState, ProjectStore, Project) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        let project = store.create(name: "alpha", path: "/tmp")
        state.selectProject(project)
        return (state, store, project)
    }

    private func scope(_ input: PaletteInput?) throws -> InputPaletteScope {
        let input = try #require(input)
        return try #require(PaletteFrame(.input(input)).scope as? InputPaletteScope)
    }

    /// Type `text` on the screen of `input` in a window, then press Escape:
    /// the palette pops the frame, and nothing commits.
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
    func tab_screen_starts_on_the_shown_name() throws {
        let (state, _, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        #expect(screen.placeholder == "Tab name")
        #expect(screen.initialQuery == tab.sidebarTitle)
    }

    @Test
    func tab_commit_compares_with_the_live_title() throws {
        // The screen opened on "build"; another client cleared the title
        // since. A commit of "build" must set it again.
        let (state, _, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        ModelWriter.tabSet(tab, title: "build")
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        ModelWriter.tabSet(tab, title: nil)
        #expect(screen.commit("build"))
        #expect(tab.customTitle == "build")
    }

    @Test
    func tab_commit_renames() throws {
        let (state, _, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        #expect(screen.commit("  build  "))
        #expect(tab.customTitle == "build")
    }

    @Test
    func tab_empty_commit_gives_back_the_automatic_name() throws {
        let (state, _, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        ModelWriter.tabSet(tab, title: "build")
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        #expect(screen.initialQuery == "build")
        #expect(screen.commit(" "))
        #expect(tab.customTitle == nil)
    }

    @Test
    func tab_commit_of_the_unchanged_automatic_name_keeps_it_automatic() throws {
        let (state, _, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        #expect(screen.commit(screen.initialQuery))
        #expect(tab.customTitle == nil)
    }

    @Test
    func tab_escape_changes_nothing() throws {
        let (state, store, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        ModelWriter.tabSet(tab, title: "build")
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
        let ws = try #require(state.workspaces[project.id])
        let first = try #require(ws.activeTab)
        let second = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        let a = try #require(PaletteInput.renameTab(first.id, in: project.id, appState: state))
        let b = try #require(PaletteInput.renameTab(second.id, in: project.id, appState: state))
        #expect(a != b)
        #expect(PaletteInput.renameTab(UUID(), in: project.id, appState: state) == nil)
    }

    // MARK: - Project

    @Test
    func project_screen_starts_on_the_name() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(screen.placeholder == "Project name")
        #expect(screen.initialQuery == "alpha")
    }

    @Test
    func project_commit_renames() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(screen.commit(" beta "))
        #expect(store.projects.first { $0.id == project.id }?.name == "beta")
    }

    @Test
    func project_empty_commit_changes_nothing() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(screen.commit(""))
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }

    @Test
    func project_reserved_name_is_refused_on_the_screen() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(!screen.commit("Pinned"))
        #expect(screen.failure?.title == PinnedTabs.reservedNameMessage)
        #expect(screen.failure?.retryable == false)
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
        #expect(state.pendingDialog == nil, "the screen says why, so no notice")
    }

    @Test
    func project_name_with_a_slash_is_refused_on_the_screen() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, appState: state, store: store))
        #expect(!screen.commit("work/api"))
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
