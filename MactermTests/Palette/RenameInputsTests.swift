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
        let (state, _, project) = makeState()
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        ModelWriter.tabSet(tab, title: "build")
        let screen = try scope(.renameTab(tab.id, in: project.id, appState: state))
        // Typed, then popped (Escape) with no commit.
        _ = screen.sections(for: PaletteQuery(raw: "other"), context: PaletteContext(
            appState: state,
            projectStore: ProjectStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-tests-\(UUID().uuidString).json"))
        ))
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
        let (_, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, store: store))
        #expect(screen.placeholder == "Project name")
        #expect(screen.initialQuery == "alpha")
    }

    @Test
    func project_commit_renames() throws {
        let (_, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, store: store))
        #expect(screen.commit(" beta "))
        #expect(store.projects.first { $0.id == project.id }?.name == "beta")
    }

    @Test
    func project_empty_commit_changes_nothing() throws {
        let (_, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, store: store))
        #expect(screen.commit(""))
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }

    @Test
    func project_reserved_name_is_refused_on_the_screen() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, store: store))
        #expect(!screen.commit("Pinned"))
        #expect(screen.failure?.title == PinnedTabs.reservedNameMessage)
        #expect(screen.failure?.retryable == false)
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
        #expect(state.pendingDialog == nil, "the screen says why, so no notice")
    }

    @Test
    func project_escape_changes_nothing() throws {
        let (state, store, project) = makeState()
        let screen = try scope(.renameProject(project.id, store: store))
        _ = screen.sections(for: PaletteQuery(raw: "beta"), context: PaletteContext(appState: state, projectStore: store))
        #expect(store.projects.first { $0.id == project.id }?.name == "alpha")
    }
}
