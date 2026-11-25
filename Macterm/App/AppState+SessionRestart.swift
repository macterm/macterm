import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState+SessionRestart")

/// Restart Session (design/002, option A): a session keeps the build that
/// started it, so after an update some tabs run an older build. The tab
/// shows a badge, and this command gives each such session a new shell of
/// the new build, in the same folder. It ends the old shell, so it runs
/// only when the user asks, and it asks first when a program runs.
extension AppState {
    /// The panes of `tab` whose session runs an older build.
    func outdatedPanes(in tab: TerminalTab) -> [Pane] {
        tab.splitRoot.allPanes().filter { !$0.isRemote && outdatedSessions.contains($0.sessionName) }
    }

    /// Whether a session of `tab` runs an older build.
    func tabRunsOlderSession(_ tab: TerminalTab) -> Bool {
        !outdatedSessions.isEmpty && !outdatedPanes(in: tab).isEmpty
    }

    /// Whether the pane shows the badge: its session runs an older build.
    /// One rule over the panes of every project of the model, so a pane of
    /// the quick terminal or of a desktop widget shows it as a pane of a
    /// project tab does (Ethan, feedback 2026-11-23).
    func showsOutdatedSessionBadge(_ pane: Pane) -> Bool {
        guard !pane.isRemote,
              outdatedSessions.contains(pane.sessionName),
              let tab = model.locate(pane: pane.id)?.tab
        else { return false }
        return !outdatedPanes(in: tab).isEmpty
    }

    /// The badge's click: restart this pane's session.
    func requestRestartSession(of pane: Pane) {
        guard let (projectID, tab) = model.locate(pane: pane.id) else { return }
        requestRestartSessions(tabID: tab.id, projectID: projectID, paneID: pane.id)
    }

    /// The older panes that a restart covers: all of the tab, or one pane.
    private func panesToRestart(in tab: TerminalTab, paneID: UUID?) -> [Pane] {
        let olds = outdatedPanes(in: tab)
        guard let paneID else { return olds }
        return olds.filter { $0.id == paneID }
    }

    /// Restart the older sessions of a tab. A busy pane (a program in front)
    /// asks first: the restart ends that program.
    func requestRestartSessions(tabID: UUID, projectID: UUID, paneID: UUID? = nil) {
        guard let tab = model.tabs(of: projectID).first(where: { $0.id == tabID }) else { return }
        let panes = panesToRestart(in: tab, paneID: paneID)
        guard !panes.isEmpty else { return }
        guard panes.contains(where: paneNeedsConfirmClose) else {
            restartSessions(tabID: tabID, projectID: projectID, paneID: paneID)
            return
        }
        present(PendingDialog(
            kind: .restartSessions(tabID: tabID, projectID: projectID, paneID: paneID),
            title: String(localized: "Restart running processes?"),
            message: String(localized: "A process is still running in this session. Restarting the session ends it."),
            confirmTitle: String(localized: "Restart"),
            host: .mainWindow
        ) { [weak self] in self?.restartSessions(tabID: tabID, projectID: projectID, paneID: paneID) })
    }

    /// Replace each older pane of the tab with a new pane in the folder
    /// where the old shell is (`pane.replace`). The tab keeps its shape,
    /// focus and zoom. The old pane leaves the model, and the server ends
    /// its session with its shell.
    func restartSessions(tabID: UUID, projectID: UUID, paneID: UUID? = nil) {
        guard let tab = model.tabs(of: projectID).first(where: { $0.id == tabID }) else { return }
        let olds = panesToRestart(in: tab, paneID: paneID)
        guard !olds.isEmpty else { return }
        logger.info("restarting \(olds.count, privacy: .public) older session(s)")
        var fresh: [Pane] = []
        for old in olds {
            let pane = Pane(
                projectPath: old.liveLocalWorkingDirectory() ?? old.projectPath,
                projectID: old.projectID,
                sessionSlug: old.sessionSlug
            )
            guard writer.paneReplace(old.id, with: pane) else { continue }
            outdatedSessions.remove(old.sessionName)
            fresh.append(pane)
        }
        for pane in fresh {
            warmIfUnrendered(pane, in: tab)
        }
        persistState()
    }
}
