import Foundation

/// A command that finished in a pane: the one input of Project Insights'
/// recorder (`ProjectMemory.commandEnded`).
///
/// It comes from the session's `end` mark (OSC 133;D), which has the command
/// line and the exit code, with the folder from the session's `cwd` and the
/// start from its `output` mark (`Pane.commandStartedAt`). A surface with no
/// session gives libghostty's `COMMAND_FINISHED` instead, with the same
/// fields but no output. Nothing is read from the screen.
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
    /// The end of a failed command's output, from the session's end mark
    /// (`output_tail`). The session reads it from its own terminal when the
    /// command ends, so a `clear` before it or a long output does not lose
    /// it. nil for a success, and for a surface with no session.
    var outputTail: String?

    /// Seconds. 0 when the start is not known.
    var duration: TimeInterval {
        startedAt.map { max(0, finishedAt.timeIntervalSince($0)) } ?? 0
    }
}
