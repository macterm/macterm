import Darwin

/// What the remote code asks of the user: the notice of an ssh login that
/// waits with no question, and the question before the first server install
/// on a host. The GUI gives it (`SSHLoginPrompts`), so the remote code never
/// names a view. With none, a login shows no notice and an install is
/// declined.
@MainActor
protocol LoginUI: AnyObject {
    /// ssh's last line while a login waits with no question, and nil when
    /// that ends (`SSHLoginNotice`).
    func showNotice(host: String, sshPID: pid_t, line: String?)
    /// The ssh of a login exited: its questions that are still up go away.
    func cancel(sshPID: pid_t)
    /// Asks to install the Macterm server on `host`. False: no.
    func askToInstallServer(on host: String) async -> Bool
}
