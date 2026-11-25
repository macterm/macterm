import Foundation

/// The quick terminal's place in the model: the hidden project with the
/// alias `quick` (design/010 §11). The server keeps its tab, so its panes'
/// sessions are claims like any pane's, and a quit is silent.
///
/// `AppState` reaches the panel's state through `adoptQuickTerminal`, once:
/// the panel's singleton by default, or one handed to `init` by tests. The
/// state is a view over this AppState's model.
extension AppState {
    /// The adopted split state, adopting the panel's singleton on first use.
    var quickTerminal: QuickTerminalSplitState {
        if let adopted = adoptedQuickTerminal { return adopted }
        let state = QuickTerminalService.shared.splitState
        adoptQuickTerminal(state)
        return state
    }

    /// Make `state` the quick terminal of this AppState's model.
    func adoptQuickTerminal(_ state: QuickTerminalSplitState) {
        adoptedQuickTerminal = state
        state.app = self
    }

    /// The launch restore: the quick terminal's project and its one tab, made
    /// when the model does not have them.
    func restoreQuickTerminal() {
        quickTerminal.ensureTab()
    }
}
