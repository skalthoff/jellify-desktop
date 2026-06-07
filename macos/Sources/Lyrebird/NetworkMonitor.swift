import Foundation
import Network
import Observation

// MARK: - Network quality hint

/// Coarse network quality classification used to pick an adaptive bitrate
/// ceiling for streaming. Resolved from `NWPath` on each path update — the
/// caller (typically `AppModel+Playback.resolvedStreamingBitrate`) maps this
/// to a concrete `MaxStreamingBitrate` value so playback starts quickly on
/// constrained links instead of buffering at 320 kbps (#447).
///
/// Three tiers are enough to cover the issue-#447 acceptance criteria:
///   - `.unmetered` — Ethernet or a non-metered Wi-Fi path. Stream at full
///     quality (320 kbps or whatever the user picked in Preferences).
///   - `.metered` — a cellular interface, a Wi-Fi path marked "expensive"
///     by the OS (e.g. Personal Hotspot), or any other metered link. Drop
///     to 192 kbps so the first 8 seconds of a track buffer in ~1 second on
///     a 2 Mbps connection.
///   - `.offline` — `NWPath.status != .satisfied`. Used as a sentinel so
///     callers don't need a separate reachability check.
enum NetworkQualityHint {
    /// Ethernet or unmetered Wi-Fi — stream at full quality.
    case unmetered
    /// Cellular or metered Wi-Fi (Personal Hotspot) — reduce bitrate.
    case metered
    /// No usable path; offline.
    case offline

    /// Resolve a `NetworkQualityHint` from a live `NWPath` snapshot.
    ///
    /// Metered heuristic:
    ///   - Any cellular interface is treated as metered regardless of the
    ///     `isExpensive` flag (cellular data has per-byte cost on most plans).
    ///   - A non-cellular path with `isExpensive == true` is also metered (e.g.
    ///     Personal Hotspot tethered over Bluetooth or USB).
    ///   - Wired Ethernet and standard Wi-Fi are unmetered.
    ///
    /// This mirrors the heuristic that iOS uses for its own Low Data Mode:
    /// treat "expensive" as the primary signal, and always flag cellular as
    /// metered independent of the OS flag.
    static func from(_ path: NWPath) -> NetworkQualityHint {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.cellular) || path.isExpensive {
            return .metered
        }
        return .unmetered
    }
}

// MARK: - Network monitor

/// Publishes the system's reachability state. Uses `NWPathMonitor` on a background
/// queue and republishes changes on the main actor so SwiftUI views can bind to
/// `isOnline` without manual dispatch.
///
/// The monitor debounces flaky transitions: a path that reports `satisfied` is
/// only treated as "online" after the state has held steady for a short window.
/// Going offline is applied immediately so the banner surfaces right away.
///
/// In addition to the binary `isOnline` flag the monitor also publishes a
/// `qualityHint` (`NetworkQualityHint`) that downstream components — most
/// notably `AppModel+Playback.resolvedStreamingBitrate` — use to pick an
/// adaptive bitrate ceiling for the current connection (#447).
@Observable
@MainActor
final class NetworkMonitor {
    /// `true` when the system reports a usable network path. Starts `true`
    /// optimistically so the banner does not flash on cold launch.
    var isOnline: Bool = true

    /// Coarse quality classification of the current path. Updated on every
    /// `NWPathMonitor` callback alongside `isOnline`. Starts `.unmetered`
    /// optimistically so cold-launch streaming is not throttled before the
    /// first path report arrives. Callers that care about metered links
    /// should read this immediately before building a stream URL (i.e., at
    /// `play(track:)` time) rather than caching it, since the link may change.
    var qualityHint: NetworkQualityHint = .unmetered

    private var monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.lyrebird.network-monitor")
    private var stableOnlineTask: Task<Void, Never>?

    init() {
        self.monitor = NWPathMonitor()
        start()
    }

    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let hint = NetworkQualityHint.from(path)
            Task { @MainActor in
                self.apply(satisfied: satisfied, hint: hint)
            }
        }
        monitor.start(queue: queue)
    }

    private func apply(satisfied: Bool, hint: NetworkQualityHint) {
        stableOnlineTask?.cancel()
        stableOnlineTask = nil

        // Always update the quality hint immediately — both going offline and
        // switching from Wi-Fi to cellular should drop the bitrate right away.
        qualityHint = hint

        if !satisfied {
            // Offline is applied immediately so users see the banner fast.
            if isOnline { isOnline = false }
            return
        }

        // Debounce coming back online to avoid flicker on flaky networks.
        stableOnlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000) // 0.75s
            guard let self, !Task.isCancelled else { return }
            if !self.isOnline { self.isOnline = true }
        }
    }

    /// Force a fresh path evaluation. Cancels the existing monitor and starts a
    /// new one so the next `pathUpdateHandler` fires with a current snapshot.
    func retry() {
        stableOnlineTask?.cancel()
        stableOnlineTask = nil
        monitor.cancel()
        monitor = NWPathMonitor()
        start()
    }
}
