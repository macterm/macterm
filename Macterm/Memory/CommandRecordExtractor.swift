import Foundation

/// A command that finished in a pane: the one input of Project Insights'
/// recorder (`ProjectMemory.commandEnded`).
///
/// It comes from the session's `end` mark (OSC 133;D), which has the command
/// line and the exit code, with the folder from the session's `cwd` and the
/// start from its `output` mark (`Pane.commandStartedAt`). A surface with no
/// session gives libghostty's `COMMAND_FINISHED` instead, with the same
/// fields. Nothing reads the command from the screen.
struct CommandEnd: Equatable {
    var paneID: UUID
    var projectID: UUID
    /// The command line as the shell sent it or as the prompt's input cells
    /// hold it. nil when there is neither: nothing is recorded.
    var command: String?
    /// nil when the shell reported none.
    var exitCode: Int?
    /// The shell's working directory when the command finished (OSC 7).
    var directory: String?
    /// nil when no start mark came for this command (a client that attached
    /// while it ran).
    var startedAt: Date?
    var finishedAt: Date

    /// Seconds. 0 when the start is not known.
    var duration: TimeInterval {
        startedAt.map { max(0, finishedAt.timeIntervalSince($0)) } ?? 0
    }
}

struct ExtractedCommand: Equatable {
    var command: String
    var output: String
    /// The user typed a space before the command: the shells'
    /// `HISTCONTROL=ignorespace` sign for "do not remember this".
    var isPrivate = false
}

/// The last command and its output on a pane's screen, read once the shell
/// has printed its next prompt, with the prompt-mark rules of
/// `OutputExplanation.lastCommand(in:)`. Project Insights uses it only for
/// the output tail of a failure; the command itself comes from the
/// `CommandEnd`. When the screen does not show the pair (a `clear`, a
/// full-screen program, output longer than the screen, a prompt with no
/// mark), there is no tail.
enum ScreenCommandExtractor {
    static func extract(screen: String) -> ExtractedCommand? {
        guard let last = OutputExplanation.lastCommand(in: screen) else { return nil }
        let command = last.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return ExtractedCommand(command: command, output: last.output)
    }

    /// Whether `screen`, the command as the screen shows it after the
    /// command finished, shows `command`: the same text, or the same text
    /// and a right prompt after a gap of two or more spaces. The output of
    /// the screen's command is then this command's output.
    static func screenCommand(_ screen: String, shows command: String) -> Bool {
        if MemoryCommand.normalized(screen) == MemoryCommand.normalized(command) { return true }
        guard screen.hasPrefix(command) else { return false }
        let rest = screen.dropFirst(command.count)
        return rest.hasPrefix("  ") || rest.hasPrefix(" \t")
    }
}
