//! Lyrebird — Linux desktop entrypoint.
//!
//! Boots an `adw::Application` under app-id `org.lyrebird.Desktop`. Primary
//! instance registration is handled by `gio::Application` itself: the first
//! process acquires the D-Bus name; subsequent invocations hand off to it
//! and exit. The first process then receives `activate` (or `open`) signals
//! and raises / focuses the existing `LyrebirdWindow` rather than creating
//! a second one.
//!
//! `ApplicationFlags::HANDLES_OPEN` is reserved for a future `lyrebird://`
//! deep-link URL scheme (tracked in research/09-linux-port.md); it does not
//! mean we currently handle file opens.
//!
//! Audio playback (GStreamer), MPRIS2, notifications, and individual screens
//! are follow-up batches — this boot sequence intentionally just presents
//! an empty shell window.

mod model;
mod window;

use adw::prelude::*;
use gio::ApplicationFlags;
use libadwaita as adw;
use tracing::info;

use crate::window::LyrebirdWindow;

/// App id — must match the gresource prefix, the `.desktop` entry, and the
/// Flatpak manifest. Changing this is a migration for users (settings keys
/// rebase, D-Bus paths move).
const APP_ID: &str = "org.lyrebird.Desktop";

fn main() -> glib::ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    // Register the compiled gresource bundle. Produced by `build.rs` via
    // `glib-build-tools`; consumed here so every main-loop template lookup
    // sees it. Must run before any `CompositeTemplate`-backed widget
    // constructs so the window's `resource = "/org/lyrebird/Desktop/window.ui"`
    // binding can resolve.
    gio::resources_register_include!("resources.gresource")
        .expect("failed to register compiled gresource bundle");

    let app = adw::Application::builder()
        .application_id(APP_ID)
        .flags(ApplicationFlags::HANDLES_OPEN)
        .resource_base_path("/org/lyrebird/Desktop")
        .build();

    app.connect_activate(|app| {
        // `activate` fires on first launch AND on every subsequent invocation
        // once primary-instance registration routes them here. Reuse the
        // existing window rather than creating a second one — this is what
        // gives us "second launch raises the first window" behaviour.
        if let Some(existing) = app.active_window() {
            existing.present();
            return;
        }

        let window = LyrebirdWindow::new(app);
        window.present();
        info!("lyrebird-desktop activated");
    });

    // `open` is reserved for `lyrebird://` deep links (HANDLES_OPEN). Until
    // the URL scheme lands, treat it like `activate` so users who invoke
    // the binary with stray positional args still get a window.
    app.connect_open(|app, _files, _hint| {
        app.activate();
    });

    app.run()
}
