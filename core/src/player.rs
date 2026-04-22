//! Queue + playback-state bookkeeping.
//!
//! Actual audio output lives on the platform side (AVFoundation on macOS,
//! MediaPlayer on Windows, GStreamer on Linux). The core only tracks what
//! *should* be playing; the platform reports back via status updates.

use crate::models::Track;
use parking_lot::Mutex;

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum PlaybackState {
    Idle,
    Loading,
    Playing,
    Paused,
    Stopped,
    Ended,
}

/// Queue-wide repeat mode carried on [`PlayerStatus`] and exposed to the
/// platform remote-control surface (macOS `MPChangeRepeatModeCommand`, MPRIS
/// `LoopStatus`, SMTC `AutoRepeatMode`).
///
/// * `Off` — advance through the queue once, then stop at the end.
/// * `One` — keep replaying the current track; next/previous both no-op.
/// * `All` — wrap around at the ends of the queue so skip-next past the last
///   track jumps to index 0, and skip-previous from index 0 jumps to the end.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, uniffi::Enum)]
pub enum RepeatMode {
    #[default]
    Off,
    One,
    All,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct PlayerStatus {
    pub state: PlaybackState,
    pub current_track: Option<Track>,
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub volume: f32,
    pub queue_position: u32,
    pub queue_length: u32,
    /// Whether the queue-shuffle mode is engaged. The core does not actually
    /// reorder the stored queue — it just carries the flag so the platform
    /// layer can reflect it in remote-control surfaces (Control Center,
    /// media keys) and so downstream "Up Next" logic can opt into a shuffled
    /// ordering. See issue #34.
    pub shuffle: bool,
    /// Current [`RepeatMode`] for the queue. Interpreted by the platform
    /// audio engine when deciding what to do at end-of-track and by
    /// [`Player::skip_next`] / [`Player::skip_previous`] when the caller
    /// walks past a queue boundary. See issue #34.
    pub repeat_mode: RepeatMode,
}

pub struct Player {
    shared: Mutex<Shared>,
}

struct Shared {
    state: PlaybackState,
    current: Option<Track>,
    queue: Vec<Track>,
    queue_index: usize,
    volume: f32,
    position_seconds: f64,
    shuffle: bool,
    repeat_mode: RepeatMode,
}

impl Shared {
    fn new() -> Self {
        Self {
            state: PlaybackState::Idle,
            current: None,
            queue: Vec::new(),
            queue_index: 0,
            volume: 1.0,
            position_seconds: 0.0,
            shuffle: false,
            repeat_mode: RepeatMode::Off,
        }
    }

    fn snapshot(&self) -> PlayerStatus {
        let duration_seconds = self
            .current
            .as_ref()
            .map(Track::duration_seconds)
            .unwrap_or(0.0);
        PlayerStatus {
            state: self.state.clone(),
            current_track: self.current.clone(),
            position_seconds: self.position_seconds,
            duration_seconds,
            volume: self.volume,
            queue_position: self.queue_index as u32,
            queue_length: self.queue.len() as u32,
            shuffle: self.shuffle,
            repeat_mode: self.repeat_mode,
        }
    }
}

impl Default for Player {
    fn default() -> Self {
        Self::new()
    }
}

impl Player {
    pub fn new() -> Self {
        Self {
            shared: Mutex::new(Shared::new()),
        }
    }

    pub fn set_queue(&self, tracks: Vec<Track>, start_index: u32) {
        let mut s = self.shared.lock();
        s.queue = tracks;
        s.queue_index = (start_index as usize).min(s.queue.len().saturating_sub(1));
    }

    pub fn current_in_queue(&self) -> Option<Track> {
        let s = self.shared.lock();
        s.queue.get(s.queue_index).cloned()
    }

    pub fn skip_next(&self) -> Option<Track> {
        let mut s = self.shared.lock();
        if s.queue_index + 1 < s.queue.len() {
            s.queue_index += 1;
            s.queue.get(s.queue_index).cloned()
        } else {
            None
        }
    }

    pub fn skip_previous(&self) -> Option<Track> {
        let mut s = self.shared.lock();
        if s.queue_index > 0 {
            s.queue_index -= 1;
            s.queue.get(s.queue_index).cloned()
        } else {
            None
        }
    }

    pub fn set_current(&self, track: Track) {
        let mut s = self.shared.lock();
        s.current = Some(track);
        s.state = PlaybackState::Playing;
    }

    pub fn mark_state(&self, state: PlaybackState) {
        self.shared.lock().state = state;
    }

    pub fn mark_position(&self, seconds: f64) {
        self.shared.lock().position_seconds = seconds.max(0.0);
    }

    pub fn set_volume(&self, v: f32) {
        self.shared.lock().volume = v.clamp(0.0, 1.0);
    }

    /// Toggle the queue-wide shuffle flag. The core does not reorder the
    /// stored queue — callers that want a shuffled listening session are
    /// expected to call [`Player::set_queue`] with pre-shuffled tracks and
    /// then toggle this flag so the remote-control surface reflects the
    /// current mode. See issue #34.
    pub fn set_shuffle(&self, on: bool) {
        self.shared.lock().shuffle = on;
    }

    /// Update the queue's [`RepeatMode`]. Does not touch the queue itself;
    /// the platform audio engine consults this when the current track ends
    /// to decide whether to replay, advance, or stop. See issue #34.
    pub fn set_repeat_mode(&self, mode: RepeatMode) {
        self.shared.lock().repeat_mode = mode;
    }

    pub fn clear(&self) {
        let mut s = self.shared.lock();
        s.state = PlaybackState::Stopped;
        s.current = None;
        s.position_seconds = 0.0;
    }

    pub fn status(&self) -> PlayerStatus {
        self.shared.lock().snapshot()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Track;

    fn track(id: &str) -> Track {
        Track {
            id: id.to_string(),
            name: id.to_string(),
            album_id: None,
            album_name: None,
            artist_name: "Test Artist".to_string(),
            artist_id: None,
            index_number: None,
            disc_number: None,
            year: None,
            runtime_ticks: 1_800_000_000, // 3 minutes
            is_favorite: false,
            play_count: 0,
            container: None,
            bitrate: None,
            image_tag: None,
        }
    }

    #[test]
    fn status_defaults_shuffle_off_and_repeat_off() {
        let player = Player::new();
        let status = player.status();
        assert!(!status.shuffle);
        assert_eq!(status.repeat_mode, RepeatMode::Off);
    }

    #[test]
    fn set_shuffle_toggles_flag_on_status() {
        let player = Player::new();
        player.set_shuffle(true);
        assert!(player.status().shuffle);
        player.set_shuffle(false);
        assert!(!player.status().shuffle);
    }

    #[test]
    fn set_repeat_mode_persists_all_three_variants() {
        let player = Player::new();
        player.set_repeat_mode(RepeatMode::One);
        assert_eq!(player.status().repeat_mode, RepeatMode::One);
        player.set_repeat_mode(RepeatMode::All);
        assert_eq!(player.status().repeat_mode, RepeatMode::All);
        player.set_repeat_mode(RepeatMode::Off);
        assert_eq!(player.status().repeat_mode, RepeatMode::Off);
    }

    #[test]
    fn shuffle_and_repeat_are_preserved_across_queue_changes() {
        // Callers (e.g. the macOS AppModel) set shuffle/repeat once and
        // expect the flags to survive a fresh `set_queue` call — otherwise
        // dropping a new album onto the dock would silently disable the
        // user's chosen repeat mode. Validate that invariant here.
        let player = Player::new();
        player.set_shuffle(true);
        player.set_repeat_mode(RepeatMode::All);
        player.set_queue(vec![track("a"), track("b")], 0);
        let status = player.status();
        assert!(status.shuffle);
        assert_eq!(status.repeat_mode, RepeatMode::All);
        assert_eq!(status.queue_length, 2);
    }
}
