import Foundation
@testable import Macterm

/// Stands in for the session's leadership rule in a test with no live
/// surface: a delivered claim makes the claimant lead and every other client
/// of the session not lead, and each hears it as the session's `lead`
/// message (`PaneSurface.receiveLead`).
@MainActor
final class FakeSessionLeads {
    /// The surfaces whose claims were sent, in order.
    var claimed: [UUID] = []
    /// False makes every claim fail as a surface with no size does.
    var deliverable = true
    /// False sends the claim but leaves the answer out, as a session that is
    /// a network trip away has not answered yet.
    var answers = true

    init(_ state: AppState) {
        state.sendClaim = { [weak self, weak state] surface in
            guard let self, let state, deliverable else { return false }
            claimed.append(surface.id)
            guard answers else { return true }
            for client in state.clients(of: surface.pane.sessionName) {
                client.receiveLead(client === surface)
            }
            return true
        }
    }

    /// The clients attach in this order: the first leads, as the session
    /// makes the first client of a session with no leader lead.
    func attach(_ surfaces: [PaneSurface]) {
        for (index, surface) in surfaces.enumerated() {
            surface.receiveLead(index == 0)
        }
    }
}
