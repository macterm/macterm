@testable import Macterm
import Testing

struct LinkHeartbeatTests {
    @Test
    func a_ping_that_never_answers_ends_the_check() async {
        await LinkHeartbeat.run(interval: .milliseconds(5), timeout: .milliseconds(20), ping: {
            try await Task.sleep(for: .seconds(60))
            return true
        })
    }

    @Test
    func a_ping_that_throws_ends_the_check() async {
        struct Dead: Error {}
        await LinkHeartbeat.run(interval: .milliseconds(5), timeout: .seconds(5), ping: { throw Dead() })
    }

    @Test
    func a_link_that_answers_keeps_the_check_running_until_it_closes() async {
        let counter = Counter()
        await LinkHeartbeat.run(
            interval: .milliseconds(5), timeout: .seconds(5),
            ping: {
                counter.bump()
                return true
            },
            isOpen: { counter.value < 3 }
        )
        #expect(counter.value >= 3)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }
}
