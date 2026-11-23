import Foundation
@testable import Macterm
import Testing

/// The sweep finds the hosts of the lost panes. Each host applies its own
/// backoff (`RemoteHostTests`).
@MainActor
struct AppStateReconnectTests {
    private func lostPane(_ host: String) -> Pane {
        let pane = Pane(projectPath: "\(host):/srv", projectID: UUID())
        pane.setRemoteLink(lost: true)
        return pane
    }

    @Test
    func the_sweep_tries_each_host_of_a_lost_pane_once() {
        let panes = [lostPane("box"), lostPane("box"), lostPane("other")]
        #expect(AppState.lostDestinations(panes, destination: nil) == ["box", "other"])
    }

    @Test
    func a_host_event_tries_only_that_host() {
        let panes = [lostPane("box"), lostPane("other")]
        #expect(AppState.lostDestinations(panes, destination: "box") == ["box"])
    }

    @Test
    func a_pane_that_is_not_lost_is_not_tried() {
        let live = Pane(projectPath: "box:/srv", projectID: UUID())
        let local = Pane(projectPath: "/tmp", projectID: UUID())
        local.setRemoteLink(lost: true)
        #expect(AppState.lostDestinations([live, local], destination: nil).isEmpty)
    }
}
