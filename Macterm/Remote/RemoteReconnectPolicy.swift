import Foundation

/// The backoff of one host's automatic tries (#281, 0264). `RemoteHost`
/// keeps one for each host: N lost panes of one host make one streak, not N.
/// It is a pure state machine with no clock and no I/O. The host owns the
/// triggers, and this type only says if the host may be tried now.
///
/// - The sweep runs on triggers, and again every few seconds while a pane
///   is lost and the app is active. The backoff tries a host that stays
///   unreachable at most once a minute after the first few tries.
/// - A connect that works (`connected`) or a host that answers again
///   (`hostAnswered`) clears the streak. The other lost panes of the host
///   then try at once.
struct RemoteReconnectPolicy {
    /// The time to wait before the next try, by the number of tries in a row
    /// (0 tries: no wait). The last step repeats.
    static let backoff: [TimeInterval] = [0, 5, 20, 60]

    private var lastAttempt: Date?
    private var streak = 0

    /// Whether the backoff window has passed. It records nothing: call
    /// `recordAttempt` when the try starts.
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

    /// The host is reachable again: a connect to it worked (a key, a sweep, a
    /// new pane), or its roaming link heard it after a gap. Its other lost
    /// panes may try at once. A try that then fails backs off from the start.
    mutating func clear() {
        lastAttempt = nil
        streak = 0
    }
}
