import Foundation
@preconcurrency import LyrebirdCore

/// Push-driven player status (#433).
///
/// The old `startPolling()` fired a repeating `Timer` whose tick re-read
/// `core.status()` on the main actor — taking the Rust player mutex and
/// republishing `@Observable` state once a second even while paused in the
/// background (~3,600 wakes/hour at idle). The core now *pushes* on the
/// mutations that can actually change what the UI shows — state transitions
/// (`markState` / `markTrackStarted` / `stop`), current-track changes, and
/// queue changes — through the `PlayerObserver` UniFFI callback interface,
/// so an idle app does zero periodic status work.
///
/// Position is the one per-second quantity, and it keeps its existing owner:
/// `AudioEngine`'s 1 Hz `periodicTimeObserver`, which already skips entirely
/// at `rate == 0`, now also forwards each tick here (`handlePositionTick`)
/// so the progress surfaces advance without any core FFI on the UI path.
///
/// Net wake budget: zero when idle or paused (no timer exists at all),
/// 1 Hz position ticks only while audio is audibly advancing — strictly
/// at-or-below the rc13 contract this replaces (see CLAUDE.md gap #2).
///
/// History, so nobody re-walks it: rc11/rc12 tried keeping the poll but
/// gating its body on `status.state == .playing`. That froze the PlayerBar
/// after the first pause — `pause()` / `resume()` delegate straight to
/// `AudioEngine` and nothing else republished `status`, so the gate locked
/// itself shut (rc12 regression). rc13 reverted to an ungated 1 s poll
/// (~3,600 wakes/hour paused). Pushes solve the dilemma both ways: every
/// `markState` transition publishes (no frozen UI), and the absence of
/// transitions costs nothing (no wakes).
extension AppModel {
    /// Subscribe `status` to the core's player event stream. Called wherever
    /// a session becomes live (login, Quick Connect, restore); replaces any
    /// previous subscription, so repeated calls are safe.
    ///
    /// Seeds `status` with one synchronous snapshot first — pushes only
    /// arrive on the *next* mutation, and a restored session may already
    /// hold meaningful player state.
    func startStatusEventStream() {
        let bridge = PlayerEventBridge(model: self)
        playerEventBridge = bridge
        core.setPlayerObserver(observer: bridge)
        status = core.status()
    }

    /// Tear down the event-stream subscription (logout, token forget, auth
    /// expiry). Player mutations after this emit nothing.
    func stopStatusEventStream() {
        core.clearPlayerObserver()
        playerEventBridge = nil
    }

    /// Apply one player push to the reactive surface. Runs on the main actor
    /// (marshalled by `PlayerEventBridge`); `fresh` is the complete
    /// post-mutation snapshot the core captured under its player lock.
    ///
    /// This is the old poll-tick body, fired on change instead of on a
    /// timer: it republishes `status`, keeps the Dock tile + scrobble gate
    /// fed, runs the track-change side effects (session history, credits +
    /// lyrics refetch, notification banner), and nudges `MediaSession` when
    /// the queue shape moved.
    func applyPlayerEvent(seq: UInt64, kinds: [PlayerEventKind], status fresh: PlayerStatus) {
        // Pushes are stamped in mutation order under the core's player lock,
        // but each crosses to the main actor as its own `Task` hop — so a
        // pair of rapid mutations could, in principle, land here reordered.
        // Applying an older snapshot over a newer one would wedge the UI on
        // stale state until the next event, so drop anything not strictly
        // newer than the last applied push.
        guard seq > lastPlayerEventSeq else { return }
        lastPlayerEventSeq = seq

        let beforeTrack = status.currentTrack
        let before = beforeTrack?.id
        status = fresh
        let after = fresh.currentTrack?.id

        // Keep the custom Dock tile in sync with state/track transitions —
        // pause/resume flips the ring style, stop tears the tile down. The
        // per-second ring fill while playing is driven by
        // `handlePositionTick`; the controller throttles its own redraws to
        // ≤1 Hz, so overlapping calls stay cheap.
        AppDelegate.shared?.refreshDockTile()

        // Feed the scrobble gate the fresh status. Fires a ListenBrainz
        // `playing_now` on track change — both submit paths hop off the main
        // actor inside `driveScrobble`.
        driveScrobble()

        // Track-change side effects. Diffed against the previously-applied
        // snapshot (not just `kinds`) so an inline `status = core.status()`
        // refresh that already mirrored this mutation can't double-fire
        // them.
        if before != after {
            // Record the track we just left onto the in-session history
            // (#81). Only push real outgoing tracks — a start-from-stopped
            // transition (before == nil) has nothing to record.
            if let outgoing = beforeTrack {
                recordSessionPlay(outgoing)
            }
            if after == nil {
                currentTrackPeople = []
                currentTrackPeopleForId = nil
                currentLyrics = nil
                currentLyricsForId = nil
            } else {
                Task { await self.fetchCurrentTrackDetails() }
                Task { await self.fetchCurrentTrackLyrics() }
                // Notify on the new track. The manager no-ops when the
                // banner toggle is off, so this is cheap on every change.
                if let track = fresh.currentTrack {
                    NotificationManager.shared.notifyTrackChange(
                        title: track.name,
                        artist: track.artistName,
                        album: track.albumName
                    )
                }
            }
        }

        // Keep MediaSession's queue index in sync when a skip or queue edit
        // happens. `AudioEngine.play(track:)` already fires `trackChanged`
        // for the new item; `queueChanged` covers shape changes that don't
        // start a new track. Elapsed time is intentionally NOT pushed here
        // (see issue #48 — the widget interpolates from
        // `elapsed + wallclock * rate`).
        if kinds.contains(.queueChanged) {
            mediaSession.queueChanged()
        }
    }

    /// 1 Hz position tick from `AudioEngine`'s periodic time observer,
    /// forwarded only while audio is actually advancing (`rate != 0`) —
    /// paused and idle states produce no ticks, preserving the zero-wake
    /// contract. Mirrors the position the engine just wrote into the core
    /// (`core.markPosition`) onto the reactive surface, with no extra FFI.
    func handlePositionTick(seconds: Double) {
        // A tick can race a teardown push (stop / track end) across the
        // main-actor hop; never resurrect a position onto a stopped surface.
        guard status.currentTrack != nil else { return }
        status.positionSeconds = seconds
        // Advance the Dock tile's progress ring in real time (≤1 Hz redraw
        // throttle lives in the controller).
        AppDelegate.shared?.refreshDockTile()
        // Threshold check for the durable ListenBrainz listen — position-
        // driven, so it belongs to the tick, not the event stream.
        driveScrobble()
    }
}

/// UniFFI callback bridge for the core's player event stream (#433).
///
/// The core invokes `playerChanged` synchronously on whatever thread
/// performed the player mutation (the main thread for user actions, but the
/// contract makes no promise); the bridge marshals onto the main actor
/// before touching `AppModel` — the same shape as `LibrarySyncBridge`.
/// No core lock is held during the callback, so the hop is the only
/// scheduling this needs.
///
/// Holds the model weakly: a push outliving the model (quit, teardown) just
/// drops. `@unchecked Sendable`: the only state is a `weak` reference
/// assigned once in `init`; ARC weak loads are thread-safe, and all reads
/// happen inside the main-actor hop.
final class PlayerEventBridge: PlayerObserver, @unchecked Sendable {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func playerChanged(seq: UInt64, kinds: [PlayerEventKind], status: PlayerStatus) {
        let model = model
        Task { @MainActor in
            model?.applyPlayerEvent(seq: seq, kinds: kinds, status: status)
        }
    }
}
