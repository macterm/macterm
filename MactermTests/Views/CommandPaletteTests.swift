import AppKit
@testable import Macterm
import SwiftUI
import Testing

/// The value of an input screen is selected when the screen opens, on every
/// way in, so that a typed name replaces it (ui-review 0600 of PR 957). The
/// palette runs in a real window that is not shown: the selection is a fact
/// of the AppKit field editor. SwiftUI's `TextField` has a field editor of
/// its own, and the old select went to the window's shared one.
@MainActor
@Suite(.serialized)
struct CommandPaletteTests {
    @MainActor
    private struct Harness {
        let state: AppState
        let store: ProjectStore
        let project: Project
        let windowState: WindowState
        let window: NSWindow
        let files: [URL]

        func close() {
            window.close()
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        var editor: NSTextView? {
            (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
        }

        /// The field as the test sees it, for a failed expectation.
        var report: String {
            guard let editor else { return "no field editor, first responder \(String(describing: window.firstResponder))" }
            return "text \"\(editor.string)\", selection \(editor.selectedRange())"
        }

        func isSelected(_ text: String) -> Bool {
            editor?.string == text && editor?.selectedRange() == NSRange(location: 0, length: (text as NSString).length)
        }
    }

    /// A palette in a window, with the project "admin" and its first tab.
    /// `scope` is the screen that shows when the palette appears (the
    /// keybind of a screen with the palette closed); nil is the root.
    private func makeHarness(scope: ((AppState, ProjectStore) -> PaletteScopeID?)? = nil) async throws -> Harness {
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
        let project = store.create(name: "admin", path: "/tmp")
        state.selectProject(project)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let windowState = state.canonicalWindowState(for: window, proposed: WindowState(activeProjectID: project.id))
        if let scope = scope?(state, store) {
            state.openCommandPalette(scope: scope)
        } else {
            windowState.isCommandPaletteVisible = true
        }
        window.contentView = NSHostingView(
            rootView: CommandPalettePanel()
                .environment(state)
                .environment(windowState)
                .environment(store)
        )
        // Off every screen and clear: AppKit keeps a borderless window where
        // it is put. A click needs the window ordered in.
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        let harness = Harness(
            state: state, store: store, project: project, windowState: windowState, window: window,
            files: [tmp, storeTmp, filesDir]
        )
        await settle { harness.editor != nil }
        _ = try #require(harness.editor, "the field takes focus: \(harness.report)")
        return harness
    }

    private func settle(_ isDone: () -> Bool) async {
        for _ in 0 ..< 150 where !isDone() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Type `text` into the field, as keys do, and wait for its rows.
    private func type(_ text: String, in h: Harness) async throws {
        let editor = try #require(h.editor)
        editor.insertText(text, replacementRange: editor.selectedRange())
        await settle { h.state.commandPaletteQuery == text }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func pressReturn(in h: Harness) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: h.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
            if let event { h.window.sendEvent(event) }
        }
    }

    /// Click the title of the first row of the list. The point comes from
    /// the frame of the list's scroll view (an `NSScrollView` under
    /// SwiftUI's `ScrollView`): the list's top padding and then half of a
    /// row. CI has no accessibility tree to find the row by.
    private func clickFirstRow(in h: Harness) throws {
        h.window.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(h.window.contentView)
        let list = try #require(Self.scrollView(in: content), "the list is in the panel")
        let frame = list.convert(list.bounds, to: nil)
        let point = NSPoint(x: frame.minX + 60, y: frame.maxY - PaletteRowInsets.highlight - 12)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        // The click's tracking reads the mouse-up from the event queue, so
        // it goes there first; the mouse-down goes to the window.
        let up = try #require(event(.leftMouseUp))
        let down = try #require(event(.leftMouseDown))
        h.window.postEvent(up, atStart: false)
        h.window.sendEvent(down)
    }

    /// The tallest scroll view under `view`: the list.
    private static func scrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.height < $1.frame.height }
    }

    private func expectSelected(_ text: String, on command: AppCommand, in h: Harness) async {
        await settle { !h.windowState.paletteStack.isEmpty && h.isSelected(text) }
        #expect(h.windowState.paletteStack.last?.pill.title == command.title, "the screen of \(command.title) is up: \(h.report)")
        #expect(h.isSelected(text), "\(text) is selected: \(h.report)")
    }

    @Test
    func project_rename_from_a_palette_row_by_return_selects_the_name() async throws {
        let h = try await makeHarness()
        defer { h.close() }
        try await type("rename current project", in: h)
        pressReturn(in: h)
        await expectSelected("admin", on: .renameProject, in: h)
    }

    @Test
    func project_rename_from_a_palette_row_by_click_selects_the_name() async throws {
        let h = try await makeHarness()
        defer { h.close() }
        try await type("rename current project", in: h)
        try clickFirstRow(in: h)
        await expectSelected("admin", on: .renameProject, in: h)
    }

    @Test
    func tab_rename_from_a_palette_row_by_return_selects_the_name() async throws {
        let h = try await makeHarness()
        defer { h.close() }
        let name = try #require(h.state.workspaces[h.project.id]?.activeTab?.sidebarTitle)
        try await type("rename current tab", in: h)
        pressReturn(in: h)
        await expectSelected(name, on: .renameTab, in: h)
    }

    /// The row was row 6 of the root list. A click ran the index of that
    /// list, which SwiftUI kept in the row's action, so it did nothing.
    @Test
    func tab_rename_from_a_palette_row_by_click_selects_the_name() async throws {
        let h = try await makeHarness()
        defer { h.close() }
        let name = try #require(h.state.workspaces[h.project.id]?.activeTab?.sidebarTitle)
        try await type("rename current tab", in: h)
        try clickFirstRow(in: h)
        await expectSelected(name, on: .renameTab, in: h)
    }

    /// The keybind and the menu item run the command's action (this test
    /// calls it directly). With the palette up, the screen replaces the one
    /// that shows.
    @Test
    func rename_by_its_command_with_the_palette_up_selects_the_name() async throws {
        let h = try await makeHarness()
        defer { h.close() }
        try await type("something", in: h)
        let action = try #require(AppCommand.renameProject.action(in: AppCommandContext(appState: h.state, projectStore: h.store)))
        action()
        await expectSelected("admin", on: .renameProject, in: h)
    }

    /// With the palette closed, the keybind opens it on the screen.
    @Test
    func rename_by_its_command_with_the_palette_closed_selects_the_name() async throws {
        let h = try await makeHarness { state, store in
            AppCommand.renameProject.inputScope(in: AppCommandContext(appState: state, projectStore: store))
        }
        defer { h.close() }
        await expectSelected("admin", on: .renameProject, in: h)
    }
}
