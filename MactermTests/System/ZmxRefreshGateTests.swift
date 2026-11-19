import Foundation
@testable import Macterm
import Testing

struct ZmxRefreshGateTests {
    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t)
    }

    @Test
    func first_ask_refreshes_then_holds_until_ttl() {
        var gate = ZmxRefreshGate()
        #expect(gate.shouldRefresh(now: date(100)) == true)
        // Asking stamped the refresh: quiet until the reconcile TTL.
        #expect(gate.shouldRefresh(now: date(101)) == false)
        #expect(gate.shouldRefresh(now: date(100 + ZmxRefreshGate.reconcileInterval - 1)) == false)
        #expect(gate.shouldRefresh(now: date(100 + ZmxRefreshGate.reconcileInterval)) == true)
    }

    @Test
    func lifecycle_event_forces_a_refresh_before_ttl() {
        var gate = ZmxRefreshGate()
        _ = gate.shouldRefresh(now: date(100))
        gate.noteSessionLifecycle()
        #expect(gate.shouldRefresh(now: date(101)) == true)
        // And the forced refresh restamps the window.
        #expect(gate.shouldRefresh(now: date(102)) == false)
    }

    @Test
    func steady_state_is_at_most_one_refresh_per_interval() {
        var gate = ZmxRefreshGate()
        var refreshes = 0
        // 5 minutes of 250ms polling with no lifecycle events.
        var t = 0.0
        while t < 300 {
            if gate.shouldRefresh(now: date(t)) { refreshes += 1 }
            t += 0.25
        }
        #expect(refreshes == Int(300 / ZmxRefreshGate.reconcileInterval))
    }
}
