import Foundation
import Testing

/// `control.sock` is frozen (design/011, Decision 2026-11-15). This test pins
/// the exact list of commands that `ControlHandler.dispatch` answers, the
/// debug-only ones included. It reads the switch from the source, so a new
/// `case` fails it, and so does a removed one.
struct ControlCommandFreezeTests {
    private static let frozenCommands: Set = [
        "status",
        "project.list", "project.create", "project.select", "project.rename", "project.remove",
        "project.memory",
        "tab.list", "tab.new", "tab.select", "tab.move", "tab.rename", "tab.close", "tab.merge",
        "window.list", "window.new", "window.close", "window.focus",
        "pane.list", "pane.inspect", "pane.dump", "pane.split", "pane.mirror", "pane.focus",
        "pane.close", "pane.run", "pane.key", "pane.zoom", "pane.resize-split", "pane.resize",
        "pane.move", "pane.password", "pane.copy-mode", "pane.read-only", "pane.explain",
        "host.connect", "host.disconnect", "host.server",
        "ssh.askpass",
        "grid",
        "session.list", "session.info", "session.kill",
        "layout.apply", "layout.save",
        "tutor.render",
        "widget.list", "widget.new", "widget.set", "widget.edit", "widget.done", "widget.remove",
        "palette.list",
    ]

    @Test
    func control_socket_command_list_is_frozen() throws {
        let commands = try Self.dispatchedCommands()
        let added = commands.subtracting(Self.frozenCommands).sorted()
        let removed = Self.frozenCommands.subtracting(commands).sorted()
        #expect(
            added.isEmpty,
            """
            control.sock is frozen. Do not add \(added) to ControlHandler. Add a new verb to the \
            server protocol as an app action that the server relays to the app (issue 0235).
            """
        )
        #expect(
            removed.isEmpty,
            "ControlHandler no longer answers \(removed). Remove them from frozenCommands on purpose."
        )
    }

    /// The `case "…":` names between `func dispatch` and its `default:`.
    private static func dispatchedCommands() throws -> Set<String> {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Control
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("Macterm/Control/ControlHandler.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "private func dispatch("))
        let end = try #require(text.range(of: "default:", range: start.upperBound ..< text.endIndex))
        let body = text[start.upperBound ..< end.lowerBound]
        let pattern = try Regex(#"case "([^"]+)":"#)
        let names = body.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) }
        #expect(!names.isEmpty)
        return Set(names)
    }
}
