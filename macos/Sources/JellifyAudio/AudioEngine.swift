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

    /// Called when AVPlayer reaches the end of the current item, so the
    /// owner (AppModel) can advance the queue.
    public var onTrackEnded: (() -> Void)?

    /// Single writer of `MPNowPlayingInfoCenter.nowPlayingInfo`. Held weakly
    /// because the session is owned by `AppModel` — the engine just notifies
    /// it of transport state transitions. See `MediaSession.swift` and
    /// issues #29 / #48.
    public weak var mediaSession: MediaSession?

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
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removePlayerObservers()
        player = nil
        core.stop()
        mediaSession?.trackChanged(nil)
    }

    public func seek(toSeconds seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // Push the post-seek elapsed to MPNowPlayingInfoCenter inside
            // the completion handler so the widget confirms the scrub
            // without waiting for the next status tick. See issue #32.
            Task { @MainActor in
                self?.mediaSession?.seeked(to: seconds)
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
