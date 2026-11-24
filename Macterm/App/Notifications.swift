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
    /// A remote pane became lost (its link stopped, or a try failed): the
    /// reconnect sweep runs (`AppState.reconnectDroppedRemotePanes`).
    static let remoteLinkDidStop = Notification.Name("MactermRemoteLinkDidStop")
    /// A remote host's link came back after a login (`object` is the
    /// destination, `RemoteHosts`). The other lost panes of that host can
    /// attach with no login: `AppState.reconnectDroppedRemotePanes`.
    static let remoteHostDidConnect = Notification.Name("MactermRemoteHostDidConnect")
    /// A roaming link heard its host after a gap (`object` is the
    /// destination, `RemoteHosts`). The lost panes of that host try now,
    /// with no backoff: `AppState.reconnectDroppedRemotePanes`.
    static let remoteHostDidAnswer = Notification.Name("MactermRemoteHostDidAnswer")
    /// A pane's surface received its first real size (`object` is the
    /// surface's id). A leadership claim before it is refused, so the key
    /// window claims again (#345).
    static let terminalSurfaceSized = Notification.Name("MactermTerminalSurfaceSized")
    /// The session's first `lead` message for a surface after an attach, or
    /// one that says it leads (`object` is the surface's id). The key window
    /// claims again (`AppState.claimLeadershipForKeyWindow`).
    static let terminalSessionLead = Notification.Name("MactermTerminalSessionLead")
    /// A pane's `attention` flags changed (`object` is the pane's id).
    /// Observed by `AppState`, which marks the pane seen on the spot when the
    /// user already looks at it and derives the Dock badge again (`BellBadge`).
    static let paneAttentionDidChange = Notification.Name("MactermPaneAttentionDidChange")
    /// A zmx session was created, killed, or reattached: the session listing
    /// is stale. Observed by `AppState`, which invalidates its
    /// `ZmxRefreshGate` and wakes the poll.
    static let zmxSessionsChanged = Notification.Name("MactermZmxSessionsChanged")
}
