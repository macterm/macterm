import Foundation

/// A pane's run state (`Pane.executionState`), which the pane derives from
/// its session: `running` from the session's status, `done` from its
/// `unseen` flag.
enum TerminalExecutionState: Equatable {
    case idle
    case running
    case done
}
