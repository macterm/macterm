import Foundation
@testable import Macterm
import Testing

/// A screen that asks for one value (`InputPaletteScope`), driven through
/// one example: a folder name that must not be empty or hold a slash, and
/// that the action refuses when it is `taken`.
@MainActor
struct InputPaletteScopeTests {
    /// What the example's actions did.
    final class Log {
        var committed: [String] = []
    }

    private func makeInput(log: Log, completions: @escaping @MainActor (String) -> [PaletteCompletion] = { _ in [] }) -> PaletteInput {
        PaletteInput(
            id: "test.folder-name",
            pill: PalettePill(title: "New Folder", icon: "folder.badge.plus"),
            prompt: "Folder name",
            initialValue: "untitled",
            completions: completions
        ) { text in
            let name = text.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return .nothing }
            if name.contains("/") { return .notice("A name cannot contain a slash.") }
            return .action(PaletteInputAction(title: "Make \"\(name)\"") {
                if name == "taken" { return .refused("The name is taken.") }
                log.committed.append(name)
                return .done
            })
        }
    }

    private func rows(_ scope: InputPaletteScope, _ text: String) -> [PaletteItem] {
        scope.sections(for: PaletteQuery(raw: text), context: makeContext()).flatMap(\.items)
    }

    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
    }

    private func makeContext() -> PaletteContext {
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        return PaletteContext(appState: makeAppState(), projectStore: ProjectStore(fileURL: storeTmp))
    }

    @Test
    func the_screen_starts_on_its_value_with_its_prompt_and_pill() throws {
        let input = makeInput(log: Log())
        let frame = PaletteFrame(.input(input))
        let scope = try #require(frame.scope as? InputPaletteScope)
        #expect(frame.pill == input.pill)
        #expect(scope.placeholder == "Folder name")
        #expect(scope.initialQuery == "untitled")
        #expect(PaletteScopeID.input(input).command == nil)
        #expect(PaletteScopeID.input(input) == .input(makeInput(log: Log())), "one id is one screen")
    }

    @Test
    func a_valid_value_has_one_action_row_first_and_return_on_it_runs_it() throws {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log) { _ in
            [PaletteCompletion(title: "notes-old", value: "notes-old")]
        })
        let items = rows(scope, "notes")
        #expect(items.map(\.title) == ["Make \"notes\"", "notes-old"])
        let action = try #require(items.first)
        #expect(scope.isAction(action))
        #expect(!scope.isAction(items[1]))
        #expect(scope.failure == nil)

        #expect(scope.press(action) == .closed)
        #expect(log.committed == ["notes"])
    }

    @Test
    func return_with_no_row_selected_does_nothing() {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log))
        _ = rows(scope, "notes")
        #expect(scope.press(nil) == .nothing)
        #expect(log.committed.isEmpty, "no fallback commits the field text")
    }

    @Test
    func a_value_that_is_not_valid_has_no_action_row_and_shows_its_notice_until_the_text_changes() throws {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log))

        #expect(rows(scope, "a/b").isEmpty)
        let failure = try #require(scope.failure)
        #expect(failure.title == "A name cannot contain a slash.")
        #expect(!failure.retryable, "a notice is one line with no Retry")

        #expect(rows(scope, "ab").count == 1)
        #expect(scope.failure == nil, "an edit clears it")

        #expect(rows(scope, "").isEmpty, "an empty field has no row")
        #expect(scope.failure == nil, "and no notice")
        #expect(log.committed.isEmpty)
    }

    @Test
    func an_action_that_refuses_keeps_the_screen_with_one_line_until_the_text_changes() throws {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log))

        let action = try #require(rows(scope, "taken").first)
        #expect(scope.press(action) == .refused)
        #expect(scope.failure?.title == "The name is taken.")
        _ = rows(scope, "taken")
        #expect(scope.failure?.title == "The name is taken.", "a redraw of the same text keeps the reason")

        let other = try #require(rows(scope, "free").first)
        #expect(scope.failure == nil, "an edit clears it")
        #expect(scope.press(other) == .closed)
        #expect(log.committed == ["free"])
    }

    @Test
    func completions_are_rows_that_fill_the_field_and_never_run_the_action() throws {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log) { text in
            ["notes", "novel"].filter { $0.hasPrefix(text) }.map { PaletteCompletion(title: $0, value: $0 + "-1") }
        })
        let items = rows(scope, "no")
        #expect(items.map(\.title) == ["Make \"no\"", "notes", "novel"])
        let novel = try #require(items.last)
        #expect(scope.completion(for: novel) == "novel-1")
        #expect(scope.completion(for: items[0]) == nil, "the action row is no completion")
        #expect(scope.completion(for: PaletteItem(title: "other", action: {})) == nil)
        #expect(scope.press(novel) == .fill("novel-1"))
        #expect(log.committed.isEmpty)

        let filled = rows(scope, "novel-1")
        #expect(filled.map(\.title) == ["Make \"novel-1\""])
    }

    @Test
    func a_folder_field_has_the_path_notice_or_the_action_row() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-input-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let scope = InputPaletteScope(input: PaletteInput(
            id: "test.folder",
            pill: PalettePill(title: "Folder", icon: "folder"),
            prompt: "Folder"
        ) { text in
            PaletteInput.folderCheck(text) { path in PaletteInputAction(title: "Change to \"\(path)\"") { .done } }
        })

        #expect(rows(scope, root.path).map(\.title) == ["Change to \"\(root.path)\""])
        #expect(scope.failure == nil)

        #expect(rows(scope, file.path).isEmpty)
        #expect(scope.failure?.title == "\(file.path) is not a directory")

        let missing = root.appendingPathComponent("none").path
        #expect(rows(scope, missing).isEmpty)
        #expect(scope.failure?.title == "Path \(missing) doesn't exist")

        #expect(rows(scope, "  ").isEmpty)
        #expect(scope.failure == nil)
    }

    @Test
    func a_path_field_completes_with_the_shared_path_completer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-input-path-\(UUID().uuidString)", isDirectory: true)
        for name in ["src", "scripts", ".swiftpm"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let completions = PaletteInput.pathCompletions(root.path + "/s")
        #expect(completions == [
            PaletteCompletion(title: "scripts", value: root.path + "/scripts/"),
            PaletteCompletion(title: "src", value: root.path + "/src/"),
        ])
        #expect(PaletteInput.pathCompletions("devbox:~/dev").isEmpty, "a remote path gets no completion")
    }

    @Test
    func a_chord_opens_it_on_its_value_and_the_scope_keeps_its_text_while_covered() throws {
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        let input = makeInput(log: Log())

        // Opened by a chord: the field starts on the value.
        state.commandPaletteQuery = "split"
        state.openCommandPalette(scope: .input(input))
        #expect(window.paletteScope == .input(input))
        #expect(state.commandPaletteQuery == "untitled")

        // A screen above it and back: its field has the text it had.
        let scope = try #require(window.paletteStack.last?.scope as? InputPaletteScope)
        _ = scope.sections(for: PaletteQuery(raw: "draft"), context: makeContext())
        window.pushPaletteFrame(PaletteFrame(.passwords))
        window.popPaletteFrame()
        #expect(window.paletteStack.last?.scope.initialQuery == "draft")

        // Its frame leaves the stack like any screen's.
        window.popPaletteFrame()
        #expect(window.paletteStack.isEmpty)
    }
}
