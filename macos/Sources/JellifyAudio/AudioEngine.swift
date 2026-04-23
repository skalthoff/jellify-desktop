import AVFoundation
import Foundation
@preconcurrency import JellifyCore

// NOTE: `AVAudioSession` is iOS-only and deliberately NOT imported here. On
// macOS there is no session/category concept — `AVPlayer` talks to CoreAudio
// directly. The app keeps playing when the window is minimized or another
// app takes focus because that's the default AppKit behaviour for a regular
// SwiftUI app. Background-audio entitlements are an iOS concept; macOS
// expects `LSApplicationCategoryType = public.app-category.music` in the
// bundle Info.plist instead. See issue #47. Do not reach for
// `AVAudioSession.sharedInstance()` here — the iOS-only symbol won't link,
// and even on a cross-platform build it would just pollute this engine with
// dead code.

/// How long the engine will tolerate `AVPlayer` sitting in
/// `.waitingToPlayAtSpecifiedRate` before treating it as a stall and
/// kicking the stream.
private let stallThreshold: TimeInterval = 5.0

/// Maximum number of silent restart attempts before the engine surfaces a
/// terminal failure to the owner. Two retries covers the "flaky Wi-Fi
/// transient" case without turning a genuine outage into a busy-loop.
private let maxAutoRetries: Int = 2

/// Observer contract for transport failures surfaced by [`AudioEngine`].
///
/// The engine does not render UI — it only tells the owner that the stream
/// stalled (retry in progress) or ultimately failed. See issue #439.
///
/// Every method is `@MainActor`-bound so implementors don't have to hop
/// queues before touching SwiftUI state.
@MainActor
public protocol AudioEngineDelegate: AnyObject {
    /// Called when the engine has been in
    /// `.waitingToPlayAtSpecifiedRate` for longer than the stall threshold
    /// and is about to restart the stream. The owner typically shows a
    /// transient toast ("Stalled, retrying…").
    func audioEngineDidStall()

    /// Called when the engine has exhausted its auto-retry budget. The
    /// owner should surface a terminal error with a tap-to-retry
    /// affordance — the engine will NOT retry again on its own.
    func audioEngineDidFail(_ message: String)
}

/// AVPlayer-backed audio engine. Reports transport state back to the Rust
/// core so other parts of the app can observe it via `core.status()`.
@MainActor
public final class AudioEngine: NSObject {
    private let core: JellifyCore
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    /// The URL + auth header of the item currently loaded into the player.
    /// Captured on `play(_:)` so we can rebuild a fresh `AVPlayerItem` when
    /// recovering from a stall.
    private var currentStreamURL: URL?
    private var currentAuthHeader: String?

    /// Pending stall-detection work item. Scheduled the moment
    /// `timeControlStatus` flips to `.waitingToPlayAtSpecifiedRate`;
    /// cancelled when playback resumes or the engine tears down.
    private var stallWorkItem: DispatchWorkItem?

    /// How many silent restart attempts we've made on the *current* stream.
    /// Reset to 0 every time `play(_:)` loads a brand-new track.
    private var stallRetryCount: Int = 0

    /// Monotonically-increasing counter used to detect stale seek completions
    /// (#582). Each call to `seek(toSeconds:)` increments this; the completion
    /// closure captures the value at dispatch time and discards the callback if
    /// a newer seek has already been issued.
    private var seekGeneration: Int = 0

    /// Called when AVPlayer reaches the end of the current item, so the
    /// owner (AppModel) can advance the queue.
    public var onTrackEnded: (() -> Void)?

    /// Single writer of `MPNowPlayingInfoCenter.nowPlayingInfo`. Held weakly
    /// because the session is owned by `AppModel` — the engine just notifies
    /// it of transport state transitions. See `MediaSession.swift` and
    /// issues #29 / #48.
    public weak var mediaSession: MediaSession?

    /// Receives stall / terminal-failure notifications for issue #439.
    /// Held weakly — the owner (`AppModel`) has the strong reference.
    public weak var delegate: AudioEngineDelegate?

    public init(core: JellifyCore) {
        self.core = core
        super.init()
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
        }
    }

    // MARK: - Public

    public func play(track: Track) throws {
        let urlString = try core.streamUrl(trackId: track.id)
        guard let url = URL(string: urlString) else {
            throw AudioEngineError.invalidURL(urlString)
        }
        let authHeader = try core.authHeader()
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Authorization": authHeader
                ]
            ]
        )
        let item = AVPlayerItem(asset: asset)

        // Tear down the old player cleanly before switching.
        removePlayerObservers()
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        self.player = newPlayer

        // Remember the stream so `recoverFromStall` can rebuild a fresh
        // `AVPlayerItem` without re-asking the core for a URL (which would
        // cost an extra async hop on the main actor).
        self.currentStreamURL = url
        self.currentAuthHeader = authHeader
        // Each new track gets a fresh budget for silent restart attempts —
        // a genuine library-wide outage shouldn't poison the *next* song.
        self.stallRetryCount = 0

        attachPlayerObservers(to: newPlayer, item: item)

        core.markTrackStarted(track: track)
        core.markState(state: .playing)
        newPlayer.play()
        // Publish the new track to MPNowPlayingInfoCenter. `MediaSession`
        // reads the current position via its delegate, so `core.markState`
        // must run first so the snapshot is up to date. See issue #29.
        mediaSession?.trackChanged(track)
    }

    public func pause() {
        player?.pause()
        core.markState(state: .paused)
        // `rateObservation` below also fires `rateChanged`, but that
        // callback is async (Task hop) — calling here keeps the widget in
        // sync within the same run loop turn for responsiveness. Duplicate
        // calls are cheap: MediaSession.rateChanged is idempotent.
        mediaSession?.rateChanged(isPlaying: false)
    }

    public func resume() {
        player?.play()
        core.markState(state: .playing)
        mediaSession?.rateChanged(isPlaying: true)
    }

    public func stop() {
        cancelStallWatchdog()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removePlayerObservers()
        player = nil
        currentStreamURL = nil
        currentAuthHeader = nil
        stallRetryCount = 0
        core.stop()
        mediaSession?.trackChanged(nil)
    }

    public func seek(toSeconds seconds: Double) {
        guard let player = player else { return }
        // #582: Cancel any in-flight seek before issuing the new one so
        // rapid scrubber drags don't race against each other.
        player.currentItem?.cancelPendingSeeks()
        seekGeneration &+= 1
        let generation = seekGeneration
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            // Ignore completions from seeks that were superseded by a
            // newer drag event — `finished` is `false` for pre-empted seeks,
            // but we gate on generation equality instead so we never update
            // elapsed to a stale position even on a race between two seeks
            // that both happen to complete (the earlier one finishing after
            // the later one due to scheduling). Push the post-seek elapsed to
            // MPNowPlayingInfoCenter so the widget confirms the scrub without
            // waiting for the next status tick (issue #32).
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.mediaSession?.seeked(to: seconds)
            }
        }
    }

    public func setVolume(_ v: Float) {
        player?.volume = max(0, min(1, v))
        core.setVolume(volume: v)
    }

    // MARK: - Observers

    private func attachPlayerObservers(to player: AVPlayer, item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds.isFinite ? time.seconds : 0
            self.core.markPosition(seconds: seconds)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }

        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor in
                guard let self = self else { return }
                let isPlaying = rate != 0
                if isPlaying {
                    self.core.markState(state: .playing)
                } else {
                    self.core.markState(state: .paused)
                }
                // Covers implicit rate flips that don't go through
                // pause()/resume() — e.g. buffering-induced stalls. Per
                // issue #48, the widget's progress calc depends on
                // playbackRate being accurate, so any rate change has to
                // publish.
                self.mediaSession?.rateChanged(isPlaying: isPlaying)
            }
        }

        // Stall detection (issue #439). `timeControlStatus` tells us why
        // the player is or isn't moving:
        //   * `.playing` — audio is flowing.
        //   * `.paused` — user-initiated.
        //   * `.waitingToPlayAtSpecifiedRate` — the buffer drained and the
        //     network isn't catching up. AVPlayer already *wants* to play,
        //     so a brief spell here is normal; anything past
        //     `stallThreshold` is a real hang worth kicking.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self = self else { return }
                switch status {
                case .waitingToPlayAtSpecifiedRate:
                    self.scheduleStallWatchdog()
                case .playing, .paused:
                    // Playback recovered (or user paused) — drop any pending
                    // restart so we don't nuke a perfectly healthy stream.
                    self.cancelStallWatchdog()
                @unknown default:
                    break
                }
            }
        }
    }

    private func removePlayerObservers() {
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
        }
        endObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    // MARK: - Stall recovery (issue #439)

    /// Queue a stall handler to fire after [`stallThreshold`]. If
    /// playback resumes within the window the work item is cancelled in
    /// [`cancelStallWatchdog`]; otherwise [`handleStallTimeout`] fires.
    ///
    /// Scheduling is idempotent — repeatedly calling this while the player
    /// keeps flipping in and out of `.waitingToPlayAtSpecifiedRate` only
    /// keeps one timer alive at a time.
    private func scheduleStallWatchdog() {
        stallWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.handleStallTimeout()
            }
        }
        stallWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + stallThreshold, execute: item)
    }

    private func cancelStallWatchdog() {
        stallWorkItem?.cancel()
        stallWorkItem = nil
    }

    /// Called from the watchdog when the player has been stuck in
    /// `.waitingToPlayAtSpecifiedRate` for [`stallThreshold`].
    ///
    /// On the first two stalls of a given stream we notify the delegate
    /// that a silent retry is in flight and rebuild the `AVPlayerItem`
    /// against the same URL — that's enough to dislodge most transient
    /// CDN / Wi-Fi blips. On the third stall we give up and surface a
    /// terminal failure so the UI can offer tap-to-retry.
    private func handleStallTimeout() {
        // Guard against a stale timer firing after the user already
        // stopped the engine or moved on to a different track.
        guard let player = self.player, let url = self.currentStreamURL else {
            return
        }
        // If playback resumed between the timer firing and us getting
        // onto the main actor, bail — no retry needed.
        if player.timeControlStatus != .waitingToPlayAtSpecifiedRate {
            return
        }

        stallRetryCount += 1
        if stallRetryCount > maxAutoRetries {
            delegate?.audioEngineDidFail("Couldn't play, tap to retry.")
            return
        }

        delegate?.audioEngineDidStall()
        recoverFromStall(player: player, url: url)
    }

    /// Rebuild `AVPlayerItem` from the remembered URL + auth header and
    /// swap it in via `replaceCurrentItem`. This restarts the HTTP fetch
    /// without tearing the player down, so `rate` / `timeControlStatus`
    /// observers remain wired and the UI doesn't flicker.
    private func recoverFromStall(player: AVPlayer, url: URL) {
        let options: [String: Any]
        if let header = currentAuthHeader {
            options = [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": header]
            ]
        } else {
            options = [:]
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)

        // `replaceCurrentItem` does NOT re-fire the end-of-item
        // notification for the old item, so we need to re-register the
        // end observer against the freshly-built `AVPlayerItem` or the
        // queue will stop advancing after a stall recovery. Tearing down
        // just the end observer (rather than everything) keeps
        // `rateObservation` / `timeControlObservation` in place — both
        // target the `AVPlayer`, not the item.
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }

        player.replaceCurrentItem(with: item)
        player.play()
    }
}

enum AudioEngineError: LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid stream URL: \(s)"
        }
    }
}
