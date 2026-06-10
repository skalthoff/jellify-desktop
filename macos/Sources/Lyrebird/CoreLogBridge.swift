import Foundation
import os
@preconcurrency import LyrebirdCore

/// Routes `tracing` events from the Rust core to `os_log`.
///
/// The Rust core emits structured log events through the `LogObserver`
/// UniFFI callback interface (registered in `installCoreLogBridge`).
/// `CoreLogBridge.log(event:)` maps each event to the appropriate
/// `os.Logger` instance and level so Rust diagnostics appear in
/// Console.app under `subsystem == "org.lyrebird.desktop"` alongside
/// the Swift-side log entries.
///
/// # Level mapping
///
/// | Rust `tracing` level | `os_log` API call         |
/// |----------------------|---------------------------|
/// | `trace` / `debug`    | `logger.debug(...)`       |
/// | `info`               | `logger.info(...)`        |
/// | `warn`               | `logger.error(...)`       |
/// | `error`              | `logger.fault(...)`       |
///
/// `warn` maps to `os_log` error (not notice) so it survives the default
/// `--info` filter in `log stream` without requiring `--debug`. `error`
/// maps to fault so it is always persisted to disk regardless of the
/// stream level.
///
/// # Threading
///
/// `CoreLogBridge.log(event:)` is called from the Rust forwarding thread
/// (not the main thread). `os.Logger` calls are thread-safe and require
/// no main-actor hop — events are forwarded synchronously and cheaply.
///
/// # Debug panel
///
/// The debug panel's Logs tab reads `OSLogStore` filtered to
/// `subsystem == "org.lyrebird.desktop"`. Because `CoreLogBridge` writes
/// to that subsystem, core events appear there automatically once the
/// bridge is installed.
final class CoreLogBridge: LogObserver, @unchecked Sendable {
    // Loggers keyed by category. Created once; `os.Logger` is safe to
    // share across threads and has negligible construction cost.
    private let loggers: [String: Logger]
    private let fallback: Logger

    init() {
        let sub = Log.subsystem
        loggers = [
            "client":  Logger(subsystem: sub, category: "core.client"),
            "player":  Logger(subsystem: sub, category: "core.player"),
            "storage": Logger(subsystem: sub, category: "core.storage"),
            "auth":    Logger(subsystem: sub, category: "core.auth"),
            "core":    Logger(subsystem: sub, category: "core"),
        ]
        fallback = Logger(subsystem: sub, category: "core")
    }

    // MARK: - LogObserver

    func log(event: LogEvent) {
        let logger = loggers[event.category] ?? fallback
        // Privacy: mark as .public so the message survives the unified-log
        // scrubber. Rust log messages should not carry PII; if they do, the
        // Rust call site is responsible for redaction before emission.
        let msg = event.message
        switch event.level {
        case .trace, .debug:
            logger.debug("\(msg, privacy: .public)")
        case .info:
            logger.info("\(msg, privacy: .public)")
        case .warn:
            logger.error("\(msg, privacy: .public)")
        case .error:
            logger.fault("\(msg, privacy: .public)")
        }
    }
}

// MARK: - Installation

extension AppModel {
    /// Install the core log bridge. Call once, early in `init()`, before
    /// any `LyrebirdCore` method that might emit log events.
    ///
    /// Safe to call multiple times — subsequent calls replace the observer
    /// (the `setLogObserver` FFI is idempotent on the Rust side).
    func installCoreLogBridge() {
        setLogObserver(observer: CoreLogBridge())
    }
}
