import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateReconnectTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func lostPane(_ host: String) -> Pane {
        let pane = Pane(projectPath: "\(host):/srv", projectID: UUID())
        pane.isRemoteLinkLost = true
        return pane
    }

    /// A policy deep in the backoff for these panes: a try failed a moment
    /// ago, and the next one waits a minute.
    private func backedOff(_ panes: [Pane]) -> (RemoteReconnectPolicy, Date) {
        var policy = RemoteReconnectPolicy()
        var now = epoch
        for delay in RemoteReconnectPolicy.backoff {
            now += delay
            for pane in panes {
                policy.recordAttempt(pane.id, now: now)
            }
        }
        return (policy, now + 1)
    }

    @Test
    func a_host_that_answers_again_tries_its_lost_panes_at_once_and_no_other_host() {
        let box = lostPane("box")
        let other = lostPane("other")
        var (policy, now) = backedOff([box, other])

        // The 5 s sweep keeps the backoff: nothing tries while the host is down.
        let retry = AppState.reconnectSessions([box, other], trigger: .retry, destination: nil, policy: &policy, now: now)
        #expect(retry.sessions.isEmpty)
        #expect(retry.anyLost)

        // The roaming link of `box` hears it after a gap: its pane tries now.
        let answered = AppState.reconnectSessions([box, other], trigger: .hostAnswered, destination: "box", policy: &policy, now: now)
        #expect(answered.sessions == [box.sessionName])

        // The try is recorded: a second event at the same time gives no
        // second try while the first runs.
        box.isRemoteReconnecting = true
        let again = AppState.reconnectSessions([box], trigger: .hostAnswered, destination: "box", policy: &policy, now: now)
        #expect(again.sessions.isEmpty)

        // The other host still waits for its backoff.
        now += 5
        let later = AppState.reconnectSessions([other], trigger: .retry, destination: nil, policy: &policy, now: now)
        #expect(later.sessions.isEmpty)
    }

    @Test
    func a_login_on_the_host_keeps_the_backoff() {
        let box = lostPane("box")
        var (policy, now) = backedOff([box])
        let connected = AppState.reconnectSessions([box], trigger: .hostConnected, destination: "box", policy: &policy, now: now)
        #expect(connected.sessions.isEmpty)
        now += 60
        let retry = AppState.reconnectSessions([box], trigger: .retry, destination: nil, policy: &policy, now: now)
        #expect(retry.sessions == [box.sessionName])
    }

    @Test
    func a_pane_that_is_not_lost_is_not_tried() {
        let pane = Pane(projectPath: "box:/srv", projectID: UUID())
        var policy = RemoteReconnectPolicy()
        let result = AppState.reconnectSessions([pane], trigger: .hostAnswered, destination: "box", policy: &policy, now: epoch)
        #expect(result.sessions.isEmpty)
        #expect(!result.anyLost)
    }
}
