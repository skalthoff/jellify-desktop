import AppKit
import Foundation
@preconcurrency import JellifyCore
import MediaPlayer

/// Abstraction the `MediaSession` uses to route remote-command events
/// (play/pause from Control Center, media keys, Bluetooth headsets, etc.)
/// back into the app's normal transport layer.
///
/// The command handlers stay side-effect-minimal by design: they call through
/// to these methods rather than poking `AudioEngine` directly, so the same
/// code path runs whether a human or a Bluetooth headset triggers playback
/// changes. See issue #31.
@MainActor
public protocol MediaSessionDelegate: AnyObject {
    var currentStatus: PlayerStatus { get }
    func mediaSessionTogglePlayPause()
    func mediaSessionPlay()
    func mediaSessionPause()
    func mediaSessionStop()
    func mediaSessionSkipNext()
    func mediaSessionSkipPrevious()
    func mediaSessionSeek(toSeconds seconds: Double)
    /// Build the artwork URL for a track. Returns `nil` when the track has no
    /// image tag or when the auth context isn't ready. `MediaSession` uses
    /// this rather than holding a reference to `JellifyCore` so the session
    /// can be unit-tested with a mock delegate.
    func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL?
    /// Authorization header value for artwork fetches. Matches the header
    /// `AudioEngine` attaches to `AVURLAsset` so the Jellyfin server accepts
    /// the image request.
    func mediaSessionAuthorizationHeader() -> String?
}

/// Single writer of `MPNowPlayingInfoCenter.default().nowPlayingInfo` and
/// owner of `MPRemoteCommandCenter.shared()` handlers. Every other system
/// integration (Control Center, AVRCP, media keys, Dock) reads through this;
/// `nowPlayingInfo` is mutated from exactly one place so `elapsedPlaybackTime`
/// and `playbackRate` stay consistent. See issues #29, #30, #31, #32, #47, #48.
///
/// Update strategy (issue #48): elapsed + rate are only written on state
/// transitions (track change, play, pause, seek). The Control Center widget
/// computes progress from
/// `elapsed + (wallClockNow - lastUpdateTime) * playbackRate`, so continuously
/// pushing elapsed on every 0.5s tick causes the scrubber to stutter. The
/// Rust-side `core.markPosition` tick (used for scrobbling thresholds and UI
/// updates) is intentionally NOT fed to `MPNowPlayingInfoCenter`.
@MainActor
public final class MediaSession {
    private weak var delegate: MediaSessionDelegate?
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkTask: Task<Void, Never>?
    private var currentTrackID: String?

    /// Construct the session with no delegate. Call `attach(delegate:)` from
    /// the owner's initializer once `self` is available. This two-phase
    /// hand-off lets the delegate (`AppModel`) own the session as a
    /// non-optional `let` without fighting Swift's initialization order.
    public init() {
        configureRemoteCommands()
    }

    /// Wire up the delegate. Idempotent — replacing a delegate is safe, but
    /// the expected pattern is to call this exactly once from `AppModel.init`.
    public func attach(delegate: MediaSessionDelegate) {
        self.delegate = delegate
        refreshRemoteCommandEnablement()
    }

    deinit {
        artworkTask?.cancel()
    }

    // MARK: - Public transition hooks
    //
    // `AudioEngine` / `AppModel` call these when a state change happens. They
    // are the only paths that touch `MPNowPlayingInfoCenter.nowPlayingInfo`,
    // which is how issue #29's "single writer" invariant is enforced.

    /// Called when the currently-playing track changes (or becomes `nil`).
    /// Writes the full property set (title/artist/album/duration/queue) and
    /// kicks off an async artwork fetch. Resets elapsed to zero and pushes
    /// the initial rate based on `status.state`.
    public func trackChanged(_ track: Track?) {
        guard let delegate else { return }

        if track == nil {
            currentTrackID = nil
            artworkTask?.cancel()
            artworkTask = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            refreshRemoteCommandEnablement()
            return
        }

        let track = track!
        currentTrackID = track.id

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.name
        info[MPMediaItemPropertyArtist] = track.artistName
        if let album = track.albumName, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        info[MPMediaItemPropertyAlbumArtist] = track.artistName
        // `Track.durationSeconds` lives as a Swift convenience in the
        // top-level app target; compute the same thing inline here so
        // `JellifyAudio` doesn't need to depend on it.
        info[MPMediaItemPropertyPlaybackDuration] = Double(track.runtimeTicks) / 10_000_000.0
        info[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        let status = delegate.currentStatus
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, status.positionSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = status.state == .playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if status.queueLength > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = NSNumber(value: status.queuePosition)
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = NSNumber(value: status.queueLength)
        }

        // Keep the previous artwork in place until the new one decodes —
        // clearing it first shows a blank square mid-transition (see #30).
        if let cached = artworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = cached
        } else if let lastArt = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = lastArt
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Kick off artwork fetch. Cancels any in-flight fetch for the
        // previous track so rapid skip-next doesn't show the prior track's
        // art (acceptance criterion on #30).
        artworkTask?.cancel()
        let trackID = track.id
        artworkTask = Task { [weak self] in
            await self?.loadArtwork(for: track, expectedTrackID: trackID)
        }

        refreshRemoteCommandEnablement()
    }

    /// Called when the AVPlayer rate flips between 0 and 1 (play <-> pause).
    /// Updates `elapsedPlaybackTime` + `playbackRate` so Bluetooth AVRCP
    /// doesn't see a stale rate.
    public func rateChanged(isPlaying: Bool) {
        guard let delegate, currentTrackID != nil else { return }
        updateElapsedAndRate(
            elapsed: delegate.currentStatus.positionSeconds,
            rate: isPlaying ? 1.0 : 0.0
        )
    }

    /// Called after the engine seeks to a new position. Updates
    /// `elapsedPlaybackTime` immediately so the widget confirms the scrub
    /// without waiting for the next position tick (issue #32).
    public func seeked(to seconds: Double) {
        guard let delegate, currentTrackID != nil else { return }
        let rate: Float = delegate.currentStatus.state == .playing ? 1.0 : 0.0
        updateElapsedAndRate(elapsed: seconds, rate: rate)
    }

    /// Called when the queue position or length changes (skip next/prev,
    /// setQueue). Refreshes the queue index on the now-playing info and
    /// re-evaluates `nextTrackCommand` / `previousTrackCommand` enablement.
    public func queueChanged() {
        guard let delegate, currentTrackID != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let status = delegate.currentStatus
        if status.queueLength > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = NSNumber(value: status.queuePosition)
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = NSNumber(value: status.queueLength)
        } else {
            info.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueIndex)
            info.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueCount)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        refreshRemoteCommandEnablement()
    }

    // MARK: - Internals

    private func updateElapsedAndRate(elapsed: Double, rate: Float) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote command center

    private func configureRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.delegate?.mediaSessionPlay()
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.delegate?.mediaSessionPause()
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            if delegate.currentStatus.currentTrack == nil {
                return .noActionableNowPlayingItem
            }
            delegate.mediaSessionTogglePlayPause()
            return .success
        }

        cc.stopCommand.isEnabled = false
        cc.stopCommand.addTarget { [weak self] _ in
            guard let self, let delegate = self.delegate else {
                return .commandFailed
            }
            if delegate.currentStatus.currentTrack == nil {
                return .noActionableNowPlayingItem
            }
            delegate.mediaSessionStop()
            return .success
        }

        cc.nextTrackCommand.isEnabled = false
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.delegate?.mediaSessionSkipNext()
            return .success
        }

        cc.previousTrackCommand.isEnabled = false
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.delegate?.mediaSessionSkipPrevious()
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let delegate = self.delegate,
                delegate.currentStatus.currentTrack != nil,
                let seek = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            delegate.mediaSessionSeek(toSeconds: seek.positionTime)
            // Update elapsed right away so the widget confirms the scrub
            // without a 0.5s lag (issue #32).
            self.updateElapsedAndRate(
                elapsed: seek.positionTime,
                rate: delegate.currentStatus.state == .playing ? 1.0 : 0.0
            )
            return .success
        }

        // Commands explicitly not wired yet (BATCH-14 / #35 / #38):
        // likeCommand, dislikeCommand, changeShuffleModeCommand,
        // changeRepeatModeCommand. Leaving them at their default-disabled
        // state so they don't appear in Control Center.
    }

    private func refreshRemoteCommandEnablement() {
        guard let delegate else { return }
        let status = delegate.currentStatus
        let cc = MPRemoteCommandCenter.shared()
        let hasTrack = status.currentTrack != nil
        cc.stopCommand.isEnabled = hasTrack
        // Next/previous gate on queue bounds. Repeat/shuffle-driven
        // rebinding is BATCH-14; until then the bounds check is strict.
        if status.queueLength == 0 {
            cc.nextTrackCommand.isEnabled = false
            cc.previousTrackCommand.isEnabled = false
        } else {
            cc.nextTrackCommand.isEnabled = status.queuePosition + 1 < status.queueLength
            cc.previousTrackCommand.isEnabled = status.queuePosition > 0
        }
    }

    // MARK: - Artwork

    /// Fetch and publish artwork for `track`. `expectedTrackID` is checked
    /// against `currentTrackID` before every write so a late-arriving image
    /// never overwrites a subsequent track's artwork (see #30).
    private func loadArtwork(for track: Track, expectedTrackID: String) async {
        guard let delegate else { return }

        // Cached hit from a prior play of the same track — publish
        // immediately without a network hop.
        if let cached = artworkCache[track.id] {
            guard currentTrackID == expectedTrackID else { return }
            publishArtwork(cached)
            return
        }

        guard track.imageTag != nil,
              let url = delegate.mediaSessionArtworkURL(for: track, maxWidth: 600)
        else {
            // No artwork available. Leave whatever was previously displayed
            // in place rather than clearing — matches Apple Music behaviour.
            return
        }

        var request = URLRequest(url: url)
        if let auth = delegate.mediaSessionAuthorizationHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else { return }
            // Only publish if the track hasn't changed mid-flight.
            guard currentTrackID == expectedTrackID else { return }

            // macOS honours the size callback; feed it a resized NSImage so
            // the widget doesn't carry a full-resolution copy around.
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
                Self.resize(image, to: requestedSize)
            }
            artworkCache[track.id] = artwork
            publishArtwork(artwork)
        } catch is CancellationError {
            // Track changed during the fetch — silent no-op.
        } catch {
            // Network error on a secondary asset — leave the previous
            // artwork in place so Control Center doesn't go blank.
        }
    }

    private func publishArtwork(_ artwork: MPMediaItemArtwork) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Produce a resized copy of `image` at `size` points. Used by the
    /// `MPMediaItemArtwork` size callback so the widget can request whatever
    /// resolution it actually needs (Retina Control Center is ~200pt; macOS
    /// Dock thumbnails are smaller).
    private static func resize(_ image: NSImage, to size: CGSize) -> NSImage {
        let target = NSSize(
            width: max(1, size.width),
            height: max(1, size.height)
        )
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}
