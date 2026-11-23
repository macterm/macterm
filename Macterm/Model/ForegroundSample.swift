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
    /// verdict derives from the remote-side signals instead — the OSC
    /// 133/heartbeat execution state (catches a command mid-output), else
    /// the host's latest report (an idle shell is not worth a dialog;
    /// anything else is). A pane with no report (a host with no server, or
    /// before the first report) falls back to the surface's reading, which
    /// for the ssh client is always busy: never silently kill an unknown
    /// foreground.
    static func needsConfirmClose(
        sample: ForegroundSample?,
        executionState: TerminalExecutionState,
        isRemote: Bool,
        hasSurface: Bool,
        surfaceBusy: @autoclosure () -> Bool
    ) -> Bool {
        guard hasSurface else { return false }
        guard isRemote else { return surfaceBusy() }
        return remoteNeedsConfirmClose(sample: sample, executionState: executionState) ?? surfaceBusy()
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
