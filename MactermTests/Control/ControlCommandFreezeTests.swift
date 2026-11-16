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
        // Issue 0277 removes `pane.mirror`. Remove it here in the same change.
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
            control.sock is frozen. Do not add \(added.joined(separator: ", ")) to ControlHandler. Add a new verb to the \
            server protocol as an app action that the server relays to the app (issue 0235).
            """
        )
        #expect(
            removed.isEmpty,
            "ControlHandler no longer answers \(removed.joined(separator: ", ")). Remove them from frozenCommands in the same change."
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
        // Each case names one command: `case "noun.verb":`. Any other form of a
        // case line fails, so that a list or a pattern cannot hide a command.
        let pattern = try Regex(#"^case "([^"]+)":"#)
        var names: Set<String> = []
        for line in body.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("case ") else { continue }
            let match = try #require(
                line.firstMatch(of: pattern),
                "Write each ControlHandler case as one command: \(line)"
            )
            try names.insert(String(#require(match.output[1].substring)))
        }
        #expect(!names.isEmpty)
        return names
    }
}
