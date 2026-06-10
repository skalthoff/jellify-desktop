//! Player push-notification stream (#433): `set_player_observer` /
//! `clear_player_observer` and the per-mutation [`PlayerEventKind`] emission
//! contract that replaced the UI's 1 Hz `status()` poll.

use super::*;
use crate::models::Track;
use crate::player::{PlaybackState, PlayerEventKind, PlayerObserver, PlayerStatus};
use std::sync::{Arc, Mutex};

fn track(id: &str) -> Track {
    Track {
        id: id.into(),
        name: id.into(),
        album_id: None,
        album_name: None,
        artist_name: "Artist".into(),
        artist_id: None,
        index_number: None,
        disc_number: None,
        year: None,
        runtime_ticks: 1_800_000_000,
        is_favorite: false,
        play_count: 0,
        container: None,
        bitrate: None,
        image_tag: None,
        playlist_item_id: None,
        user_data: None,
    }
}

/// Shared event log a test can keep a handle to while the boxed observer is
/// owned by the core. Each entry is one `player_changed` push.
#[derive(Default)]
struct Recorder {
    events: Mutex<Vec<(u64, Vec<PlayerEventKind>, PlayerStatus)>>,
}

impl Recorder {
    fn events(&self) -> Vec<(u64, Vec<PlayerEventKind>, PlayerStatus)> {
        self.events.lock().unwrap().clone()
    }

    fn kinds(&self) -> Vec<Vec<PlayerEventKind>> {
        self.events().into_iter().map(|(_, k, _)| k).collect()
    }
}

struct RecorderHandle(Arc<Recorder>);

impl PlayerObserver for RecorderHandle {
    fn player_changed(&self, seq: u64, kinds: Vec<PlayerEventKind>, status: PlayerStatus) {
        self.0.events.lock().unwrap().push((seq, kinds, status));
    }
}

/// Build a temp-backed core with a recording observer already registered.
fn observed_core(tmp: &tempfile::TempDir) -> (std::sync::Arc<LyrebirdCore>, Arc<Recorder>) {
    let core = resume_test_core(tmp);
    let recorder = Arc::new(Recorder::default());
    core.set_player_observer(Box::new(RecorderHandle(Arc::clone(&recorder))));
    (core, recorder)
}

#[test]
fn set_queue_pushes_track_and_queue_change_with_snapshot() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b")], 0).unwrap();

    let events = recorder.events();
    assert_eq!(events.len(), 1, "one mutation, one push");
    let (_, kinds, status) = &events[0];
    assert_eq!(
        kinds,
        &vec![PlayerEventKind::TrackChanged, PlayerEventKind::QueueChanged]
    );
    // The push carries the complete post-mutation snapshot.
    assert_eq!(status.current_track.as_ref().unwrap().id, "a");
    assert_eq!(status.queue_length, 2);
    assert_eq!(status.queue_position, 0);
}

#[test]
fn mark_state_pushes_only_on_actual_transition() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.mark_state(PlaybackState::Playing);
    core.mark_state(PlaybackState::Playing); // idempotent — no push
    core.mark_state(PlaybackState::Paused);

    let kinds = recorder.kinds();
    assert_eq!(
        kinds,
        vec![
            vec![PlayerEventKind::StateChanged],
            vec![PlayerEventKind::StateChanged],
        ],
        "re-marking the same state must not push"
    );
    let events = recorder.events();
    assert_eq!(events[0].2.state, PlaybackState::Playing);
    assert_eq!(events[1].2.state, PlaybackState::Paused);
}

#[test]
fn mark_position_never_pushes() {
    // The energy contract behind #433: the 1 Hz position tick must not echo
    // back out as an event, or the idle wake-storm the stream removed would
    // be reintroduced one layer down.
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a")], 0).unwrap();
    let baseline = recorder.events().len();

    for tick in 0..60 {
        core.mark_position(f64::from(tick));
    }

    assert_eq!(
        recorder.events().len(),
        baseline,
        "mark_position must be event-silent"
    );
    // But the next real push carries the freshest position.
    core.mark_state(PlaybackState::Playing);
    let events = recorder.events();
    let (_, _, status) = events.last().unwrap();
    assert_eq!(status.position_seconds, 59.0);
}

#[test]
fn volume_shuffle_repeat_and_session_id_do_not_push() {
    // These setters' UI call sites refresh `status()` inline, so they are
    // deliberately outside the event set (state / track / queue).
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_volume(0.5);
    core.set_shuffle(true);
    core.set_repeat_mode(RepeatMode::All);
    core.set_play_session_id(Some("sess-1".into()));

    assert!(
        recorder.events().is_empty(),
        "volume/shuffle/repeat/session-id must not push, got {:?}",
        recorder.kinds()
    );
}

#[test]
fn mark_track_started_pushes_state_and_track_once() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.mark_track_started(track("a"));
    // Re-marking the same track while already Playing changes nothing
    // observable — no push.
    core.mark_track_started(track("a"));

    let kinds = recorder.kinds();
    assert_eq!(
        kinds,
        vec![vec![
            PlayerEventKind::StateChanged,
            PlayerEventKind::TrackChanged,
        ]],
        "second same-track mark must be silent"
    );
    let events = recorder.events();
    assert_eq!(events[0].2.state, PlaybackState::Playing);
    assert_eq!(events[0].2.current_track.as_ref().unwrap().id, "a");
}

#[test]
fn mark_track_started_realigns_queue_cursor_and_pushes_queue_change() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b"), track("c")], 0)
        .unwrap();
    core.mark_track_started(track("c"));

    let kinds = recorder.kinds();
    assert_eq!(
        kinds.last().unwrap(),
        &vec![
            PlayerEventKind::StateChanged,
            PlayerEventKind::TrackChanged,
            PlayerEventKind::QueueChanged,
        ],
        "in-queue track start moves the cursor too"
    );
    let events = recorder.events();
    assert_eq!(events.last().unwrap().2.queue_position, 2);
}

#[test]
fn skip_next_pushes_cursor_move_and_is_silent_at_end_of_queue() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b")], 0).unwrap();
    let baseline = recorder.events().len();

    assert_eq!(core.skip_next().unwrap().id, "b");
    let events = recorder.events();
    assert_eq!(events.len(), baseline + 1);
    let (_, kinds, status) = events.last().unwrap();
    assert_eq!(
        kinds,
        &vec![PlayerEventKind::TrackChanged, PlayerEventKind::QueueChanged]
    );
    assert_eq!(status.current_track.as_ref().unwrap().id, "b");
    assert_eq!(status.queue_position, 1);

    // End of queue with RepeatMode::Off: nothing changes, nothing pushes.
    assert!(core.skip_next().is_none());
    assert_eq!(recorder.events().len(), baseline + 1);
}

#[test]
fn skip_previous_pushes_cursor_move() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b")], 1).unwrap();
    let baseline = recorder.events().len();

    assert_eq!(core.skip_previous().unwrap().id, "a");
    let events = recorder.events();
    assert_eq!(events.len(), baseline + 1);
    assert_eq!(
        events.last().unwrap().1,
        vec![PlayerEventKind::TrackChanged, PlayerEventKind::QueueChanged]
    );

    // At the start with RepeatMode::Off: silent no-op.
    assert!(core.skip_previous().is_none());
    assert_eq!(recorder.events().len(), baseline + 1);
}

#[test]
fn repeat_all_wrap_on_single_track_queue_is_silent() {
    // The wrap lands on the same index and the same track — nothing about
    // the snapshot changed, so the push must be suppressed even though
    // skip_next returned Some.
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a")], 0).unwrap();
    core.set_repeat_mode(RepeatMode::All);
    let baseline = recorder.events().len();

    assert_eq!(core.skip_next().unwrap().id, "a");
    assert_eq!(recorder.events().len(), baseline);
}

#[test]
fn play_next_and_add_to_queue_push_queue_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b")], 0).unwrap();
    let baseline = recorder.events().len();

    core.play_next(vec![track("x")]);
    core.add_to_queue(vec![track("y")]);
    // Empty inputs are genuine no-ops — silent.
    core.play_next(vec![]);
    core.add_to_queue(vec![]);

    let events = recorder.events();
    assert_eq!(events.len(), baseline + 2);
    assert_eq!(events[baseline].1, vec![PlayerEventKind::QueueChanged]);
    assert_eq!(events[baseline + 1].1, vec![PlayerEventKind::QueueChanged]);
    assert_eq!(events[baseline + 1].2.queue_length, 4);
}

#[test]
fn play_next_on_cold_queue_pushes_track_change_too() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.play_next(vec![track("x"), track("y")]);

    let events = recorder.events();
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0].1,
        vec![PlayerEventKind::TrackChanged, PlayerEventKind::QueueChanged],
        "priming the playhead on an empty queue is a track change"
    );
    assert_eq!(events[0].2.current_track.as_ref().unwrap().id, "x");
}

#[test]
fn clear_queue_pushes_queue_change_only_when_something_changed() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b"), track("c")], 1)
        .unwrap();
    let baseline = recorder.events().len();

    core.clear_queue();
    let events = recorder.events();
    assert_eq!(events.len(), baseline + 1);
    assert_eq!(
        events.last().unwrap().1,
        vec![PlayerEventKind::QueueChanged]
    );
    assert_eq!(events.last().unwrap().2.queue_length, 1);

    // Already a single-item queue holding the current track — second clear
    // changes nothing and must be silent.
    core.clear_queue();
    assert_eq!(recorder.events().len(), baseline + 1);
}

#[test]
fn stop_pushes_state_track_and_queue_teardown() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b")], 0).unwrap();
    core.mark_track_started(track("a"));
    let baseline = recorder.events().len();

    core.stop();

    let events = recorder.events();
    assert_eq!(events.len(), baseline + 1);
    let (_, kinds, status) = events.last().unwrap();
    assert_eq!(
        kinds,
        &vec![
            PlayerEventKind::StateChanged,
            PlayerEventKind::TrackChanged,
            PlayerEventKind::QueueChanged,
        ]
    );
    assert_eq!(status.state, PlaybackState::Stopped);
    assert!(status.current_track.is_none());
    assert_eq!(status.queue_length, 0);

    // Stopping an already-stopped player changes nothing — silent.
    core.stop();
    assert_eq!(recorder.events().len(), baseline + 1);
}

#[test]
fn seq_is_monotonic_in_mutation_order() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, recorder) = observed_core(&tmp);

    core.set_queue(vec![track("a"), track("b"), track("c")], 0)
        .unwrap();
    core.mark_track_started(track("a"));
    core.skip_next();
    core.mark_state(PlaybackState::Paused);
    core.stop();

    let seqs: Vec<u64> = recorder.events().iter().map(|(s, _, _)| *s).collect();
    assert!(!seqs.is_empty());
    assert!(
        seqs.windows(2).all(|w| w[1] > w[0]),
        "seq must strictly increase in mutation order, got {seqs:?}"
    );
}

#[test]
fn clear_player_observer_stops_pushes_and_replacement_reroutes() {
    let tmp = tempfile::tempdir().unwrap();
    let (core, first) = observed_core(&tmp);

    core.mark_state(PlaybackState::Playing);
    assert_eq!(first.events().len(), 1);

    core.clear_player_observer();
    core.mark_state(PlaybackState::Paused);
    assert_eq!(first.events().len(), 1, "cleared observer must go silent");

    // A replacement observer picks up subsequent pushes; the displaced one
    // stays silent. seq continues from where the player left off, so a
    // subscriber can still apply its drop-stale-seq rule across swaps.
    let second = Arc::new(Recorder::default());
    core.set_player_observer(Box::new(RecorderHandle(Arc::clone(&second))));
    core.mark_state(PlaybackState::Playing);
    assert_eq!(first.events().len(), 1);
    assert_eq!(second.events().len(), 1);
    assert!(second.events()[0].0 >= 3, "seq keeps counting across swaps");
}

/// Observer that re-enters the FFI from inside the callback. Exercises the
/// #433 deadlock contract: no core lock may be held while `player_changed`
/// runs, so `status()` (player lock), `set_volume` (player lock, mutating),
/// and `clear_player_observer` (observer-slot lock) must all be callable
/// here. If emission ever moves back under a lock, this test hangs rather
/// than passes — treat a timeout as a failure of the contract.
struct ReentrantObserver {
    core: std::sync::Arc<LyrebirdCore>,
    seen_states: Arc<Mutex<Vec<PlaybackState>>>,
}

impl PlayerObserver for ReentrantObserver {
    fn player_changed(&self, _seq: u64, _kinds: Vec<PlayerEventKind>, _status: PlayerStatus) {
        // Player-lock read.
        let live = self.core.status();
        // Player-lock write (event-silent, so no recursion).
        self.core.set_volume(0.42);
        // Observer-slot-lock write: unregister ourselves mid-callback.
        self.core.clear_player_observer();
        self.seen_states.lock().unwrap().push(live.state);
    }
}

#[test]
fn observer_may_reenter_ffi_without_deadlock() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    let seen_states = Arc::new(Mutex::new(Vec::new()));
    core.set_player_observer(Box::new(ReentrantObserver {
        core: std::sync::Arc::clone(&core),
        seen_states: Arc::clone(&seen_states),
    }));

    core.mark_state(PlaybackState::Playing);

    let seen = seen_states.lock().unwrap().clone();
    assert_eq!(
        seen,
        vec![PlaybackState::Playing],
        "re-entrant status() must observe the post-mutation state"
    );
    assert_eq!(core.status().volume, 0.42, "re-entrant set_volume applied");
    // The mid-callback unregistration stuck: further mutations are silent.
    core.mark_state(PlaybackState::Paused);
    assert_eq!(seen_states.lock().unwrap().len(), 1);
}
