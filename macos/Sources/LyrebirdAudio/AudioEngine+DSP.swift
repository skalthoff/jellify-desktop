import AVFoundation
import Foundation
import os
@preconcurrency import LyrebirdCore

private let dspLog = Logger(subsystem: "org.lyrebird.desktop", category: "dsp")

/// AVAudioEngine DSP routing for `AudioEngine` (#39).
///
/// When `dspPipelineEnabled` is on, every public transport method branches
/// here instead of the AVQueuePlayer path. The split is deliberately at the
/// top of each method so that with the flag **off** (the default) the
/// existing path is byte-for-byte untouched — `dspPipeline` is never even
/// constructed.
///
/// Reporting parity: this path drives the exact same server contract as the
/// AVQueuePlayer path — `PlaybackInfo` resolution, `reportPlaybackStarted` /
/// `reportPlaybackProgress` / `reportPlaybackStopped`, `markTrackStarted`,
/// `markState` / `markPosition` (1 Hz, playing only), the 5s heartbeat, and
/// `MediaSession` transport notifications. A crossfade handoff (#41) keeps
/// that parity too: the outgoing track reports Stopped at the position the
/// fade began, the incoming reports Started against the play session its
/// stream was resolved with, and the heartbeat re-keys to the new session.
///
/// Known #39 gaps on this path (cleanly degraded, listed in the PR):
/// stall recovery is skip-on-error rather than bounded in-place retries, and
/// Ogg containers (which AudioToolbox cannot parse) skip to the next track.
///
/// Loudness (ReplayGain / volume normalization) applies through each deck's
/// player gain stage: `dspPlay` / the crossfade arm resolve the track's tags
/// via a metadata-only `AVURLAsset` read (the streamer's AudioToolbox parse
/// never surfaces them) and hand the result to
/// `EngineDSPPipeline.provideLoudnessGains`. The read is one ranged request
/// per track start; running it unconditionally keeps the pipeline's cached
/// tags warm so a settings flip mid-track is pure math, live, with no
/// re-fetch. An untagged track resolves to unity — never a level change.
///
/// Gapless: with crossfade on (#41) the armed next track buffers ahead and
/// transitions overlap (or zero-fade join for same-album pairs); with
/// crossfade off and gapless on, the armed track still buffers ahead and the
/// zero-fade join takes over at the outgoing track's natural end. Both off ⇒
/// the pre-#41 rebuild transition.
extension AudioEngine {
    /// `UserDefaults` key for the "Stop after current track" one-shot. The
    /// literal matches `AppModel+PlaybackControls` / `PreferencesPlayback`
    /// (the app layer owns the feature; the engine only peeks — without
    /// consuming — so an armed stop suppresses crossfade and the track runs
    /// to its true end before `handleTrackEnded` halts the queue).
    private static let stopAfterCurrentDefaultsKey = "playback.stopAfterCurrent"

    /// Build (or reuse) the pipeline. Only ever called from DSP-routed
    /// methods, which are themselves gated on `dspPipelineEnabled` — so the
    /// AVQueuePlayer path never constructs one.
    func dspEnsurePipeline() -> EngineDSPPipeline {
        if let pipeline = dspPipeline { return pipeline }
        let pipeline = EngineDSPPipeline()
        pipeline.onTrackFinished = { [weak self] in
            guard let self else { return }
            // Same contract as `AVPlayerItemDidPlayToEndTime`: mark ended,
            // let the owner advance its queue (AppModel.handleTrackEnded).
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }
        pipeline.onPositionTick = { [weak self] seconds in
            guard let self, seconds.isFinite, seconds >= 0 else { return }
            self.core.markPosition(seconds: seconds)
            // Reporting parity with the AVQueuePlayer path: forward the tick
            // so the owner's progress surfaces advance on the DSP route too
            // (#433 — `markPosition` is event-silent core-side).
            self.onPositionTick?(seconds)
        }
        pipeline.onStreamError = { [weak self] message in
            guard let self else { return }
            // Diagnostic detail goes to the log only — stream URLs carry the
            // api_key token, and transient NSURLError descriptions can embed
            // them. The user-facing copy matches the AVPlayer path's
            // transient-skip behaviour.
            dspLog.error("DSP track failed, skipping: \(message, privacy: .public)")
            self.delegate?.audioEngineDidEncounterTransientError("Playback failed — skipping")
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }
        pipeline.onCrossfadeBegan = { [weak self] _ in
            guard let self else { return }
            // The crossfade handoff (#41) is this path's gapless auto-
            // advance: the armed track is already audible. Fire the same
            // end-of-item contract as a natural finish — AppModel advances
            // its queue and calls play(track:), which adopts the live deck
            // via `adoptHandedOffTrack` instead of reloading.
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }
        pipeline.onShouldBeginCrossfade = {
            // "Stop after current track" (#116) must halt at the track's
            // *true* end — starting a crossfade would cut its final seconds.
            // Peek (never consume — `handleTrackEnded` owns the one-shot).
            !UserDefaults.standard.bool(forKey: AudioEngine.stopAfterCurrentDefaultsKey)
        }
        pipeline.setOutputDevice(uid: outputDeviceUID)
        // Re-apply the persisted EQ curve (#40) — the pipeline constructs
        // flat/bypassed, so a rebuild (or the first DSP-routed play of the
        // session) must restore the user's settings before audio renders.
        pipeline.applyEqualizer(equalizer)
        // Same deal for the crossfade settings (#41): `UserDefaults` is the
        // single source of truth (seeded by the Playback pane via
        // `dspApplyCrossfade`), so a fresh pipeline restores it directly.
        pipeline.applyCrossfade(CrossfadeSettings.load(from: .standard))
        // Gapless ships default-on; the pipeline itself defaults off so a
        // bare instance preserves the pre-gapless rebuild transitions — the
        // user preference is applied here, at the seam where the preference
        // layer meets the engine.
        pipeline.applyGapless(GaplessPreference.isEnabled())
        // Loudness knobs (ReplayGain mode / pre-gain / volume normalization):
        // the engine's vars are the live copy (owner-seeded + self-seeded at
        // init), so a fresh pipeline mirrors them directly.
        pipeline.applyNormalization(normalizationSettings)
        dspPipeline = pipeline
        return pipeline
    }

    /// Push new crossfade settings onto the live pipeline (#41). No-op while
    /// the DSP flag is off — the value persists in `UserDefaults` and the
    /// pipeline restores it on construction, so nothing is lost and the
    /// AVQueuePlayer path stays byte-for-byte untouched.
    public func dspApplyCrossfade(_ settings: CrossfadeSettings) {
        guard dspPipelineEnabled else { return }
        dspEnsurePipeline().applyCrossfade(settings)
    }

    /// DSP-path `play(track:)`. Mirrors the AVQueuePlayer path's resolution
    /// + reporting sequence exactly; only the audio transport differs.
    ///
    /// When the requested track is the one a crossfade handoff just made
    /// audible (#41), the pipeline is already playing it — adopt it: emit
    /// the same report swap a reload would (outgoing Stopped at the fade
    /// position, incoming Started against its resolved session) without
    /// touching the audio.
    func dspPlay(track: Track) async throws {
        let pipeline = dspEnsurePipeline()

        if let receipt = pipeline.adoptHandedOffTrack(key: track.id) {
            dspAdoptCrossfadedTrack(track, receipt: receipt)
            return
        }

        // Resolve local copy vs stream — identical decision tree to the
        // AVQueuePlayer path (#819 offline gate included).
        let url: URL
        let authHeader: String?
        let mediaSourceId: String?
        let playSessionId: String?
        if let localURL = await resolveLocalAssetURL(for: track.id) {
            url = localURL
            authHeader = nil
            mediaSourceId = nil
            playSessionId = nil
            core.setPlaySessionId(playSessionId: nil)
        } else {
            let (resolvedSource, resolvedSession) = await resolvePlaybackSource(for: track.id)
            mediaSourceId = resolvedSource
            playSessionId = resolvedSession
            let urlString = try core.streamUrl(
                trackId: track.id,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                maxStreamingBitrate: maxStreamingBitrate
            )
            guard let streamURL = URL(string: urlString) else {
                throw AudioEngineError.invalidURL(urlString)
            }
            url = streamURL
            core.setPlaySessionId(playSessionId: playSessionId)
            authHeader = try core.authHeader()
        }

        // Capture the outgoing track's position before the pipeline reloads,
        // so the matching Stopped report carries where it actually stopped —
        // the same capture-before-swap dance as the AVQueuePlayer path.
        let previousPositionTicks = dspPositionTicks()

        let durationHint: Double? = track.runtimeTicks > 0
            ? Double(track.runtimeTicks) / 10_000_000.0
            : nil
        pipeline.load(
            url: url,
            authHeader: authHeader,
            containerHint: track.container,
            durationHint: durationHint,
            trackKey: track.id,
            albumKey: track.albumId
        )
        // Resolve the track's loudness tags for the deck's gain stage. Fire-
        // and-forget alongside the stream — an untagged or unreachable read
        // degrades to unity gain.
        dspResolveLoudnessGains(forTrackKey: track.id, url: url, authHeader: authHeader)

        // Close out the previous server session before opening the new one
        // (Jellyfin keys sessions by PlaySessionId and leaks a transcode job
        // otherwise).
        reportStopped(positionTicks: previousPositionTicks)

        let core = self.core
        Task.detached { core.markTrackStarted(track: track) }
        core.markState(state: .playing)
        pipeline.play()
        mediaSession?.trackChanged(track)

        reportStarted(
            trackId: track.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            playMethod: nil
        )
        core.startHeartbeat(intervalSecs: 5, playSessionId: playSessionId)

        dspArmNextTrackForCrossfade(afterTrackWithKey: track.id)
    }

    /// Load the loudness tags for a DSP-routed track off the main actor and
    /// hand them to the pipeline's per-deck gain stage. The streamer's
    /// AudioToolbox parse never surfaces ReplayGain frames, so this is a
    /// separate metadata-only `AVURLAsset` read against the same URL (one
    /// ranged request; AVFoundation stops at the header tables). Untagged or
    /// failed reads provide nothing — the deck stays at unity.
    private func dspResolveLoudnessGains(forTrackKey trackKey: String, url: URL, authHeader: String?) {
        Task.detached { [weak self] in
            var options: [String: Any] = [:]
            if let authHeader {
                options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": authHeader]
            }
            let asset = AVURLAsset(url: url, options: options)
            let gains = await ReplayGain.gains(for: asset)
            guard !gains.isEmpty else { return }
            await MainActor.run {
                guard let self, let pipeline = self.dspPipeline else { return }
                pipeline.provideLoudnessGains(gains, forTrackKey: trackKey)
            }
        }
    }

    /// The reporting half of a crossfade handoff (#41). The audio swap
    /// already happened inside the pipeline; this mirrors `dspPlay`'s
    /// session bookkeeping for it: the outgoing track's Stopped report
    /// carries the position the fade began at, the incoming track's Started
    /// report (and the heartbeat) re-key to the play session its stream was
    /// resolved with at arm time.
    private func dspAdoptCrossfadedTrack(_ track: Track, receipt: EngineDSPPipeline.HandoffReceipt) {
        let outgoingTicks = Int64(max(0, receipt.outgoingPositionSeconds) * 10_000_000)
        core.setPlaySessionId(playSessionId: receipt.playSessionId)
        reportStopped(positionTicks: outgoingTicks)

        let core = self.core
        Task.detached { core.markTrackStarted(track: track) }
        core.markState(state: .playing)
        mediaSession?.trackChanged(track)

        reportStarted(
            trackId: track.id,
            mediaSourceId: receipt.mediaSourceId,
            playSessionId: receipt.playSessionId,
            playMethod: nil
        )
        core.startHeartbeat(intervalSecs: 5, playSessionId: receipt.playSessionId)

        dspArmNextTrackForCrossfade(afterTrackWithKey: track.id)
    }

    /// Arm the queue's next track on the pipeline so the upcoming transition
    /// can join — crossfade overlap (#41) or the gapless zero-fade handoff.
    /// Resolves the stream exactly like `dspPlay` (offline gate, PlaybackInfo
    /// session correlation, bitrate ceiling) but fire-and-forget: any failure
    /// just means this transition falls back to the ordinary end-of-track
    /// rebuild.
    ///
    /// `core.peekNext()` honours the live queue + repeat mode (the same
    /// lookahead `AppModel.armNextTrackPreload` reads), so the armed track
    /// is the one `skipNext()` will return at the handoff. A queue edit
    /// after arming makes the armed track stale — `dspPlay` then sees a key
    /// mismatch and reloads fresh, the same staleness contract as the
    /// AVQueuePlayer path's pre-inserted item.
    ///
    /// Internal (not private) so `applyGapless` can re-arm when the user
    /// turns gapless on mid-track; key-based because that caller only has
    /// the pipeline's current track key, and the stale guard needs nothing
    /// more.
    func dspArmNextTrackForCrossfade(afterTrackWithKey currentKey: String) {
        guard let pipeline = dspPipeline, pipeline.transitionArmingEnabled else { return }
        guard let next = core.peekNext() else {
            pipeline.disarmNextTrack()
            return
        }

        let offlineEnabled = offlinePlaybackEnabled
        let bitrateCap = maxStreamingBitrate
        let core = self.core
        Task.detached { [weak self] in
            // Resolution mirrors `preloadNextTrack`'s detached body: local
            // copy first (#819), else PlaybackInfo → stream URL → auth.
            let localPath = offlineEnabled ? core.downloadLocalPath(trackId: next.id) : nil
            let url: URL?
            var authHeader: String?
            var mediaSourceId: String?
            var playSessionId: String?
            if let localPath, !localPath.isEmpty {
                url = URL(fileURLWithPath: localPath)
            } else {
                let opts = PlaybackInfoOpts(
                    userId: nil,
                    startTimeTicks: nil,
                    mediaSourceId: nil,
                    maxStreamingBitrate: nil,
                    enableDirectPlay: nil,
                    enableDirectStream: nil,
                    enableTranscoding: nil,
                    autoOpenLiveStream: nil,
                    deviceProfile: nil
                )
                let info = try? core.playbackInfo(itemId: next.id, opts: opts)
                mediaSourceId = info?.mediaSources.first?.id
                playSessionId = info?.playSessionId
                guard let urlString = try? core.streamUrl(
                    trackId: next.id,
                    mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId,
                    maxStreamingBitrate: bitrateCap
                ), let streamURL = URL(string: urlString) else {
                    dspLog.notice("crossfade arm skipped: could not resolve stream for \(next.id, privacy: .public)")
                    return
                }
                url = streamURL
                authHeader = try? core.authHeader()
            }
            guard let url else { return }

            let durationHint: Double? = next.runtimeTicks > 0
                ? Double(next.runtimeTicks) / 10_000_000.0
                : nil
            let armedTrack = EngineDSPPipeline.ArmedNextTrack(
                key: next.id,
                albumKey: next.albumId,
                url: url,
                authHeader: authHeader,
                containerHint: next.container,
                durationHint: durationHint,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId
            )
            // Rebind the branch-assigned `var` as a `let` so the main-actor
            // hop below captures an immutable value (Swift 6 Sendable rule).
            let resolvedAuthHeader = authHeader
            await MainActor.run {
                guard let self, let pipeline = self.dspPipeline else { return }
                // Stale guard: only arm if the track we resolved against is
                // still the one playing (a rapid skip mid-resolve supersedes
                // this arm — its own dspPlay re-arms).
                guard pipeline.currentTrackKey == currentKey else { return }
                pipeline.armNextTrack(armedTrack)
                // Resolve the armed track's loudness tags now so its deck
                // gain is in place before the join makes it audible (the
                // pipeline stashes the result until the prepare window loads
                // the deck).
                self.dspResolveLoudnessGains(forTrackKey: next.id, url: url, authHeader: resolvedAuthHeader)
            }
        }
    }

    func dspPause() {
        dspPipeline?.pause()
        core.markState(state: .paused)
        mediaSession?.rateChanged(isPlaying: false)
        reportProgressSnapshot(isPaused: true)
    }

    func dspResume() {
        dspPipeline?.resume()
        core.markState(state: .playing)
        mediaSession?.rateChanged(isPlaying: true)
        reportProgressSnapshot(isPaused: false)
    }

    func dspStop() {
        // Emit Stopped before tearing the pipeline down so the report still
        // reflects the last playback position — same order as the
        // AVQueuePlayer path.
        reportStopped()
        core.stopHeartbeat()
        dspPipeline?.stop()
        core.stop()
        mediaSession?.trackChanged(nil)
    }

    func dspSeek(toSeconds seconds: Double) {
        guard let pipeline = dspPipeline else { return }
        pipeline.seek(toSeconds: seconds)
        // The pipeline's position reflects the target synchronously, so the
        // widget + server snapshot can publish immediately (the streamer
        // corrects the base frame asynchronously only for estimated VBR
        // landings / range-less servers).
        mediaSession?.seeked(to: seconds)
        reportProgressSnapshot(isPaused: pipeline.state != .playing)
    }

    func dspSetVolume(_ v: Float) {
        dspEnsurePipeline().setVolume(max(0, min(1, v)))
        core.setVolume(volume: v)
    }

    /// Position in Jellyfin ticks for the reporting helpers. Mirrors
    /// `positionTicks()`'s clamping for the AVPlayer path.
    func dspPositionTicks() -> Int64 {
        guard let pipeline = dspPipeline else { return 0 }
        let seconds = pipeline.positionSeconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }
}
