import Foundation

extension Notification.Name {
    static let toggleQuickTerminal = Notification.Name("MactermToggleQuickTerminal")
    static let mactermConfigDidChange = Notification.Name("MactermConfigDidChange")
    static let toggleSidebar = Notification.Name("MactermToggleSidebar")
    static let autoTilingEnabledDidChange = Notification.Name("MactermAutoTilingEnabledDidChange")
    /// Something happened that should wake or speed up the foreground-process
    /// poll: tab switch, OSC title, user interaction, execution-state
    /// transition. Observed by `AppState.notePollEvent()`.
    static let terminalPollEvent = Notification.Name("MactermTerminalPollEvent")
    /// A remote host's link came back after a login (`object` is the
    /// destination, `RemoteHosts`). The other lost panes of that host can
    /// attach with no login: `AppState.reconnectDroppedRemotePanes`.
    static let remoteHostDidConnect = Notification.Name("MactermRemoteHostDidConnect")
    /// A pane's surface received its first real size (`object` is the
    /// surface's id) — the moment a leadership claim can be delivered to it (#345):
    /// a claim before this is refused, and a mirror that came up in the key
    /// window would otherwise never take the pty.
    static let terminalSurfaceSized = Notification.Name("MactermTerminalSurfaceSized")
    /// A surface's client started to lead its session (`object` is the
    /// surface's id): the session's `lead` message. `AppState` lets the key
    /// window claim again when the session chose a client outside it.
    static let terminalSessionLead = Notification.Name("MactermTerminalSessionLead")
    /// A pane's `hasUnacknowledgedBell` flipped (`object` is the pane's id).
    /// Observed by `AppState`, which acknowledges it on the spot when the pane
    /// is already being looked at and re-derives the Dock badge (`BellBadge`).
    static let terminalBellStateDidChange = Notification.Name("MactermTerminalBellStateDidChange")
    /// A final IO heartbeat's quiet deadline. Unlike ordinary poll events,
    /// this must force one poll even when coalescing and window occlusion would
    /// otherwise leave the timer paused.
    static let terminalQuietSettleDeadline = Notification.Name("MactermTerminalQuietSettleDeadline")
    /// A zmx session was created, killed, or reattached — the
    /// `ZmxForegroundResolver` name→leader-pid cache is stale. Observed by
    /// `AppState`, which invalidates its `ZmxRefreshGate` and wakes the poll.
    static let zmxSessionsChanged = Notification.Name("MactermZmxSessionsChanged")
}
