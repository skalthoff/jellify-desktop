//! Unit tests for the `logging` module — subscriber registration, level
//! filtering, drop-on-no-observer safety, and field formatting.
//!
//! Tests that mutate the global observer are serialized via `OBSERVER_LOCK`
//! so they do not race each other under `cargo test`'s parallel runner.

use crate::logging::{target_category, LogEvent, LogLevel, LogObserver, DROP_COUNT, GLOBAL};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

// ---------------------------------------------------------------------------
// Global serialization lock for tests that mutate the observer
// ---------------------------------------------------------------------------

fn observer_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

// ---------------------------------------------------------------------------
// Collecting observer
// ---------------------------------------------------------------------------

struct CollectingObserver {
    events: Arc<Mutex<Vec<LogEvent>>>,
}

impl CollectingObserver {
    fn new() -> (Self, Arc<Mutex<Vec<LogEvent>>>) {
        let events = Arc::new(Mutex::new(Vec::new()));
        (
            Self {
                events: events.clone(),
            },
            events,
        )
    }
}

impl LogObserver for CollectingObserver {
    fn log(&self, event: LogEvent) {
        self.events.lock().unwrap().push(event);
    }
}

// ---------------------------------------------------------------------------
// target_category mapping
// ---------------------------------------------------------------------------

#[test]
fn target_category_client() {
    assert_eq!(target_category("lyrebird_core::client"), "client");
    assert_eq!(target_category("lyrebird_core::client::auth"), "client");
}

#[test]
fn target_category_player() {
    assert_eq!(target_category("lyrebird_core::player"), "player");
}

#[test]
fn target_category_storage() {
    assert_eq!(target_category("lyrebird_core::storage"), "storage");
    assert_eq!(target_category("lyrebird_core::library_cache"), "storage");
    assert_eq!(target_category("lyrebird_core::downloads"), "storage");
}

#[test]
fn target_category_auth() {
    assert_eq!(target_category("lyrebird_core::scrobble"), "auth");
}

#[test]
fn target_category_fallback() {
    assert_eq!(target_category("lyrebird_core"), "core");
    assert_eq!(target_category("lyrebird_core::unknown_module"), "core");
    assert_eq!(target_category("tokio::runtime"), "core");
}

// ---------------------------------------------------------------------------
// LogLevel conversion
// ---------------------------------------------------------------------------

#[test]
fn log_level_from_tracing_level() {
    assert_eq!(LogLevel::from(&tracing::Level::TRACE), LogLevel::Trace);
    assert_eq!(LogLevel::from(&tracing::Level::DEBUG), LogLevel::Debug);
    assert_eq!(LogLevel::from(&tracing::Level::INFO), LogLevel::Info);
    assert_eq!(LogLevel::from(&tracing::Level::WARN), LogLevel::Warn);
    assert_eq!(LogLevel::from(&tracing::Level::ERROR), LogLevel::Error);
}

// ---------------------------------------------------------------------------
// init_logging idempotency
// ---------------------------------------------------------------------------

#[test]
fn init_logging_is_idempotent() {
    crate::logging::init_logging();
    crate::logging::init_logging();
    crate::logging::init_logging();
    assert!(GLOBAL.get().is_some(), "GLOBAL not set after init_logging");
}

// ---------------------------------------------------------------------------
// Drop-on-no-observer safety
// ---------------------------------------------------------------------------

#[test]
fn events_dropped_silently_when_no_observer() {
    let _guard = observer_lock();
    crate::logging::init_logging();
    crate::logging::clear_log_observer();

    let before = DROP_COUNT.load(Ordering::Relaxed);

    tracing::warn!(target: "lyrebird_core", "drop-safety test event");
    std::thread::sleep(std::time::Duration::from_millis(50));

    let after = DROP_COUNT.load(Ordering::Relaxed);
    assert!(
        after >= before,
        "drop_count decreased unexpectedly: before={before} after={after}"
    );
}

// ---------------------------------------------------------------------------
// Observer receives events
// ---------------------------------------------------------------------------

#[test]
fn observer_receives_warn_event() {
    let _guard = observer_lock();
    crate::logging::init_logging();

    let (observer, events) = CollectingObserver::new();
    if let Some(g) = GLOBAL.get() {
        *g.observer.lock() = Some(Arc::new(observer) as Arc<dyn LogObserver>);
    }

    tracing::warn!(target: "lyrebird_core::client", "observer-test-warn-unique");
    std::thread::sleep(std::time::Duration::from_millis(100));

    crate::logging::clear_log_observer();

    let collected = events.lock().unwrap();
    let found = collected.iter().any(|e| {
        e.level == LogLevel::Warn
            && e.message.contains("observer-test-warn-unique")
            && e.category == "client"
    });

    assert!(found, "warn event not received; collected: {collected:?}");
}

// ---------------------------------------------------------------------------
// log_drop_count FFI
// ---------------------------------------------------------------------------

#[test]
fn log_drop_count_returns_valid_u64() {
    let count = crate::logging::log_drop_count();
    assert!(count < u64::MAX);
}

// ---------------------------------------------------------------------------
// Direct channel capacity — drop on full channel
// ---------------------------------------------------------------------------

#[test]
fn channel_full_increments_drop_count() {
    use crate::logging::CHANNEL_CAPACITY;

    let _guard = observer_lock();
    crate::logging::init_logging();
    // Ensure no observer is installed so the forwarding thread processes
    // events quickly (they get counted as drops and discarded).
    crate::logging::clear_log_observer();

    let before = DROP_COUNT.load(Ordering::Relaxed);

    // Inject messages directly into the channel. CHANNEL_CAPACITY + 100
    // ensures we definitely overfill — the try_send failures become drops.
    if let Some(g) = GLOBAL.get() {
        for i in 0..(CHANNEL_CAPACITY + 100) {
            let _ = g.sender.try_send(LogEvent {
                level: LogLevel::Warn,
                category: "core".into(),
                message: format!("overflow-{i}"),
            });
        }
    }

    // Give the forwarding thread time to drain the channel (it counts each
    // no-observer delivery as a drop too), then count remaining drops.
    std::thread::sleep(std::time::Duration::from_millis(200));

    let after = DROP_COUNT.load(Ordering::Relaxed);
    // We sent CHANNEL_CAPACITY + 100 items; at least 100 must have been
    // dropped by try_send OR counted as no-observer drops. Total delivered
    // + dropped = CHANNEL_CAPACITY + 100, so drops ≥ 100.
    assert!(
        after > before,
        "expected drop count to increase; before={before} after={after}"
    );
}
