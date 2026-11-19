import Foundation
@testable import Macterm
import Testing

/// A host for a `PaneSession` that records what it is given.
final class RecordingPaneHost: PaneSessionHost, @unchecked Sendable {
    struct State {
        var screen = ""
        var exit: (code: UInt8?, signal: UInt8?)?
        var linkLost = 0
        var undelivered = Data()
        var resets = 0
        var foreground: MactermProtocol.Foreground?
        /// Each `lead` message, in order. A nil is an end of the channel.
        var leads: [Bool?] = []
        /// Each set of attention flags, in order.
        var attention: [MactermProtocol.Attention] = []
        /// The bytes of each snapshot that was drawn, in order.
        var snapshots: [String] = []
    }

    private let lock = NSLock()
    private var state = State()
    private var grid: PaneGrid
    private var inSnapshot = false
    /// Runs once, at the first `lead` of true: a pane that moves from the
    /// incubator into its tile after the attach.
    private var onFirstLead: (@Sendable () -> Void)?

    init(grid: PaneGrid = PaneGrid(cols: 80, rows: 24), onFirstLead: (@Sendable () -> Void)? = nil) {
        self.grid = grid
        self.onFirstLead = onFirstLead
    }

    func setGrid(_ new: PaneGrid) {
        lock.lock()
        grid = new
        lock.unlock()
    }

    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Polls until `condition` holds, or fails after 20 s.
    @MainActor
    func waitFor(_ condition: (State) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition(snapshot()) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out: \(snapshot().screen.debugDescription)")
    }

    func paneFeed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data == PaneSession.resetScreen {
            state.resets += 1
            state.screen = ""
        } else {
            let text = String(decoding: data, as: UTF8.self)
            state.screen += text
            if inSnapshot { state.snapshots[state.snapshots.count - 1] += text }
        }
    }

    func paneGrid() -> PaneGrid {
        lock.lock()
        defer { lock.unlock() }
        return grid
    }

    func paneSnapshot(started: Bool) {
        lock.lock()
        inSnapshot = started
        if started { state.snapshots.append("") }
        lock.unlock()
    }

    func paneTtyMode(_: MactermProtocol.TtyMode) {}
    func paneAttention(_ flags: MactermProtocol.Attention) {
        lock.lock()
        state.attention.append(flags)
        lock.unlock()
    }

    func paneLead(_ leader: Bool?) {
        lock.lock()
        state.leads.append(leader)
        let hook = leader == true ? onFirstLead : nil
        if hook != nil { onFirstLead = nil }
        lock.unlock()
        hook?()
    }

    func paneForeground(_ foreground: MactermProtocol.Foreground) {
        lock.lock()
        state.foreground = foreground
        lock.unlock()
    }

    func paneExited(code: UInt8?, signal: UInt8?) {
        lock.lock()
        state.exit = (code, signal)
        lock.unlock()
    }

    func paneLinkLost() {
        lock.lock()
        state.linkLost += 1
        lock.unlock()
    }

    func paneInputUndelivered(_ data: Data) {
        lock.lock()
        state.undelivered.append(data)
        lock.unlock()
    }

    func paneGone() {}
}
