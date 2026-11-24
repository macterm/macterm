import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "BellBadge")

/// The Dock badge for unacknowledged bells — `bell-features = attention`'s
/// second half (the first, the dock bounce, is `GhosttyCallbacks.ringBell`).
///
/// The badge is never written from the ring itself. It is DERIVED from the
/// panes' session flags (`Pane.attention.bell`) by `syncDockBadge`, which runs
/// when the flags change, when the config reloads (the feature may have come
/// or gone), and at every structural save (a closed tab leaves the count).
/// That is what lets a config reload that drops `attention` clear a badge
/// that is already up, with no code path that knows about "clearing" at all.
///
/// What counts as seen is Macterm's rule for the done dot, not ghostty's
/// (ghostty clears at the next key or focus gain). A bell in the active tab
/// of the active app is seen when it rings (`markSeenIfActive`). Other bells
/// clear as the done dot does: tab selection, pane focus or input, or the
/// app that comes to the front.
extension AppState {
    /// A pane's flags changed. Mark the pane seen if the user looks at its
    /// tab, then derive the badge. The clear comes back here with no flags
    /// set, so the badge never shows a bell that the user saw.
    func paneAttentionDidChange(paneID: UUID) {
        if let projectID = activeProjectID {
            markSeenIfActive(paneID: paneID, projectID: projectID)
        }
        markSeenIfInKeyPanel(paneID: paneID)
        syncDockBadge()
    }

    /// The quick terminal and the desktop widgets keep their tabs outside
    /// `workspaces` (until the model cut-over, design 010), so
    /// `markSeenIfActive` does not find their panes. Such a pane is seen
    /// while its panel is key: the focused pane of the quick terminal, or
    /// the one pane of a widget. The app need not be active, because both
    /// panels are non-activating. A run end (`onRunEnded`) and a change of
    /// the session's flags both come here, because either can arrive first.
    func markSeenIfInKeyPanel(paneID: UUID) {
        if let quick = adoptedQuickTerminal,
           quick.focusedPaneID == paneID,
           let pane = quick.splitRoot.findPane(id: paneID)
        {
            if paneIsInKeyWindow(pane) { pane.markSeen() }
            return
        }
        guard let pane = desktopWidgets.lazy.compactMap(\.pane).first(where: { $0.id == paneID }),
              paneIsInKeyWindow(pane)
        else { return }
        pane.markSeen()
    }

    /// The app came to the front: whatever tab it shows is now being looked
    /// at. Mirrors ghostty, where the key window's focused surface drops its
    /// bell on `windowDidBecomeKey`; Macterm's unit is the tab.
    func markActiveTabSeenOnActivation() {
        guard let projectID = activeProjectID,
              let pane = workspaces[projectID]?.activeTab?.splitRoot.allPanes().first
        else { return }
        markSeenIfActive(paneID: pane.id, projectID: projectID)
    }

    /// Re-derive the badge from every tab in every workspace (the pinned
    /// sentinel included — its tabs ring like any other) and write it only
    /// when it changed. Mirror (shadow) tabs are not in `workspaces`, so a
    /// tab shown in two windows counts once.
    func syncDockBadge() {
        let features = bellFeatures()
        let count = BellBadge.tabCount(workspaces.values.flatMap(\.tabs))
        let label = BellBadge.label(bellTabCount: count, features: features)
        guard label != dockBadgeLabel else { return }
        let text = label ?? "none"
        logger.debug("dock badge: \(text, privacy: .public) (\(count, privacy: .public) ringing tabs)")
        dockBadgeLabel = label
        dockBadgeWriter(label)
    }
}
