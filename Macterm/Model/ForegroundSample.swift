import Foundation

/// One foreground report of a pane's session: the single value the naming
/// and busyness policies read, the same for local and remote panes.
///
/// Shell-ness is the session's verdict (its process groups and its
/// `/etc/shells`), judged where the processes run, with the local database
/// only as a fallback (`Pane.applyForeground`). A policy that reads
/// `isIdleShell` never asks which host's shell database applies.
struct ForegroundSample: Equatable {
    /// Foreground comm basename (normalized), or nil when the report had
    /// nothing. Distinct from "no report came", which is
    /// `Pane.foregroundSample == nil`.
    var name: String?

    /// Whether `name` is a shell that owns its prompt.
    var isIdleShell: Bool

    /// When the report came. The sample is republished only when the report
    /// changes, so this is "first seen", not "last confirmed".
    var sampledAt: Date
}

/// The pure policies every consumer of a pane's foreground state shares.
/// Free functions over (sample, executionState, …) so they are trivially
/// characterization-testable and cannot fork per call site.
enum ForegroundPolicy {
    /// Whether closing must be confirmed because a foreground program is
    /// running — the single verdict behind pane/tab close, project
    /// removal, the CLI's `busy` error, and the quit dialog rows.
    ///
    /// Local panes trust libghostty's own signal (`surfaceBusy`,
    /// `ghostty_surface_needs_confirm_quit`). A remote pane can't: its local
    /// process is the ssh client, a perpetually "running program", so the
    /// verdict derives from the remote-side signals instead — the
    /// session's run state (catches a command mid-output), else
    /// the host's latest report (an idle shell is not worth a dialog;
    /// anything else is). A pane with no report (before the first report,
    /// or a plain shell whose host did not answer, see
    /// `plainShellNeedsConfirmClose`) falls back to the surface's reading.
    /// That reading is busy when the cursor is not at the prompt that OSC
    /// 133 marks. Never silently kill an unknown foreground.
    ///
    /// `surfaceBusy` is the surface's reading, nil for a pane with no
    /// surface, which runs nothing. `confirmClose` is the user's
    /// `confirm-close-surface`. libghostty
    /// applies it to the surface's reading. Only `true` lets a remote pane's
    /// own signals decide: for `false` and `always` the surface's reading
    /// is the verdict for every pane (`ConfirmCloseSurface`).
    static func needsConfirmClose(
        sample: ForegroundSample?,
        executionState: TerminalExecutionState,
        isRemote: Bool,
        confirmClose: ConfirmCloseSurface,
        surfaceBusy: (() -> Bool)?
    ) -> Bool {
        guard let surfaceBusy else { return false }
        guard isRemote, confirmClose.judgesPaneState else { return surfaceBusy() }
        return remoteNeedsConfirmClose(sample: sample, executionState: executionState) ?? surfaceBusy()
    }

    /// The verdict for a pane on a host with no server (a plain shell,
    /// 0494). It has no sample. libghostty reads it as busy when the host's
    /// shell sends no OSC 133 prompt mark. So the close asks the host first
    /// (`HostCommands.shellIsIdle`). `shellIdle` is the host's answer.
    static func plainShellNeedsConfirmClose(shellIdle: Bool, executionState: TerminalExecutionState) -> Bool {
        executionState == .running || !shellIdle
    }

    /// The remote-side busy verdict alone, nil when no sample has ever
    /// landed. Split out so unit tests can exercise the decision without a
    /// live NSView (the surface fallback needs one).
    static func remoteNeedsConfirmClose(
        sample: ForegroundSample?,
        executionState: TerminalExecutionState
    ) -> Bool? {
        if executionState == .running { return true }
        guard let sample, let name = sample.name, !name.isEmpty else { return nil }
        return !sample.isIdleShell
    }
}
