import Foundation
@testable import Macterm
import Testing

@MainActor
struct TabCyclerTests {
    @Test
    func a_cycle_walks_its_order_and_finishes_on_the_pick() {
        let cycler = TabCycler()
        let ws = Workspace(id: UUID(), projectPath: "/tmp")
        let ids = [UUID(), UUID(), UUID()]
        cycler.startIfNeeded(recency: ids, in: ws) { [] }
        #expect(cycler.isCycling)
        #expect(cycler.selectedTabID == ids[0])
        #expect(cycler.advance())
        #expect(cycler.selectedTabID == ids[1])
        // A second start while one is in flight keeps the cycle.
        cycler.startIfNeeded(recency: [UUID()], in: ws) { [] }
        #expect(cycler.order == ids)
        cycler.focus(at: 2)
        cycler.focus(at: 7)
        #expect(cycler.finish() == ids[2])
        #expect(!cycler.isCycling)
        #expect(cycler.finish() == nil)
    }

    @Test
    func a_cycle_of_one_tab_does_not_advance() {
        let cycler = TabCycler()
        let ws = Workspace(id: UUID(), projectPath: "/tmp")
        cycler.startIfNeeded(recency: [UUID()], in: ws) { [] }
        #expect(!cycler.advance())
        _ = cycler.finish()
    }
}
