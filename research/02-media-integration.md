# jellify-desktop — macOS Media + System Integration Issues

Proposed GitHub issues to bring `macos/Sources/JellifyAudio/AudioEngine.swift` and the surrounding app to parity with first-class macOS media citizens (Apple Music, Doppler, Swinsian, Cider). Ordering is roughly by foundation → feature. Where an existing file is the natural home, it is cited by path.

Conventions used:
- `area:macos` — implies SwiftUI / AppKit / AVFoundation / MediaPlayer work
- `area:audio` — audio graph, DSP, playback pipeline
- `area:core` — work in `core/src/**` (Rust, usually via UniFFI)
- Effort: **S** ≤ 0.5 day, **M** 1-2 days, **L** 3-5 days, **XL** >1 week

---

### Issue 1: Introduce a MediaSession coordinator that owns MPNowPlayingInfoCenter updates
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** —

- Create a new `MediaSession` class (e.g. `macos/Sources/JellifyAudio/MediaSession.swift`) that is the single writer of `MPNowPlayingInfoCenter.default().nowPlayingInfo`. Every other system integration (Control Center, AVRCP, media keys, Dock) reads through it. Do not scatter `nowPlayingInfo` mutations across the codebase — that's how `elapsedPlaybackTime` drifts.
- Write the full property set on every track change: `MPMediaItemPropertyTitle`, `MPMediaItemPropertyArtist`, `MPMediaItemPropertyAlbumTitle`, `MPMediaItemPropertyAlbumArtist`, `MPMediaItemPropertyPlaybackDuration`, `MPMediaItemPropertyMediaType = .music`, `MPNowPlayingInfoPropertyAssetURL`, `MPNowPlayingInfoPropertyMediaType = .audio`, plus `MPNowPlayingInfoPropertyIsLiveStream = false`. Set `MPNowPlayingInfoPropertyQueueIndex` / `QueueCount` from `PlayerStatus.queuePosition` / `queueLength`.
- On every play/pause/seek, update only the mutated keys: `MPNowPlayingInfoPropertyElapsedPlaybackTime` and `MPNowPlayingInfoPropertyPlaybackRate` (0.0 paused, 1.0 playing). Never leave a stale rate — Bluetooth AVRCP misbehaves when `AVPlayer.rate` and `playbackRate` disagree ([Apple forums thread 654413](https://developer.apple.com/forums/thread/654413)).
- Inject the session into `AudioEngine` (construction-time dependency, not a singleton) so unit tests can substitute a mock. Keep AudioEngine `@MainActor`.
- Refactor `AppModel.pollTimer` so the session, not AppModel, is the source of truth for "what's playing now." AppModel still exposes `status: PlayerStatus` for SwiftUI but the MediaSession pushes to MPNowPlaying on each `core.markPosition` tick.
- **Acceptance:** opening `System Settings > Control Center > Now Playing` shows Jellify with correct title, artist, album, duration; rate flips between 0.0/1.0 on pause/resume; queue index updates when skipping. Verified visually and by logging `MPNowPlayingInfoCenter.default().nowPlayingInfo` after each transport action.

References: [MPNowPlayingInfoCenter docs](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) • [Controlling music from lock screen](https://medium.com/@g4gurpreetoberoi/controlling-music-from-lock-screen-mpnowplayinginfocenter-3f75ec7972d6) • [Enabling Now-Playing and Earphone Button Controls for an Audio App](https://www.glucode.com/blog/posts/enabling-now-playing-and-earphone-button-controls-for-an-audio-app).

---

### Issue 2: Load and publish artwork to MPMediaItemArtwork
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** #1

- Extend `MediaSession` with an async artwork loader that uses `core.imageUrl(itemId:tag:maxWidth:)`. Fetch once per track (cache in-memory by `Track.id`) using a `URLSession` with the same auth headers AVPlayer uses.
- Build `MPMediaItemArtwork(boundsSize: requested) { requestedSize in resizedImage }`. macOS honors the size callback; supply a resized `NSImage` so the widget doesn't force a full-resolution download. Ask Jellyfin for `maxWidth: 600` (covers Retina Control Center at ~200pt) and resize down in the closure if needed.
- Set `MPMediaItemPropertyArtwork` only after the image has actually been decoded — setting a still-loading artwork shows a blank square until replaced. For the moment between track change and artwork load, leave the previous artwork in place rather than clearing (matches Apple Music behavior).
- Cancel in-flight artwork fetches when the track changes mid-load.
- Handle the no-artwork case: `track.imageTag == nil` — substitute a procedural placeholder (there's already one in `Components/Artwork.swift`).
- **Acceptance:** Control Center shows the album artwork within ~300 ms of play; rapid skip-next does not show the prior track's art.

---

### Issue 3: Implement MPRemoteCommandCenter handlers (play, pause, togglePlayPause, next, previous, stop)
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** #1

- In `MediaSession`, wire `MPRemoteCommandCenter.shared()` handlers using closures (the closure form is cleaner than target-selector): `playCommand`, `pauseCommand`, `togglePlayPauseCommand`, `stopCommand`, `nextTrackCommand`, `previousTrackCommand`. Each handler calls through to `AppModel` (inject as a weak reference) and returns `.success` on state change, `.commandFailed` on error, or `.noActionableNowPlayingItem` when `PlayerStatus.currentTrack == nil`.
- Explicitly enable/disable: `playCommand.isEnabled = true` etc. macOS gates what shows in Control Center by which commands are enabled. Disable `stopCommand` unless there's a current item.
- Re-check enablement on every queue change: at `queuePosition == 0`, disable `previousTrackCommand`; at `queuePosition == queueLength - 1`, disable `nextTrackCommand` (unless repeat is on, see #8).
- Keep the handlers side-effect-minimal. They should not themselves touch `AVPlayer`; they route through `AppModel.togglePlayPause()` etc. so the same code path runs whether a human or a Bluetooth headset triggers it.
- **Acceptance:** Clicking play/pause in Control Center's Now Playing widget starts/stops Jellify; next/previous in the widget skips; buttons gray out appropriately at queue bounds.

References: [MPRemoteCommandCenter docs](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter) • [RemoteCommandManager.swift (iOS-Swift-Demos)](https://github.com/iamzken/iOS-Swift-Demos/blob/master/MPRemoteCommandSample/Shared/Managers/RemoteCommandManager.swift) • [mpv's implementation (macOS)](https://github.com/mpv-player/mpv/blob/master/osdep/mac/remote_command_center.swift).

---

### Issue 4: Implement changePlaybackPositionCommand for scrubber in Control Center
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p0`
**Effort:** S
**Depends on:** #3

- Enable `changePlaybackPositionCommand` and add a handler that seeks to `(event as! MPChangePlaybackPositionCommandEvent).positionTime` using existing `audio.seek(toSeconds:)`.
- Immediately after seeking, update `MPNowPlayingInfoPropertyElapsedPlaybackTime` to the new position so the widget confirms the scrub without waiting for the next 0.5s tick.
- Return `.success` unconditionally (AVPlayer coalesces seeks, so even if the target is out of bounds it clamps).
- **Acceptance:** Dragging the Control Center scrubber updates the AVPlayer position; release of the scrubber snaps to the expected time.

---

### Issue 5: Implement skipForwardCommand / skipBackwardCommand with configurable intervals
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p2`
**Effort:** S
**Depends on:** #3

- Wire `skipForwardCommand` / `skipBackwardCommand` for ±15 s jump (common podcast default, fine for music).
- Set `preferredIntervals = [15]` on each command. macOS will use the first value to label the button ([skipForwardCommand docs](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/1618990-skipforwardcommand)).
- Handler reads `(event as! MPSkipIntervalCommandEvent).interval` (not the preferred; the event carries the actual) and calls `audio.seek(toSeconds: status.positionSeconds ± interval)`.
- Likely `p2` — skip-forward on a music client is unusual, but it costs almost nothing and the Touch Bar button is there for the taking.
- **Acceptance:** ±15s skip buttons appear in the Now Playing widget and step the track by the configured interval.

---

### Issue 6: Wire shuffleCommand / repeatCommand (stateful toggles)
**Labels:** `area:macos`, `area:audio`, `area:core`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** #3

- Add shuffle + repeat state to the Rust core: extend `PlayerStatus` with `shuffle: bool` and `repeatMode: RepeatMode { off, one, all }`. Plumb through `core.setShuffle(on:)` / `core.setRepeatMode(mode:)` via UniFFI. This is a cross-platform win — Linux/Windows also need it. (Touches `core/src/player.rs`, regenerates `jellify_core.swift`.)
- In `MediaSession`, wire `changeShuffleModeCommand` / `changeRepeatModeCommand`. Map `MPShuffleType.items` → `shuffle=true`, `MPShuffleType.off` → `shuffle=false`; map `MPRepeatType.one` → `.one`, `.all` → `.all`, `.off` → `.off`.
- Propagate state back: set `MPShuffleType` and `MPRepeatType` on the command on every status change so the Control Center toggle reflects current state.
- Update `next`/`previous` behavior in core to honor shuffle (random draw from remaining queue) and repeat (wrap for `.all`, same track for `.one`).
- Also update the placeholder shuffle/repeat icons in `PlayerBar.swift:59-70` (currently no-op buttons) to bind to the same state.
- **Acceptance:** Toggling shuffle/repeat from Control Center and from PlayerBar produces the same effect; UI icons reflect state; end-of-queue with repeat=all wraps to track 0; repeat=one restarts the current track on end.

---

### Issue 7: Wire likeCommand / dislikeCommand to Jellyfin favorites
**Labels:** `area:macos`, `area:audio`, `area:core`, `kind:feat`, `priority:p2`
**Effort:** S
**Depends on:** #3

- Track struct already exposes `isFavorite` (see `jellify_core.swift:1687`). Expose a core method `setFavorite(trackId:favorite:)` that hits Jellyfin's `/Users/{id}/FavoriteItems/{id}` (POST to favorite, DELETE to unfavorite).
- Wire `MPRemoteCommandCenter.shared().likeCommand` — toggle favorite on. Leave `dislikeCommand` disabled (Jellyfin has no dislike concept; don't fake one).
- On track change update `likeCommand.isActive = track.isFavorite` so the heart fills correctly.
- **Acceptance:** Hitting the heart in Control Center toggles the favorite in the Jellyfin library; re-queuing the track shows the updated state.

---

### Issue 8: Confirm media keys (F7/F8/F9) route through MPRemoteCommandCenter on macOS 12+
**Labels:** `area:macos`, `kind:research`, `priority:p0`
**Effort:** S
**Depends on:** #3

- macOS 10.12.2+ delivers F7/F8/F9 and Touch Bar media button presses via `MPRemoteCommandCenter` to the "most recently active" media app (the one that last called `MPNowPlayingInfoCenter`). This supersedes the old private `MediaRemote` / `HIDManager` route keylogger approach used pre-Sierra ([apple.stackexchange discussion](https://github.com/iina/iina/issues/1110), [BTHSControl](https://github.com/JamesFator/BTHSControl)).
- Once #1-#3 are done, F7/F8/F9 should Just Work with no additional code. This issue is a verification / smoke-test task: hit each key with Jellify playing, hit with Jellify paused, hit while Music.app is also installed (confirm Jellify intercepts since it most-recently set `nowPlayingInfo`).
- Document the "most recently active" rule in `CONTRIBUTING.md` under a "Media keys" section. Users sometimes report "Jellify doesn't respond to F8" when really they just opened Music.app afterward.
- **Acceptance:** F7/F8/F9 trigger previous/play-pause/next while Jellify is the most-recent media app. Touch Bar transport controls (on supported hardware) also work.

---

### Issue 9: Handle AVRCP events from Bluetooth headphones / CarPlay-style accessories
**Labels:** `area:macos`, `kind:test`, `priority:p1`
**Effort:** S
**Depends on:** #3

- macOS routes AVRCP next/pause/play button presses through the same `MPRemoteCommandCenter` that serves Control Center. No separate code path is needed — this is a test / regression task.
- Pair a pair of AirPods or a generic Bluetooth headset; press the multifunction button. Verify single-press toggles play/pause, double-press skips next, triple-press skips previous. Confirm the handlers return `.success` (return `.commandFailed` silently disables that function on the headset for the rest of the session on some vendors — iOS forum post flagged this).
- If pause doesn't resume correctly from Bluetooth, check that `AVPlayer.rate` and `MPNowPlayingInfoPropertyPlaybackRate` agree. AVRCP's pause sends based on the advertised rate ([Apple forums](https://developer.apple.com/forums/thread/654413)).
- **Acceptance:** AirPods triple-click, single-click, double-click all behave correctly; `MPRemoteCommand*` logs show events; `AVPlayer.rate` stays in sync with the advertised rate.

---

### Issue 10: Robust AVPlayer error + stall handling
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** —

- `AudioEngine.swift` currently observes `rate` and `DidPlayToEndTime` but does not observe `AVPlayerItem.status`, `playbackBufferEmpty`, `playbackLikelyToKeepUp`, or `AVPlayerItemFailedToPlayToEndTimeNotification`. Add:
  - KVO on `AVPlayerItem.status` — on `.failed` surface the `error`, call `core.markState(state: .stopped)`, invoke a `onPlaybackFailed(Error)` callback so `AppModel` can show `errorMessage`.
  - KVO on `playbackBufferEmpty` → mark `.loading` state (add to `PlaybackState` enum in core; currently has `.loading` but it's never set from Swift).
  - KVO on `playbackLikelyToKeepUp` → mark `.playing` if we were `.loading`.
  - `NotificationCenter` observer for `.AVPlayerItemFailedToPlayToEndTime` with `item` as object — surface the error similarly.
- Add a stall-recovery retry: on `.failed` with a network-ish error (`NSURLErrorDomain`), wait 2s and rebuild the AVPlayerItem with the same URL. Cap retries at 3. See [Apple forums thread 649391](https://developer.apple.com/forums/thread/649391) for AVPlayer's own retry behavior — it gives up after ~14s of stall.
- Add a `BufferingOverlay` to `PlayerBar` that shows a spinner when `status.state == .loading`. Right now a stall looks identical to playing.
- **Acceptance:** Killing the server mid-track shows "Network error" in the player bar within ~5s; restarting the server and hitting retry resumes; logs show each KVO transition.

References: [What to do when AVPlayer stalls (Apple forums)](https://developer.apple.com/forums/thread/649391) • [Monitor iOS Video Playback with AVPlayer (Fastpix)](https://www.fastpix.io/blog/how-to-monitor-video-playback-performance-in-ios-using-avplayer) • [Error Handling Best Practices for HLS (WWDC17)](https://asciiwwdc.com/2017/sessions/514).

---

### Issue 11: Switch from AVPlayer to AVQueuePlayer for gapless playback
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p1`
**Effort:** L
**Depends on:** #10

- Replace the single `AVPlayer` in `AudioEngine.swift` with `AVQueuePlayer`, which is purpose-built for gapless transitions. `AVQueuePlayer.insert(_:after:)` lets us prebuffer the next track a few seconds before the current one ends.
- Queue preload strategy: whenever `status.positionSeconds >= status.durationSeconds - 15`, fetch `core.peekNext()` (new core method — add; trivial given the existing queue) and `insert` its `AVPlayerItem` into the queue. The lookahead window of 15s is generous enough for HTTP streaming to fill the buffer before the transition.
- Replace `onTrackEnded` logic: listen for `AVPlayer.currentItem` change via KVO. When `currentItem` flips to the preloaded next one, call `core.skipNext()` (it's now just updating the logical queue, not driving playback).
- Handle queue-replace (user clicks a different album mid-playback): call `queuePlayer.removeAllItems()`, then `insert` the first track of the new queue.
- Watch out: `AVQueuePlayer` shares buffering across items so HTTP auth headers need to be set on every `AVURLAsset` (no shared session). Keep the `Authorization` header logic in a helper.
- Confirm via a test track set with known 0ms transitions (e.g. Pink Floyd _Dark Side of the Moon_, Daft Punk _Discovery_): no audible click or silence between tracks.
- **Acceptance:** Playing an album with track-to-track crossovers produces no silence or click; switching queues mid-playback is immediate and clean; the "next item buffers during current track" behavior is observable in a Console log of buffer fills.

References: [AVQueuePlayer docs](https://developer.apple.com/documentation/avfoundation/avqueueplayer) • [AQPlayer sample](https://github.com/AhmadAmri/AQPlayer).

---

### Issue 12: Add AirPlay route picker button and route detection
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** #11

- Add `AVRoutePickerView` (from AVKit) to the right-hand `rightControls` area in `PlayerBar.swift` between the volume slider and the edge. Wrap it in `NSViewRepresentable` since `AVRoutePickerView` is an `NSView` on macOS.
- Enable `AVRouteDetector.isRouteDetectionEnabled = true` and observe `.AVRouteDetectorMultipleRoutesDetectedDidChange` — only show the picker button when `routeDetector.multipleRoutesDetected == true`, matching Apple Music's auto-hide.
- No additional AVPlayer glue needed — routing a track to AirPlay is transparent when using `AVQueuePlayer` / `AVPlayer`. "By using AVPlayer and AVQueuePlayer, you automatically get enhanced audio buffering when it is routed to AirPlay" ([WWDC17 Session 509](https://asciiwwdc.com/2017/sessions/509)).
- Update `MPNowPlayingInfoPropertyCurrentPlaybackDate` so AirPlay receivers that display a progress bar (HomePod, Apple TV) stay in sync.
- **Acceptance:** With an AirPlay speaker on the LAN, the picker button appears in the player bar; clicking it lists devices; selecting one routes audio without interruption; the track continues from the same position.

References: [AVRoutePickerView docs](https://developer.apple.com/documentation/avkit/avroutepickerview) • [AVRoutePickerView replaces MPVolumeView (Baking Swift)](https://jeroenscode.com/avroutepickerview-replaces-mpvolumeview/) • [SwiftUI AirPlay](https://levelup.gitconnected.com/swiftui-support-airplay-to-route-playback-to-other-devices-9489f22f761e).

---

### Issue 13: Build an AVAudioEngine-based DSP pipeline behind a feature flag (for EQ / crossfade)
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p1`
**Effort:** XL
**Depends on:** #10

- This is the foundation for EQ (#14), crossfade (#15), ReplayGain (#16). Must be an either-or with #11 (AVQueuePlayer): AVPlayer can't have real-time effect nodes applied to it — `MTAudioProcessingTap` historically worked but **does not support HTTP streaming** ([Chritto blog](https://chritto.wordpress.com/2013/01/07/processing-avplayers-audio-with-mtaudioprocessingtap/)). So to run effects, audio must go through `AVAudioEngine`.
- Bridge HTTP streaming → `AVAudioEngine`: use the `AudioStreamer` / `SwiftAudioPlayer` pattern. URLSession downloads bytes → `AudioToolbox` parses (AudioFileStream for MP3/AAC, FLAC needs a separate decoder — flac-rs in core or [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)) → schedule `AVAudioPCMBuffer`s onto an `AVAudioPlayerNode`. Confirmed pattern from [syedhali/AudioStreamer](https://github.com/syedhali/AudioStreamer) and [SwiftAudioPlayer](https://github.com/tanhakabir/SwiftAudioPlayer).
- Graph: `AVAudioPlayerNode → AVAudioUnitEQ → AVAudioMixerNode → engine.mainMixerNode`.
- Gate behind a setting (`UserDefaults.standard.bool(forKey: "engine.useAVAudioEngine")`) defaulting to `false`. Ship AVQueuePlayer path as the reliable default; opt-in to AVAudioEngine when the user enables EQ or crossfade in settings.
- Confirm FLAC 24/96, 24/192 decode. SFBAudioEngine supports all Jellyfin's likely containers (FLAC, OGG, ALAC). If we only want MP3+AAC+ALAC, Apple's built-in parsers are enough and we skip a dep.
- **Acceptance:** With the feature flag on, a playlist plays without audible artifacts through the engine path; spectrum analyzer on an external tool shows clean PCM output; memory stays flat over a 30-minute playlist.

References: [Streaming Audio With AVAudioEngine (Haris Ali)](https://www.syedharisali.com/articles/streaming-audio-with-avaudioengine/) • [Creating an advanced streaming Audio Engine for iOS (Tanha Kabir)](https://medium.com/chameleon-podcast/creating-an-advanced-streaming-audio-engine-for-ios-9fbc7aef4115) • [MTAudioProcessingTap in Swift](https://github.com/gchilds/MTAudioProcessingTap-in-Swift).

---

### Issue 14: 10-band graphic equalizer (AVAudioUnitEQ) with preset list
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p2`
**Effort:** L
**Depends on:** #13

- Insert `AVAudioUnitEQ(numberOfBands: 10)` in the engine path. Set each band: `.filterType = .parametric`, `.frequency = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000][i]`, `.bandwidth = 0.5` (octaves), `.bypass = false`.
- Preset set (standard "AM 5.1" / iTunes set — match user expectations):
  - Flat: `[0,0,0,0,0,0,0,0,0,0]`
  - Bass Boost: `[6,5,4,3,1,0,0,0,0,0]`
  - Treble Boost: `[0,0,0,0,0,1,3,5,6,6]`
  - Bass+Treble: `[5,4,3,1,0,0,2,3,5,5]`
  - Vocal Boost: `[-2,-1,0,1,3,4,3,1,0,-1]`
  - Acoustic: `[4,4,3,1,2,2,3,4,3,2]`
  - Dance: `[4,6,5,0,1,3,5,4,3,0]`
  - Electronic: `[4,4,2,0,-2,2,1,2,4,5]`
  - Hip-Hop: `[5,4,1,3,-1,-1,1,-1,2,3]`
  - Jazz: `[4,3,2,2,-1,-1,0,1,2,3]`
  - Classical: `[5,4,3,2,-2,-2,0,2,3,4]`
  - Rock: `[5,4,3,1,-1,-1,0,2,3,4]`
  - Pop: `[-1,-1,0,2,4,4,2,0,-1,-1]`
  - Piano: `[3,2,0,2,3,1,3,4,3,3]`
- Custom preset with per-band sliders, persisted to `UserDefaults`.
- EQ UI: add a new Settings screen (`EqualizerSettingsView.swift`) with a preset picker and slider stack. Match the look of the existing Theme.
- Keep EQ bypass (`eq.globalGain = 0, bypass = true` for Flat) to guarantee no DSP alteration when "Off" is selected — bit-perfect default matters to audiophile users.
- **Acceptance:** Switching presets alters audible EQ in real time without clicks or dropouts; Flat preset is bit-identical to engine-disabled output (confirm with loopback recording or by checksumming the engine's output buffer); custom preset persists across restart.

References: [AVAudioUnitEQ docs](https://developer.apple.com/documentation/avfaudio/avaudiouniteq) • [AVAudio+Equalizer example](https://github.com/HanSJin/AVAudio-Equalizer) • [AVAudioUnitEQ preset values (cfrgtkky)](http://cfrgtkky.blogspot.com/2019/01/how-to-set-avaudiouniteq-equalizer.html).

---

### Issue 15: Crossfade between tracks via dual AVAudioPlayerNodes with gain envelopes
**Labels:** `area:macos`, `area:audio`, `kind:feat`, `priority:p2`
**Effort:** L
**Depends on:** #13

- Two `AVAudioPlayerNode` instances (A and B) alternating. Each has its own `AVAudioMixerNode` between it and the main mixer so we can ramp per-node gain.
- When the current track is `crossfadeDuration` seconds from the end (configurable, default 4s), preload and schedule the next track on the other node. Apply linear gain ramps: current node fades out via `mixer.outputVolume` via `AVAudioTime`-scheduled value changes, new node fades in.
- Gain curve: offer linear + equal-power (cos/sin) in settings. Equal-power preserves perceived loudness; linear can momentarily dip. Equal-power: `gainA(t) = cos(t * π/2)`, `gainB(t) = sin(t * π/2)`, t in [0,1].
- When crossfade is on and the user hits next mid-track, fall back to a short 250ms fade-out-fade-in so there's no audio pop.
- Setting: toggle + slider (1s – 12s) in Settings.
- Disable crossfade when shuffling a single-artist playlist (optional; some users want it always on). Keep it user-controlled.
- Disable automatically for tracks marked as part of a gapless album (currently Jellyfin doesn't surface this — punt to `if album matches between current and next, skip crossfade and rely on AVQueuePlayer-style gapless behavior by zero-fading`).
- **Acceptance:** With crossfade on, consecutive tracks overlap for the configured duration with no audible pop; toggling off produces gapless back-to-back playback; a manually-triggered skip fades gracefully.

References: [AVAudioEngine Tutorial (Kodeco)](https://www.kodeco.com/21672160-avaudioengine-tutorial-for-ios-getting-started) • [AVAEMixerSample-Swift](https://github.com/ooper-shlab/AVAEMixerSample-Swift) • [Audio Manipulation Using AVAudioEngine (Metova)](https://metova.com/audio-manipulation-using-avaudioengine/).

---

### Issue 16: ReplayGain + volume normalization
**Labels:** `area:macos`, `area:audio`, `area:core`, `kind:feat`, `priority:p2`
**Effort:** M
**Depends on:** #13

- Jellyfin exposes `NormalizationGain` (in dB) and `LUFS` on the audio item JSON ([jellyfin issue #14346](https://github.com/jellyfin/jellyfin/issues/14346), [Volume Normalization thread](https://features.jellyfin.org/posts/2363/replay-gain-normalization)). Extend the Rust core `Track` struct with `normalizationGain: f32?` and `lufs: f32?` — parse from the `/Items/{id}` response. Regenerate UniFFI bindings.
- In settings, offer three modes: Off, Track (default), Album. Note that as of 2025 Jellyfin's `NormalizationGain` returns the track value regardless of the chosen preference — if album mode is selected we'll need an additional call to `/Items/{albumId}` to pull album-level gain. Document this caveat.
- Apply the gain as a pre-EQ `AVAudioUnitEQ` (use the eq's `globalGain` property), or more cleanly as `AVAudioMixerNode.outputVolume = pow(10, gain_dB / 20)`. Clamp at 0dB reduction (never boost above the source) to avoid clipping, which is the ReplayGain convention.
- Fall back to a simple peak-limit if no gain metadata is present (`AVAudioUnitEffect` with an AUDynamicsProcessor AU — limiter only, threshold -1dBFS, release 50ms). Prevent peak clipping when EQ is boosting bands.
- **Acceptance:** A quiet track followed by a loud track plays at roughly the same perceived loudness when Track mode is on; toggling Off restores raw levels; no clipping when the limiter is enabled and aggressive EQ is applied to a hot source.

References: [Jellyfin ReplayGain feature request](https://features.jellyfin.org/posts/2363/replay-gain-normalization) • [NormalizationGain track/album issue](https://github.com/jellyfin/jellyfin/issues/14346) • [Hacking ReplayGain into Jellyfin](https://project-insanity.org/2019/04/10/hacking-replay-gain-audio-normalization-into-jellyfin/).

---

### Issue 17: Dock tile playback progress + play/pause overlay
**Labels:** `area:macos`, `kind:feat`, `priority:p2`
**Effort:** M
**Depends on:** #1

- `NSApp.dockTile.contentView = NSHostingView(rootView: DockTileView())`. `DockTileView` is a SwiftUI view showing current album art with a thin progress arc around the icon edge (or a bottom bar — pick one). Pause icon overlay when `state == .paused`.
- Call `NSApp.dockTile.display()` at most once per second (the tile does not auto-redraw). Tie it to the existing 0.5s status poll but throttle to 1s in the tile path — anything more frequent spikes CPU per [thisdevbrain](https://thisdevbrain.com/custom-view-inside-dock-with-nsdocktile/).
- Dock menu: right-click should show play/pause, next, previous as `NSMenu` items. Bind the menu via `applicationDockMenu(_:)` in an `NSApplicationDelegate` (set up an `NSApplicationDelegateAdaptor` in `JellifyApp.swift`).
- On quit, restore the standard icon (`dockTile.contentView = nil; dockTile.display()`).
- **Acceptance:** Playing a track shows a ring filling around the Dock icon in real time; right-click on dock icon shows transport menu; pausing shows an overlay badge; quitting restores the stock icon.

References: [Custom View inside Dock via NSDockTile (This Dev Brain)](https://thisdevbrain.com/custom-view-inside-dock-with-nsdocktile/) • [DSFDockTile](https://github.com/dagronf/DSFDockTile) • [NSDockTile docs](https://developer.apple.com/documentation/appkit/nsdocktile).

---

### Issue 18: MenuBarExtra mini-player with transport controls
**Labels:** `area:macos`, `kind:feat`, `priority:p2`
**Effort:** M
**Depends on:** —

- Add a second `Scene` to `JellifyApp`: `MenuBarExtra("Jellify", systemImage: "music.note") { MenuBarPlayerView() }` with `.menuBarExtraStyle(.window)` for a richer popover rather than a dropdown menu.
- `MenuBarPlayerView` shows: 36×36 artwork, title + artist (single line each, truncated), a progress bar, and a row of prev / play-pause / next icons. Keep the whole popover under ~260×120 pt. See [PlayStatus](https://github.com/nbolar/PlayStatus) / Sarunw tutorials for the layout pattern.
- Reuse `AppModel` — the same `@Environment(AppModel.self)` the main window uses. Menu bar popover is a second front-end onto the same state.
- Offer a setting: "Show in menu bar" (default on); "Hide Dock icon when in menu bar" which flips `LSUIElement` (requires relaunch; document that).
- **Acceptance:** Menu bar icon shows a tiny glyph; clicking opens a mini-player; transport buttons work; artwork updates as the track changes; closing/reopening the popover doesn't leak view state.

References: [MenuBarExtra docs](https://developer.apple.com/documentation/swiftui/menubarextra) • [PlayStatus menu bar player](https://github.com/nbolar/PlayStatus) • [Create a mac menu bar app in SwiftUI (Sarunw)](https://sarunw.com/posts/swiftui-menu-bar-app/).

---

### Issue 19: Global keyboard shortcuts (⌘P play/pause, ⌘→ next, ⌘← prev, ⌘↑↓ volume)
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** S
**Depends on:** —

- Add a `CommandMenu("Playback") { ... }` to the main `WindowGroup` with `Button("Play/Pause").keyboardShortcut(.space, modifiers: [])`, next/prev/volume similarly. This gives menu bar entries too.
- Space-bar play/pause is standard in every macOS music player; it's free once the command is wired.
- Add global hotkey registration (optional, behind a setting): `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` is denied post-Mojave without accessibility permissions; use `HotKey` library or MASShortcut instead, or explicitly skip global shortcuts and document "media keys are the global story." I'd recommend skipping global and relying on F7/F8/F9 + MenuBarExtra.
- **Acceptance:** Space bar toggles playback when main window has focus; menu items reflect keyboard equivalents.

---

### Issue 20: Lossless / hi-res audio output device handling
**Labels:** `area:macos`, `area:audio`, `kind:research`, `priority:p2`
**Effort:** L
**Depends on:** #13

- macOS does **not** auto-switch the audio device sample rate to match the source — a 24/96 FLAC played on a device set to 48kHz will be resampled by CoreAudio. Apple Music's "Lossless" switcher handles this by inspecting the current AVPlayerItem's sample rate and calling `AudioObjectSetPropertyData` with `kAudioDevicePropertyNominalSampleRate` on the default output device. See [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) for a working pattern.
- When running through the AVAudioEngine path (#13), connect `playerNode → eq → mixer → engine.outputNode` and query `AVAudioFormat` on the incoming buffer. If sample rate ≠ device rate, attempt to switch the device. If switch fails (device busy, locked by another app, rejected by hardware), fall back to resampling by CoreAudio and log.
- Offer a setting: "Match audio device sample rate to source" (default off — it can cause audible clicks during the switch and surprises users). Document the tradeoff.
- Watch out for Bluetooth/AirPlay: those devices have fixed 44.1/48 kHz capabilities and rejecting the switch is normal. Don't retry indefinitely.
- **Acceptance:** With the setting on, a 24/96 FLAC causes the output device sample rate to switch to 96 kHz (visible in Audio MIDI Setup); a 44.1 MP3 afterward switches back; AirPlay playback skips the switch.

References: [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) • [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) • [Core Audio Essentials](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/CoreAudioEssentials/CoreAudioEssentials.html).

---

### Issue 21: Scrobbling — ListenBrainz/Last.fm MVP
**Labels:** `area:macos`, `area:core`, `kind:feat`, `priority:p2`
**Effort:** M
**Depends on:** —

- Jellyfin already has a scrobbling plugin story on the server side, but several users prefer client-side scrobbling (it survives partial plays better and respects the client's definition of "played"). Implement native ListenBrainz support — it has a Last.fm-compatible endpoint ([docs](https://listenbrainz.readthedocs.io/en/latest/users/api-compat.html)) so one implementation covers both services.
- Scope: send a "listen" when the track is >50% played OR >4 minutes elapsed (standard rule). Add a `Scrobbler` to the Rust core so it can work for Linux/Windows too. Queue offline listens to disk when the network is down.
- Include `musicBrainzTrackID` when Jellyfin provides it (requires adding the field to `Track` in core — it's `MusicBrainzTrackId` on the Jellyfin item JSON).
- Settings screen: user token input, toggle per-service.
- **Acceptance:** A played track (>50%) appears on the user's ListenBrainz timeline within ~60s; offline plays queue and sync when back online.

References: [Last.FM compatible API for ListenBrainz](https://listenbrainz.readthedocs.io/en/latest/users/api-compat.html) • [vibrdrome](https://github.com/ddmoney420/vibrdrome) has a working Navidrome + ListenBrainz Swift impl to study.

---

### Issue 22: Audio session / background playback configuration (macOS)
**Labels:** `area:macos`, `area:audio`, `kind:chore`, `priority:p1`
**Effort:** S
**Depends on:** —

- **AVAudioSession is iOS-only** — there is no macOS equivalent. On macOS, AVPlayer talks to CoreAudio directly and there's no "category" concept. Document this in the code (a comment at the top of `AudioEngine.swift`) so nobody reaches for `AVAudioSession.sharedInstance()` and imports AVFoundation-iOS stubs. Currently-expected macOS behaviors the app needs:
  - Audio continues when window is minimized ✓ (default behavior).
  - Audio continues when user switches to another app ✓ (default).
  - No need to request background audio entitlements (iOS-specific).
- Confirm app sandbox entitlements allow outgoing network for audio streaming. The audio engine does not need mic entitlements (don't add `NSMicrophoneUsageDescription` — it would spuriously prompt the user).
- Ensure `Info.plist` has no `LSBackgroundOnly` or `LSUIElement` (unless the user opts into the menu bar-only mode from #18).
- **Acceptance:** Playback continues when the app window is closed to the Dock; no spurious microphone permission prompt; no background entitlement warnings during notarization.

---

### Issue 23: Elapsed-time sync strategy with MPNowPlayingInfoCenter
**Labels:** `area:macos`, `area:audio`, `kind:bug`, `priority:p1`
**Effort:** S
**Depends on:** #1

- macOS's Now Playing widget computes progress from `elapsedPlaybackTime + (wallClockNow - lastUpdateTime) * playbackRate`. The correct pattern is to update `elapsed` and `rate` **only** on play, pause, and seek — not every 0.5s tick. Continuously updating `elapsed` is wasteful and causes the Control Center scrubber to stutter.
- Action: remove the current "push position 2× a second" behavior from the MediaSession path. Keep the Rust-side `core.markPosition` tick (used for scrobbling thresholds and UI updates) but don't feed it to `MPNowPlayingInfoCenter`.
- Do update `elapsed` + `rate` on: track change, play, pause, seek (after-seek), buffering start/end.
- On buffering start, set `rate = 0.0` so the widget freezes its progress. On buffering end, set `rate = 1.0` with the still-accurate `elapsed`.
- **Acceptance:** Control Center scrubber advances smoothly at 1× with zero stutter; pausing the app stops the scrubber instantly; seeking is reflected in <100ms.

---

### Issue 24: CarPlay — confirm out of scope; document for the record
**Labels:** `area:macos`, `kind:docs`, `priority:p2`
**Effort:** S
**Depends on:** —

- CarPlay is iOS-only (CarPlay framework is iOS); it's not applicable to `jellify-desktop`. iOS Jellify (the React Native app in the sibling repo `jellify/`) is the home for CarPlay.
- Add a comment in `AudioEngine.swift` explaining that any CarPlay-ish patterns you might see in iOS Jellify's codebase don't apply here.
- **Acceptance:** `README.md` and `CONTRIBUTING.md` note that desktop has no CarPlay and iOS covers it.

---

### Issue 25: Test harness for media integration (CI-friendly)
**Labels:** `area:macos`, `kind:test`, `priority:p1`
**Effort:** M
**Depends on:** #1, #3, #10

- Extend `Sources/SmokeTest/main.swift` with a non-interactive harness that:
  - Sets up `AudioEngine` + `MediaSession` with a fake `JellifyCore` double (just build an in-memory `PlayerStatus` and stream a tiny test asset from disk via `file://`).
  - Exercises each MPRemoteCommand handler and asserts state transitions.
  - Simulates buffer stall via `URLProtocol` interception.
  - Verifies `MPNowPlayingInfoCenter.default().nowPlayingInfo` dictionary contents after each transition.
- Run on CI headless (no real audio output needed — AVPlayer + AVAudioEngine both work without a speaker attached; verify with a `nullAudioDevice` or `AVAudioEngine.enableManualRenderingMode`).
- Add `XCTest` cases for `AudioEngine` and `MediaSession` in a new `Tests/` target.
- **Acceptance:** `swift test` runs green locally and in CI; coverage includes happy path, stall+recovery, track change, seek, enable/disable of commands at queue bounds.

---

## Out-of-scope / deliberately omitted

- Siri / Shortcuts integration — worth a separate tracking issue later; requires `INIntent` subclasses per transport action. Not P0.
- Spatial Audio / Dolby Atmos — Jellyfin doesn't currently tag tracks as Atmos and AVPlayer passthrough for Atmos-in-music requires very specific CoreAudio channel configurations that go beyond "media integration." Separate epic.
- Share extension / Universal Clipboard — not media-integration proper.
- HomeKit / Matter scene triggers ("Hey Siri, play my rock playlist") — downstream of Siri, omit for now.

---

## Build/graph order cheat sheet

```
 1  MediaSession              ──┐
 2  Artwork loader             │   P0 foundation
 3  MPRemoteCommandCenter     ─┤
 4  changePlaybackPosition    ─┤
10  Error + stall handling    ─┘

 6  Shuffle/Repeat (core)   ──┐
 7  Like (favorites)         │   P1 fills
 8  Media keys verification  │
 9  AVRCP verification       │
11  AVQueuePlayer gapless    │
12  AirPlay picker           │
19  Keyboard shortcuts       │
22  macOS audio session doc  │
23  Elapsed-time sync        │
25  Test harness            ─┘

 5  Skip ±15s              ──┐
13  AVAudioEngine pipeline   │
14  10-band EQ               │   P2 polish
15  Crossfade                │
16  ReplayGain               │
17  Dock tile progress       │
18  MenuBarExtra mini-player │
20  Lossless sample rate     │
21  Scrobbling               │
24  CarPlay (docs only)     ─┘
```
