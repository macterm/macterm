import Foundation
@testable import Macterm
import Testing

@MainActor
struct CommandSourceTests {
    // MARK: - Helpers

    private func makeContext(seedProject: Bool = true) -> (PaletteContext, AppState) {
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
        if seedProject {
            let p = Project(name: "proj", path: "/tmp", sortOrder: 0)
            store.add(p)
            state.selectProject(p)
        }
        return (PaletteContext(appState: state, projectStore: store), state)
    }

    private func findItem(title: String, in ctx: PaletteContext) -> PaletteItem? {
        CommandSource().emptyItems(context: ctx)?.first { $0.title == title }
    }

    /// Find a command via the QUERY path (fuzzy `items(query:)`), the code that
    /// carries the 6.1 `isEnabled` field-preservation fix.
    private func queryItem(title: String, query: String, in ctx: PaletteContext) -> PaletteItem? {
        CommandSource().items(query: query, context: ctx).first { $0.title == title }
    }

    // MARK: - renameTab command availability

    @Test
    func renameTab_command_present_when_active_project_has_tab() {
        let (ctx, _) = makeContext()
        #expect(findItem(title: AppCommand.renameTab.title, in: ctx) != nil)
    }

    @Test
    func renameTab_command_absent_when_no_active_project() {
        let (ctx, _) = makeContext(seedProject: false)
        #expect(findItem(title: AppCommand.renameTab.title, in: ctx) == nil)
    }

    // MARK: - renameTab row

    /// The row opens the input screen of the tab that was active when the
    /// row was built, in place: the palette stays up.
    @Test
    func renameTab_row_opens_the_input_screen_of_the_active_tab() throws {
        let (ctx, state) = makeContext()
        let projectID = try #require(state.activeProjectID)
        let ws = try #require(state.workspaces[projectID])
        let secondTab = ModelWriter.tabCreate(in: ws, projectPath: "/tmp")
        ModelWriter.tabSelect(secondTab.id, in: ws)

        let item = try #require(findItem(title: AppCommand.renameTab.title, in: ctx))
        guard case let .input(input) = item.opensScope else {
            Issue.record("Rename Current Tab opens no input screen")
            return
        }
        #expect(input.id == "rename-tab:\(secondTab.id.uuidString)")
        #expect(item.icon == nil, "an input screen's pill has no glyph, so its row has none")
        #expect(state.postPaletteAction == nil)
    }

    // MARK: - renameProject command availability

    @Test
    func renameProject_command_present_when_active_project_exists() {
        let (ctx, _) = makeContext()
        #expect(findItem(title: AppCommand.renameProject.title, in: ctx) != nil)
    }

    @Test
    func renameProject_command_absent_when_no_active_project() {
        let (ctx, _) = makeContext(seedProject: false)
        #expect(findItem(title: AppCommand.renameProject.title, in: ctx) == nil)
    }

    // MARK: - renameProject row

    @Test
    func renameProject_row_opens_the_input_screen_of_the_current_project() throws {
        let (ctx, state) = makeContext()
        let projectID = try #require(state.activeProjectID)
        let item = try #require(findItem(title: AppCommand.renameProject.title, in: ctx))
        guard case let .input(input) = item.opensScope else {
            Issue.record("Rename Current Project opens no input screen")
            return
        }
        #expect(input.id == "rename-project:\(projectID.uuidString)")
        #expect(input.initialValue == "proj")
    }

    // MARK: - applyLayout muted state

    /// Throws so a broken fixture fails loudly at its own line instead of
    /// surfacing as a misleading later assertion failure.
    private func writeProjectFile(_ yaml: String, in state: AppState) throws {
        let dir = state.projectFiles.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: dir.appendingPathComponent("p.yaml"), atomically: true, encoding: .utf8)
    }

    @Test
    func applyLayout_is_muted_with_hint_when_no_project_file_exists() throws {
        let (ctx, _) = makeContext()
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(!item.isEnabled)
        #expect(item.subtitle != nil)
    }

    @Test
    func applyLayout_is_muted_when_project_file_has_no_tabs() throws {
        let (ctx, state) = makeContext()
        try writeProjectFile("path: /tmp\n", in: state)
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(!item.isEnabled)
    }

    @Test
    func applyLayout_is_enabled_when_project_file_declares_tabs() throws {
        let (ctx, state) = makeContext()
        try writeProjectFile("path: /tmp\ntabs:\n  - {}\n", in: state)
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
    }

    @Test
    func applyLayout_stays_enabled_when_project_file_is_invalid() throws {
        // Invoking it surfaces the parse-error dialog — hiding or muting the
        // command would bury the error instead.
        let (ctx, state) = makeContext()
        try writeProjectFile("path: /tmp\ntabs:\n  - split: { direction: horizontal, first: {} }\n", in: state)
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
    }

    @Test
    func a_muted_palette_screen_keeps_its_glyph_but_no_way_in() throws {
        // Files cannot index a remote project, so it is muted with a reason.
        let (ctx, state) = makeContext(seedProject: false)
        let remote = Project(name: "devbox", path: "devbox:/srv/app", sortOrder: 0)
        ctx.projectStore.add(remote)
        state.activeProjectID = remote.id
        let item = try #require(findItem(title: AppCommand.files.title, in: ctx))
        #expect(!item.isEnabled)
        #expect(item.icon == PaletteScopeID.files.pill.icon)
        #expect(item.opensScope == nil, "a muted row draws no chevron")
    }

    @Test
    func applyLayout_is_hidden_without_active_project() {
        let (ctx, _) = makeContext(seedProject: false)
        #expect(findItem(title: AppCommand.applyLayout.title, in: ctx) == nil)
    }

    @Test
    func applyLayout_subtitle_names_duplicate_project_files() throws {
        // Both files are ones the "proj" slug OWNS (`proj.yaml`, `proj_2.yaml`)
        // — a genuine duplicate of this project's own declaration, which is
        // what the subtitle warns about.
        let (ctx, state) = makeContext()
        let dir = state.projectFiles.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "path: /tmp\ntabs:\n  - {}\n"
            .write(to: dir.appendingPathComponent("proj.yaml"), atomically: true, encoding: .utf8)
        try "path: /tmp\n"
            .write(to: dir.appendingPathComponent("proj_2.yaml"), atomically: true, encoding: .utf8)

        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
        let subtitle = try #require(item.subtitle)
        #expect(subtitle.contains("proj.yaml"))
        #expect(subtitle.contains("proj_2.yaml"))
    }

    @Test
    func applyLayout_subtitle_ignores_a_sibling_projects_file() throws {
        // A distinct-name project on the same directory owns its own file.
        // That's not a duplicate of ours, so no "ignoring duplicate" hint.
        let (ctx, state) = makeContext()
        let dir = state.projectFiles.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "path: /tmp\ntabs:\n  - {}\n"
            .write(to: dir.appendingPathComponent("proj.yaml"), atomically: true, encoding: .utf8)
        try "name: other\npath: /tmp\ntabs:\n  - {}\n"
            .write(to: dir.appendingPathComponent("other.yaml"), atomically: true, encoding: .utf8)

        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
        #expect(item.subtitle == nil)
    }

    // MARK: - items(query:) — the search path (6.7)

    @Test
    func query_prefix_match_surfaces_command() {
        let (ctx, _) = makeContext()
        // "New Tab" should surface for a prefix of its title.
        #expect(queryItem(title: AppCommand.newTab.title, query: "new t", in: ctx) != nil)
    }

    @Test
    func query_nonmatching_omits_command() {
        let (ctx, _) = makeContext()
        let results = CommandSource().items(query: "zzzznomatch", context: ctx)
        #expect(results.isEmpty)
    }

    /// Regression for the 6.1 bug: a disabled hint row that matches a search
    /// query must stay disabled (muted, unselectable) — the query path used to
    /// drop `isEnabled` when it rebuilt the item.
    @Test
    func query_preserves_isEnabled_on_disabled_hint_row() throws {
        let (ctx, _) = makeContext() // no project file → Apply Layout is a muted hint
        let empty = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(!empty.isEnabled) // baseline: disabled in the empty state
        let searched = try #require(
            queryItem(title: AppCommand.applyLayout.title, query: "apply", in: ctx)
        )
        #expect(!searched.isEnabled) // must remain disabled through the search path
    }
}
