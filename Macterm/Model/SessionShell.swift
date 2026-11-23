import Darwin

/// A local session's shell, from the pane channel's `state` message: the
/// pty's leader and the pty. `ProcessInspector` reads the foreground from it
/// where a pid is necessary (the password asker, a layout's `run:`).
struct SessionShell: Equatable {
    let pid: pid_t
    let ttyPath: String?
}
