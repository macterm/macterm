import Foundation

/// The backoff of one host's automatic tries (#281, 0264). `RemoteHost`
/// keeps one for each host: N lost panes of one host make one streak, not N.
/// Pure state machine — no clocks, no I/O — so the host owns the triggers,
/// and this type only answers "may the host be tried NOW?". Two properties
/// matter:
///
/// - **It never polls hard.** The sweep runs on triggers, and again every
///   few seconds while a pane is lost and the app is active. The backoff
///   below bounds how often a host that is still unreachable is tried: at
///   most once a minute after the first few tries. Only a sign that the host
///   answers again (`hostAnswered`) clears it early.
/// - **Recovery is judged by survival, not by the attempt.** A connect that
///   came back and dies at once must not clear the streak, so the streak
///   clears only after the host stayed up for `recoveryGrace`.
struct RemoteReconnectPolicy {
    /// Minimum quiet time before the host may be tried again, indexed by its
    /// consecutive-attempt streak (0 attempts → immediate, then escalating;
    /// the last entry repeats).
    static let backoff: [TimeInterval] = [0, 5, 20, 60]

    /// How long the host must stay up after its last attempt before the
    /// attempt is judged successful and its streak resets.
    static let recoveryGrace: TimeInterval = 120

    private var lastAttempt: Date?
    private var streak = 0

    /// Whether the backoff window has elapsed. Does not record — call
    /// `recordAttempt` when the try is actually issued.
    func shouldAttempt(now: Date) -> Bool {
        guard let next = nextAttempt else { return true }
        return now >= next
    }

    /// The first time when `shouldAttempt` is true, or nil when it is true now
    /// whatever the time.
    var nextAttempt: Date? {
        guard let lastAttempt else { return nil }
        return lastAttempt + Self.backoff[min(streak, Self.backoff.count - 1)]
    }

    mutating func recordAttempt(now: Date) {
        streak += 1
        lastAttempt = now
    }

    /// A try of the host failed now. The backoff counts from the end of the
    /// try, not from its start. A host whose server does not answer holds a
    /// try until the handshake gives up (15 s after the login), longer than
    /// the first backoff step: the next try would start at once, and the
    /// badge would never say `Connection Lost`. A failed connect that the
    /// sweep did not start (a pane's first connect, a key) counts as one
    /// try.
    mutating func tryFailed(now: Date) {
        streak = max(streak, 1)
        lastAttempt = now
    }

    /// A sweep found no lost pane on the host. Clears the streak only once
    /// the host has outlived `recoveryGrace` since its last attempt (see the
    /// type comment).
    mutating func observeAlive(now: Date) {
        guard let lastAttempt else { return }
        if now.timeIntervalSince(lastAttempt) >= Self.recoveryGrace { reset() }
    }

    /// The host answers again (its roaming link heard it after a gap): the
    /// next sweep may try it at once. The streak starts again, so a try that
    /// still fails backs off from the start.
    mutating func hostAnswered() {
        reset()
    }

    private mutating func reset() {
        lastAttempt = nil
        streak = 0
    }
}
