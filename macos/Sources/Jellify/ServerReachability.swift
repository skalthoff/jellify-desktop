import Foundation
import Observation
@preconcurrency import JellifyCore

/// Tracks whether the Jellyfin server is currently responding successfully.
///
/// This is a *separate* signal from `NetworkMonitor.isOnline` — the system may
/// be online (Wi-Fi up, DNS resolving) while the Jellyfin endpoint itself
/// returns 5xx, refuses connections, or times out. The server-unreachable
/// banner surfaces that second failure mode without conflating it with a
/// network outage.
///
/// Debounce policy: a single 500 from the server should not flash the banner.
/// `noteFailure()` records a timestamp in a rolling window; the reachability
/// flag flips only after `failureThreshold` failures accumulate inside
/// `failureWindow`. A single `noteSuccess()` clears the window and restores
/// reachability immediately — when the server starts answering, users
/// should not have to wait for a decay timer before the banner disappears.
@Observable
@MainActor
final class ServerReachability {
    /// `true` when the server appears to be answering. Starts optimistically
    /// so the banner does not flash on cold launch before the first request.
    var isServerReachable: Bool = true

    /// Number of failures required inside `failureWindow` to flip the flag.
    /// Chosen to tolerate a single transient 500 while still catching a
    /// sustained outage within a couple of seconds of user-visible activity.
    let failureThreshold: Int = 3

    /// Rolling window (seconds) used to evaluate `failureThreshold`.
    let failureWindow: TimeInterval = 10

    /// Timestamps of recent failures inside the rolling window. Trimmed on
    /// every `noteFailure` / `noteSuccess` call so it stays bounded.
    private var recentFailures: [Date] = []

    /// Record a server failure. Timestamps older than `failureWindow` are
    /// discarded; once the count reaches `failureThreshold` the flag flips
    /// to `false`. Callers should use `classifyError` to decide whether a
    /// thrown error counts as a server failure before calling this.
    func noteFailure(at now: Date = Date()) {
        recentFailures.append(now)
        trim(now: now)
        if recentFailures.count >= failureThreshold && isServerReachable {
            isServerReachable = false
        }
    }

    /// Record a successful server interaction. Clears the failure window and
    /// restores reachability immediately — a single good response is strong
    /// evidence the endpoint is healthy again.
    func noteSuccess() {
        recentFailures.removeAll(keepingCapacity: true)
        if !isServerReachable { isServerReachable = true }
    }

    /// Reset to the optimistic state. Used by the Retry CTA so the banner
    /// disappears while the user waits for the refetch to resolve.
    func reset() {
        recentFailures.removeAll(keepingCapacity: true)
        isServerReachable = true
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-failureWindow)
        recentFailures.removeAll { $0 < cutoff }
    }

    /// Decide whether a thrown error should be treated as a server-reachability
    /// failure. Returns `true` for network-level errors (connection refused,
    /// timeout) and for HTTP 5xx responses from the server. 4xx responses are
    /// *not* treated as reachability failures — they signal a client/auth
    /// problem, not that the endpoint is down.
    static func shouldCount(error: Error) -> Bool {
        guard let err = error as? JellifyError else { return false }
        switch err {
        case .Network:
            return true
        case .Server(let message):
            return is5xx(message: message)
        default:
            return false
        }
    }

    /// Parse a server error message of the form
    /// `"server returned an error: <status> <body>"` and return `true` when
    /// `<status>` is in the 500–599 range.
    private static func is5xx(message: String) -> Bool {
        // The Rust side formats `Server` via
        // `#[error("server returned an error: {status} {message}")]`, so the
        // status lives as the first token after the fixed prefix.
        let prefix = "server returned an error: "
        guard let range = message.range(of: prefix) else {
            return false
        }
        let tail = message[range.upperBound...]
        let statusToken = tail.prefix { !$0.isWhitespace }
        guard let status = Int(statusToken) else { return false }
        return (500...599).contains(status)
    }
}
