import Foundation
@testable import Macterm
import Testing

/// A screen that asks for one value (`InputPaletteScope`), driven through
/// one example: a folder name that must not be empty or hold a slash, with
/// the directories of a parent as its completions.
@MainActor
struct InputPaletteScopeTests {
    /// What the example's commits did.
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
            if name.isEmpty { return .refused("Type a name.") }
            if name.contains("/") { return .refused("A name cannot contain a slash.") }
            log.committed.append(name)
            return .done
        }
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
    func a_commit_runs_the_action_with_the_text_and_closes() {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log))
        _ = scope.sections(for: PaletteQuery(raw: "notes"), context: makeContext())
        #expect(scope.commit("notes"))
        #expect(log.committed == ["notes"])
        #expect(scope.failure == nil)
    }

    @Test
    func a_refused_commit_keeps_the_screen_with_one_line_until_the_text_changes() throws {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log))
        let context = makeContext()

        _ = scope.sections(for: PaletteQuery(raw: "a/b"), context: context)
        #expect(!scope.commit("a/b"))
        #expect(log.committed.isEmpty)
        let failure = try #require(scope.failure)
        #expect(failure.title == "A name cannot contain a slash.")
        #expect(!failure.retryable, "a refusal is one line with no Retry")

        _ = scope.sections(for: PaletteQuery(raw: "a/b"), context: context)
        #expect(scope.failure == failure, "a redraw of the same text keeps the reason")

        _ = scope.sections(for: PaletteQuery(raw: "ab"), context: context)
        #expect(scope.failure == nil, "an edit clears it")
        #expect(scope.commit("ab"))
        #expect(log.committed == ["ab"])
    }

    @Test
    func completions_are_rows_that_fill_the_field() throws {
        let scope = InputPaletteScope(input: makeInput(log: Log()) { text in
            ["notes", "novel"].filter { $0.hasPrefix(text) }.map { PaletteCompletion(title: $0, value: $0 + "-1") }
        })
        let rows = scope.sections(for: PaletteQuery(raw: "no"), context: makeContext()).flatMap(\.items)
        #expect(rows.map(\.title) == ["notes", "novel"])
        #expect(try scope.completion(for: #require(rows.last)) == "novel-1")
        #expect(scope.completion(for: PaletteItem(title: "other", action: {})) == nil)
        #expect(scope.sections(for: PaletteQuery(raw: "x"), context: makeContext()).isEmpty)
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
    func the_field_keeps_its_text_across_a_pop_and_the_screen_leaves_the_stack() throws {
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

        // Escape or Backspace at an empty field pops it like any screen.
        window.popPaletteFrame()
        #expect(window.paletteStack.isEmpty)
    }
}
