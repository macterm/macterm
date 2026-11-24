import AppKit
@testable import Macterm
import SwiftUI
import Testing

/// The palette panel (`CommandPalettePanel`) laid out in a window.
@MainActor
struct CommandPaletteTests {
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

    /// A name input: the action row for a name, a notice for a name with a
    /// slash, and many completions for "many".
    private let input = PaletteInput(
        id: "test.height",
        pill: PalettePill(title: "Name", icon: "pencil"),
        prompt: "Name",
        completions: { text in
            text == "many" ? (1 ... 30).map { PaletteCompletion(title: "row \($0)", value: "row \($0)") } : []
        },
        check: { text in
            if text.isEmpty { return .nothing }
            if text.contains("/") { return .notice("A name cannot contain a slash.") }
            return .action(PaletteInputAction(title: "Use \"\(text)\"") { .done })
        }
    )

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func an_input_screen_keeps_the_height_of_the_root_palette_in_every_state() async throws {
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let hosting = NSHostingView(rootView: CommandPalettePanel()
            .environment(state)
            .environment(window)
            .environment(ProjectStore(fileURL: storeURL)))
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // ARC owns the window: a close must not release it too.
        host.isReleasedWhenClosed = false
        host.contentView = hosting
        defer { host.close() }

        /// The height once the panel drew `text`: the scope saw it.
        func height(_ text: String, drawn: @escaping () -> Bool = { true }) async throws -> CGFloat {
            state.commandPaletteQuery = text
            try await waitUntil { scope()?.text == text && drawn() }
            #expect(scope()?.text == text && drawn(), "the panel drew \(text)")
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        func scope() -> InputPaletteScope? {
            window.paletteStack.last?.scope as? InputPaletteScope
        }

        hosting.layoutSubtreeIfNeeded()
        let root = hosting.fittingSize.height
        state.openCommandPalette(scope: .input(input))

        let empty = try await height("")
        let valid = try await height("notes") { scope()?.action != nil }
        let refused = try await height("a/b") { scope()?.failure != nil }
        let many = try await height("many")
        #expect(root > CommandPalettePanel.listHeight)
        #expect([empty, valid, refused, many].allSatisfy { $0 == root })
    }
}
