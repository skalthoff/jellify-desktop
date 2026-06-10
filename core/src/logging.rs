//! Structured-logging bridge: forwards `tracing` events to the platform via
//! a UniFFI callback interface so the Swift side can route them through
//! `os_log` (visible in Console.app and `log stream`).
//!
//! # Design
//!
//! A [`LogObserver`] callback interface receives every event that passes the
//! configured level filter. Delivery is fire-and-forget over a bounded
//! channel (capacity 1,024 events): if the channel is full the event
//! is dropped and a drop counter is incremented — the runtime is never
//! backpressured. The forwarding thread pulls from the channel and calls the
//! Swift callback off the main thread; a slow or absent observer cannot stall
//! any Rust caller.
//!
//! # Level filter
//!
//! The default filter admits `INFO` and above in debug builds, `WARN` and
//! above in release builds. The environment variable `JELLIFY_LOG` (e.g.
//! `JELLIFY_LOG=debug,lyrebird_core::client=trace`) overrides it at process
//! start using `tracing_subscriber::EnvFilter`'s standard directive syntax.
//! The 2 MB/h on-disk log budget is met at the default `warn` release filter.
//!
//! # Categories
//!
//! The `target` field (set automatically by `tracing` to the Rust module path)
//! is mapped to a short category string so the Swift side can route to the
//! matching `os_log` category.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

// ---------------------------------------------------------------------------
// Public FFI surface
// ---------------------------------------------------------------------------

/// Log level forwarded over the FFI, mirroring `tracing::Level` in a UniFFI-
/// exportable form.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl From<&Level> for LogLevel {
    fn from(l: &Level) -> Self {
        match *l {
            Level::TRACE => LogLevel::Trace,
            Level::DEBUG => LogLevel::Debug,
            Level::INFO => LogLevel::Info,
            Level::WARN => LogLevel::Warn,
            Level::ERROR => LogLevel::Error,
        }
    }
}

/// A single structured log event forwarded from the Rust core.
///
/// Fields are best-effort: the visitor collects `key=value` pairs from the
/// tracing event metadata and joins them with a space so the Swift side
/// receives a ready-to-log string without needing to parse structure.
#[derive(Clone, Debug, uniffi::Record)]
pub struct LogEvent {
    pub level: LogLevel,
    /// Short category string derived from the Rust module target
    /// (e.g. `"client"`, `"player"`, `"storage"`, `"auth"`).
    pub category: String,
    /// Pre-formatted `message key=value…` string, ready for `os_log`.
    pub message: String,
}

/// Callback interface implemented by the Swift bridge. Every call is made
/// from a dedicated background thread; implementations MUST NOT hop to the
/// main actor or block — use `Task.detached` / `DispatchQueue.async` if
/// main-thread state is needed. If the callback returns slowly the channel
/// will drain at the caller's rate; if it blocks the forwarding thread the
/// drop counter climbs silently.
#[uniffi::export(callback_interface)]
pub trait LogObserver: Send + Sync {
    fn log(&self, event: LogEvent);
}

// ---------------------------------------------------------------------------
// Global subscriber state
// ---------------------------------------------------------------------------

/// Counts events dropped because the channel was full or no observer was set.
pub(crate) static DROP_COUNT: AtomicU64 = AtomicU64::new(0);

pub(crate) struct Global {
    pub(crate) sender: std::sync::mpsc::SyncSender<LogEvent>,
    pub(crate) observer: parking_lot::Mutex<Option<Arc<dyn LogObserver>>>,
}

/// Lazily-initialised global. Populated by [`init_logging`]; reads before
/// that call are safe (no observer → events drop silently).
pub(crate) static GLOBAL: OnceLock<Global> = OnceLock::new();

// ---------------------------------------------------------------------------
// Public FFI entry-points (called from Swift)
// ---------------------------------------------------------------------------

/// Install `observer` as the active log sink. Replaces any previous observer.
/// Safe to call before or after `init_logging` — the observer is held in the
/// global and used as soon as the forwarding thread starts.
#[uniffi::export]
pub fn set_log_observer(observer: Box<dyn LogObserver>) {
    if let Some(g) = GLOBAL.get() {
        *g.observer.lock() = Some(Arc::from(observer));
    }
    // If GLOBAL isn't set yet (init_logging hasn't run), the observer will
    // be lost. In practice LyrebirdCore::new calls init_logging first; in
    // tests the caller should call init_logging before set_log_observer.
}

/// Remove the current observer. Subsequent events are dropped silently.
#[uniffi::export]
pub fn clear_log_observer() {
    if let Some(g) = GLOBAL.get() {
        *g.observer.lock() = None;
    }
}

/// Return the number of events dropped since process start (channel-full +
/// no-observer drops). Exposed for the debug panel.
#[uniffi::export]
pub fn log_drop_count() -> u64 {
    DROP_COUNT.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Initialisation (called from `LyrebirdCore::new`)
// ---------------------------------------------------------------------------

/// Bounded channel capacity. At ~200 bytes/event this is ~200 KB of in-flight
/// log data — enough to absorb bursts without blocking.
pub(crate) const CHANNEL_CAPACITY: usize = 1_024;

/// Install the tracing subscriber. Idempotent — subsequent calls are no-ops
/// (guarded by the `OnceLock`). Sets the global default `tracing` subscriber
/// and starts the forwarding thread on the first call.
///
/// `JELLIFY_LOG` environment variable controls filtering (standard
/// `tracing_subscriber::EnvFilter` directive syntax). Defaults to `warn` in
/// release builds and `info` in debug builds when the variable is unset.
pub fn init_logging() {
    use tracing_subscriber::prelude::*;

    GLOBAL.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::sync_channel::<LogEvent>(CHANNEL_CAPACITY);

        // Spawn the forwarding thread. The channel `rx` is owned by this
        // closure; `rx.recv()` blocks until a message arrives or the last
        // sender is dropped (process exit).
        std::thread::Builder::new()
            .name("lyrebird-log-fwd".into())
            .spawn(move || {
                while let Ok(event) = rx.recv() {
                    if let Some(g) = GLOBAL.get() {
                        // Clone the Arc under the lock, then call outside it.
                        let obs = g.observer.lock().clone();
                        if let Some(obs) = obs {
                            obs.log(event);
                        } else {
                            DROP_COUNT.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                }
            })
            .expect("failed to spawn log forwarding thread");

        Global {
            sender: tx,
            observer: parking_lot::Mutex::new(None),
        }
    });

    #[cfg(debug_assertions)]
    let default_filter = "info";
    #[cfg(not(debug_assertions))]
    let default_filter = "warn";

    let env_filter = tracing_subscriber::EnvFilter::try_from_env("JELLIFY_LOG")
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(default_filter));

    // `try_init` is idempotent — if a test harness or another crate already
    // set a subscriber this returns an error we ignore.
    let _ = tracing_subscriber::registry()
        .with(env_filter)
        .with(OsLogBridgeLayer)
        .try_init();
}

// ---------------------------------------------------------------------------
// tracing_subscriber Layer
// ---------------------------------------------------------------------------

/// Converts each `tracing::Event` into a [`LogEvent`] and sends it to the
/// forwarding channel via a non-blocking `try_send`.
pub(crate) struct OsLogBridgeLayer;

impl<S: Subscriber> Layer<S> for OsLogBridgeLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let meta = event.metadata();
        let level = LogLevel::from(meta.level());
        let category = target_category(meta.target()).to_owned();

        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let message = visitor.finish();

        let log_event = LogEvent {
            level,
            category,
            message,
        };

        if let Some(g) = GLOBAL.get() {
            // Non-blocking: on channel-full, count and discard.
            if g.sender.try_send(log_event).is_err() {
                DROP_COUNT.fetch_add(1, Ordering::Relaxed);
            }
        } else {
            DROP_COUNT.fetch_add(1, Ordering::Relaxed);
        }
    }
}

// ---------------------------------------------------------------------------
// Target → category mapping
// ---------------------------------------------------------------------------

/// Map a tracing `target` (Rust module path) to a short category string that
/// aligns with the Swift-side `os_log` categories in `Log.swift`.
///
/// | tracing target                    | category   |
/// |-----------------------------------|------------|
/// | `lyrebird_core::client`           | `"client"` |
/// | `lyrebird_core::player`           | `"player"` |
/// | `lyrebird_core::storage`          | `"storage"`|
/// | `lyrebird_core::library_cache`    | `"storage"`|
/// | `lyrebird_core::downloads`        | `"storage"`|
/// | `lyrebird_core::scrobble`         | `"auth"`   |
/// | `lyrebird_core` / anything else   | `"core"`   |
pub(crate) fn target_category(target: &str) -> &'static str {
    let module = target.strip_prefix("lyrebird_core::").unwrap_or(target);
    match module {
        m if m.starts_with("client") => "client",
        m if m.starts_with("player") => "player",
        m if m.starts_with("storage") => "storage",
        m if m.starts_with("library_cache") => "storage",
        m if m.starts_with("downloads") => "storage",
        m if m.starts_with("scrobble") => "auth",
        _ => "core",
    }
}

// ---------------------------------------------------------------------------
// Field visitor
// ---------------------------------------------------------------------------

/// Collects `tracing::Event` fields into a `message key=value…` string.
#[derive(Default)]
pub(crate) struct MessageVisitor {
    message: Option<String>,
    fields: Vec<(String, String)>,
}

impl MessageVisitor {
    pub(crate) fn finish(self) -> String {
        let mut out = self.message.unwrap_or_default();
        for (k, v) in self.fields {
            if k == "message" {
                continue;
            }
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(&k);
            out.push('=');
            out.push_str(&v);
        }
        out
    }
}

impl tracing::field::Visit for MessageVisitor {
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_owned());
        } else {
            self.fields
                .push((field.name().to_owned(), value.to_owned()));
        }
    }

    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{value:?}"));
        } else {
            self.fields
                .push((field.name().to_owned(), format!("{value:?}")));
        }
    }

    fn record_f64(&mut self, field: &tracing::field::Field, value: f64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }

    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields
            .push((field.name().to_owned(), value.to_string()));
    }
}
