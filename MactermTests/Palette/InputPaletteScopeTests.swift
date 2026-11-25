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

        #expect(rows(scope, "").map(\.id) == [InputPaletteScope.cancelItemID], "an empty field has only the Cancel row")
        #expect(scope.failure == nil, "and no notice")
        #expect(log.committed.isEmpty)
    }

    @Test
    func an_empty_field_has_a_cancel_row_last_that_leaves_the_screen() throws {
        let log = Log()
        let scope = InputPaletteScope(input: makeInput(log: log) { _ in
            [PaletteCompletion(title: "Select in Finder", value: "~/")]
        })
        let items = rows(scope, "")
        #expect(items.map(\.title) == ["Select in Finder", "Cancel"])
        let cancel = try #require(items.last)
        #expect(!scope.isAction(cancel))
        #expect(scope.completion(for: cancel) == nil)
        #expect(scope.restingItemID == InputPaletteScope.cancelItemID, "with no action row, Return on an empty field cancels")
        #expect(scope.press(cancel) == .cancelled)
        #expect(scope.press(items[0]) == .fill("~/"), "another selected row is not the Cancel row")
        #expect(log.committed.isEmpty)

        let typed = rows(scope, "notes")
        #expect(!typed.contains { $0.id == InputPaletteScope.cancelItemID }, "text hides the Cancel row")
        #expect(scope.restingItemID == InputPaletteScope.actionItemID, "the action row is the resting row")
        #expect(scope.press(cancel) != .cancelled, "a stale Cancel row does nothing once there is text")

        #expect(rows(scope, "a/b").allSatisfy { $0.id != InputPaletteScope.cancelItemID })
        #expect(scope.restingItemID == nil, "no row rests for a value that is not valid")
    }

    @Test
    func a_choice_row_is_the_action_and_tab_fills_its_value() throws {
        var ran: [String] = []
        let scope = InputPaletteScope(input: PaletteInput(
            id: "test.choices",
            pill: PalettePill(title: "Pick", icon: "folder"),
            prompt: "Pick",
            choices: { text, _ in
                (text == "*" ? ["alpha", "beta"] : []).map { name in
                    PaletteInputChoice(item: PaletteItem(id: "pick:\(name)", title: name) { ran.append(name) }, value: name + "/")
                }
            },
            check: { _ in .nothing }
        ))
        let listed = rows(scope, "*")
        #expect(listed.map(\.title) == ["alpha", "beta"])
        #expect(scope.restingItemID == "pick:alpha", "the selection rests on the first choice")
        let beta = try #require(listed.last)
        #expect(scope.isChoice(beta))
        #expect(scope.completion(for: beta) == "beta/", "Tab fills the value")
        #expect(scope.press(beta) == .closed)
        #expect(ran == ["beta"], "Return or a click runs the selected choice only")

        #expect(rows(scope, "").map(\.id) == [InputPaletteScope.cancelItemID], "no choice: Cancel rests")
        #expect(scope.restingItemID == InputPaletteScope.cancelItemID)
    }

    @Test
    func tab_skips_a_value_that_the_field_has_and_an_action_row_rests_before_a_choice() {
        let scope = InputPaletteScope(input: PaletteInput(
            id: "test.tab",
            pill: PalettePill(title: "Pick", icon: "folder"),
            prompt: "Pick",
            choices: { _, _ in
                ["a/", "a/b/"].map { PaletteInputChoice(item: PaletteItem(id: "pick:\($0)", title: $0) {}, value: $0) }
            },
            check: { _ in .action(PaletteInputAction(title: "Use") { .done }) }
        ))
        let listed = rows(scope, "a/")
        #expect(listed.first?.id == InputPaletteScope.actionItemID, "the action row comes first")
        #expect(scope.restingItemID == InputPaletteScope.actionItemID, "and the selection rests on it")
        #expect(!listed.contains { $0.id == InputPaletteScope.cancelItemID }, "text hides Cancel")
        #expect(scope.tabText(selected: listed[1], rows: listed) == "a/b/", "the field has a/, so Tab takes the next value")
        #expect(scope.tabText(selected: listed[2], rows: listed) == "a/b/")
    }

    @Test
    func an_empty_field_with_an_action_row_rests_on_the_action_row() {
        let scope = InputPaletteScope(input: PaletteInput(
            id: "test.empty-action",
            pill: PalettePill(title: "Here", icon: "folder"),
            prompt: "Folder"
        ) { _ in .action(PaletteInputAction(title: "Current Pane's Directory") { .done }) })
        #expect(rows(scope, "").map(\.id) == [InputPaletteScope.actionItemID, InputPaletteScope.cancelItemID])
        #expect(scope.restingItemID == InputPaletteScope.actionItemID, "Cancel is selected only when no other row is")
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
