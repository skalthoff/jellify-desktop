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

#[derive(Clone, Debug, uniffi::Record)]
pub struct PlayerStatus {
    pub state: PlaybackState,
    pub current_track: Option<Track>,
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub volume: f32,
    pub queue_position: u32,
    pub queue_length: u32,
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
