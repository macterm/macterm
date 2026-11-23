import Foundation

/// Pure refresh policy for the session listing that finds the sessions of
/// an older build (`AppState.outdatedSessions`): refresh on session lifecycle
/// events (spawn, kill, reattach) and on a slow reconcile TTL as a safety net
/// against kills outside the app. Owned by `AppState`, consulted inside the poll tick; value
/// type with an injected clock in the `PollCadence` style.
struct ZmxRefreshGate {
    static let reconcileInterval: TimeInterval = 30

    private var invalidated = true
    private var lastRefreshAt: Date?

    /// A session was created, killed, or reattached: the listing is stale.
    mutating func noteSessionLifecycle() {
        invalidated = true
    }

    /// Whether the caller should list the sessions now. Returns true at most once
    /// per invalidation-or-TTL window: asking stamps the refresh, so callers
    /// must actually perform it (a failed run self-heals via the TTL).
    mutating func shouldRefresh(now: Date) -> Bool {
        let ttlElapsed = lastRefreshAt.map { now.timeIntervalSince($0) >= Self.reconcileInterval } ?? true
        guard invalidated || ttlElapsed else { return false }
        invalidated = false
        lastRefreshAt = now
        return true
    }
}
