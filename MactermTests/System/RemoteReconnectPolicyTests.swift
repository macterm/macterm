import Foundation
@testable import Macterm
import Testing

struct RemoteReconnectPolicyTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func first_attempt_is_immediate() {
        let policy = RemoteReconnectPolicy()
        #expect(policy.shouldAttempt(now: epoch))
    }

    @Test
    func backoff_escalates_with_consecutive_attempts() {
        var policy = RemoteReconnectPolicy()
        var now = epoch

        // 1st attempt recorded → 2nd gated by backoff[1] (5s).
        policy.recordAttempt(now: now)
        #expect(!policy.shouldAttempt(now: now + 4))
        #expect(policy.shouldAttempt(now: now + 5))

        // 2nd attempt → gated by backoff[2] (20s).
        now += 5
        policy.recordAttempt(now: now)
        #expect(!policy.shouldAttempt(now: now + 19))
        #expect(policy.shouldAttempt(now: now + 20))

        // 3rd attempt → backoff[3] (60s), and the last entry repeats for
        // every attempt after (a host down for a day gets one attempt per
        // ≥60s-spaced trigger, never a tighter loop).
        now += 20
        policy.recordAttempt(now: now)
        #expect(!policy.shouldAttempt(now: now + 59))
        #expect(policy.shouldAttempt(now: now + 60))
        now += 60
        policy.recordAttempt(now: now)
        #expect(!policy.shouldAttempt(now: now + 59))
        #expect(policy.shouldAttempt(now: now + 60))
    }

    @Test
    func alive_observation_resets_the_streak_only_after_the_grace_period() {
        var policy = RemoteReconnectPolicy()
        policy.recordAttempt(now: epoch)

        // A dial still in flight looks alive (processExited == false) for up
        // to the TCP connect timeout — it must NOT reset the backoff.
        policy.observeAlive(now: epoch + 30)
        #expect(!policy.shouldAttempt(now: epoch + 1))

        // Surviving past the grace window means the reconnect really took.
        policy.observeAlive(now: epoch + RemoteReconnectPolicy.recoveryGrace)
        policy.recordAttempt(now: epoch + 200)
        // Streak restarted at 1 → back to the 5s gate, not 20s.
        #expect(policy.shouldAttempt(now: epoch + 205))
    }

    @Test
    func a_host_that_answers_again_may_try_at_once_and_backs_off_from_the_start() {
        var policy = RemoteReconnectPolicy()
        var now = epoch
        for delay in RemoteReconnectPolicy.backoff {
            now += delay
            policy.recordAttempt(now: now)
        }
        // Deep in the backoff: the next try waits a minute.
        #expect(!policy.shouldAttempt(now: now + 1))
        policy.hostAnswered()
        #expect(policy.shouldAttempt(now: now + 1))
        // A try that still fails waits the first step again, not a minute.
        policy.recordAttempt(now: now + 1)
        #expect(!policy.shouldAttempt(now: now + 5))
        #expect(policy.shouldAttempt(now: now + 6))
    }

    @Test
    func the_next_attempt_is_the_last_attempt_and_its_step() {
        var policy = RemoteReconnectPolicy()
        #expect(policy.nextAttempt == nil)
        policy.recordAttempt(now: epoch)
        #expect(policy.nextAttempt == epoch + 5)
        policy.tryFailed(now: epoch + 20)
        #expect(policy.nextAttempt == epoch + 25)
    }

    /// The backoff counts from the end of a failed try: a try that lasts
    /// longer than the backoff does not start the next try at once.
    @Test
    func a_failed_try_starts_the_backoff_at_its_end() {
        var policy = RemoteReconnectPolicy()
        policy.recordAttempt(now: epoch)
        // The try runs for 20 s, longer than the 5 s step, and fails.
        let end = epoch + 20
        #expect(policy.shouldAttempt(now: end))
        policy.tryFailed(now: end)
        #expect(!policy.shouldAttempt(now: end + 4))
        #expect(policy.shouldAttempt(now: end + 5))
        // The next try fails too: the step after it is 20 s from its end.
        policy.recordAttempt(now: end + 5)
        policy.tryFailed(now: end + 25)
        #expect(!policy.shouldAttempt(now: end + 44))
        #expect(policy.shouldAttempt(now: end + 45))
    }

    /// A failed connect that the sweep did not start (the pane's first
    /// connect after a restart) counts as one try: the sweep waits 5 s.
    @Test
    func a_failed_first_connect_waits_the_first_step() {
        var policy = RemoteReconnectPolicy()
        policy.tryFailed(now: epoch)
        #expect(!policy.shouldAttempt(now: epoch + 4))
        #expect(policy.shouldAttempt(now: epoch + 5))
    }
}
