import AVFoundation
import Foundation
@preconcurrency import JellifyCore

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
    }

    public func pause() {
        player?.pause()
        core.markState(state: .paused)
    }

    public func resume() {
        player?.play()
        core.markState(state: .playing)
    }

    public func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removePlayerObservers()
        player = nil
        core.stop()
    }

    public func seek(toSeconds seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
            Task { @MainActor in
                guard let self = self else { return }
                if player.rate == 0 {
                    self.core.markState(state: .paused)
                } else {
                    self.core.markState(state: .playing)
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
