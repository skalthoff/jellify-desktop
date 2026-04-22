# Jellify Desktop — Linux Port Issue List

Scope: take `linux/` (currently empty) to a Flathub-published GTK4 + libadwaita Rust
binary that wraps the shared `core/` crate in-process (no FFI; direct `use jellify_core::*`).
Audio via GStreamer `playbin3`. Integration via MPRIS2, `Gio::Notification`, `gio::Settings`.

Reference open-source GTK music players studied for patterns:
- **Amberol** (Rust + GTK4, most architecturally similar; GStreamer + MPRIS2)
- **Lollypop** (Python but has mature MPRIS2 + audio menu patterns worth mirroring)
- **Tauon** (modern GTK4 queue UX)
- **GNOME Music** (official HIG reference)

Milestones:
- **L-M1** — Scaffold + core integration (build, bindings, app lifecycle, settings, CI)
- **L-M2** — Core screens MVP: login → browse → play a track via GStreamer
- **L-M3** — Polish: MPRIS2, media keys, notifications, a11y, keyboard shortcuts, theming
- **L-M4** — Flatpak distribution + Flathub submission

---

## L-M1 — Scaffold + core integration

### Issue 1: Bootstrap `linux/` Cargo crate with gtk-rs + libadwaita dependencies
**Labels:** `area:linux`, `kind:chore`, `priority:p0`
**Effort:** S

Create `linux/Cargo.toml` as a workspace member producing a binary named `jellify-desktop`.
Add to workspace `members` in root `Cargo.toml`.

Dependencies (pinned to a GNOME-46-era stack so we match the Flatpak runtime we'll target):
- `gtk4 = "0.9"` (with features `v4_12`)
- `libadwaita = "0.7"` (with features `v1_5`)
- `glib = "0.20"`, `gio = "0.20"`
- `gstreamer = "0.23"`, `gstreamer-play = "0.23"` (for `playbin3` wrapper) — or `gstreamer-player`
- `gdk-pixbuf = "0.20"`, `gdk4 = "0.9"`
- `jellify_core = { path = "../core" }`
- `tokio = { workspace = true }` (for async shared with core)
- `async-channel = "2"` for async→GTK main-loop bridging
- `tracing`, `tracing-subscriber`, `anyhow` from workspace

Acceptance: `cargo build -p jellify-desktop` compiles a binary on a Linux host with
GTK4 + libadwaita + GStreamer dev packages installed. Document apt/dnf package lists
in `linux/README.md`.

### Issue 2: Configure `build.rs` + gresource pipeline
**Labels:** `area:linux`, `kind:chore`, `priority:p0`
**Effort:** S

Add `glib-build-tools = "0.20"` as a build-dep. Write `linux/build.rs` that calls
`glib_build_tools::compile_resources` against `linux/resources/resources.gresource.xml`.
The XML should bundle:
- `ui/*.ui` (Blueprint-compiled or raw GtkBuilder XML for window shell, login, library)
- `icons/scalable/*.svg` (app + symbolic icons)
- `fonts/*.otf` (Figtree family — see Issue 14)
- `style.css` (app-wide GTK CSS, see Issue 13)

Acceptance: `cargo build` produces a `resources.gresource` artifact consumed at runtime via
`gio::Resource::load` in `main.rs`. A dummy label loaded from a `.ui` file renders on startup.

### Issue 3: `adw::Application` main entry + single-instance handling
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** S

`src/main.rs` boots an `adw::Application` with app-id `org.jellify.Desktop`, flags
`ApplicationFlags::HANDLES_OPEN` (reserved for future `jellify://` deep links).
Register primary-instance handling so a second launch raises the existing window via
`activate` rather than opening a new one.

On `startup`: load the gresource, register fonts (Issue 14), install the global CSS
provider (Issue 13), wire global GActions (`app.quit`, `app.preferences`, `app.about`).

On `activate`: instantiate `JellifyWindow` (custom `adw::ApplicationWindow` subclass),
present it.

Acceptance: launching `jellify-desktop` twice raises one window. `Ctrl+Q` quits via
action accelerator.

### Issue 4: Custom `JellifyWindow` GObject subclass via `glib::subclass`
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

Using `gobject_derive`-style imp modules, create `src/window.rs` with:
- `#[derive(CompositeTemplate)]` backed by `window.ui`
- Private fields for `AdwNavigationView`, `AdwHeaderBar`, content `AdwLeaflet`
- Template children wired via `#[template_child]`
- `ObjectImpl::constructed` hooks up signals, restores window geometry from
  `gio::Settings`, installs per-window GActions (`win.toggle-queue`, `win.play-pause`, etc.)
- Save window size on `close-request`

Acceptance: launching presents a styled `AdwApplicationWindow` with header bar and
empty navigation view. Geometry persists across restarts.

### Issue 5: Embed `JellifyCore` as a shared `Rc`-wrapped model on the main loop
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

Create `src/model.rs` containing an `AppModel` struct that owns
`Arc<JellifyCore>` plus GTK-facing state (`gio::ListStore` backings for albums,
artists, queue; `glib::Property`-derived custom GObject wrappers around
`jellify_core::{Album, Artist, Track}`).

Pattern: core calls (which are synchronous and internally `tokio::block_on`) run on a
worker thread via `gio::spawn_blocking` or an `async-channel` bridge. Results posted
back to the GTK main loop via `glib::MainContext::spawn_local`.

Expose `AppModel` through the window's imp so children can `window.model()`.

Acceptance: `AppModel::new(core_config)` instantiates successfully, exposes
`probe_server`, `login`, `list_albums` etc. as async wrappers that return via a
main-loop-safe future.

### Issue 6: Wrap core models as `gio::ListModel`-compatible GObjects
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

For `gtk::ListView` and `gtk::GridView` to render core `Album`/`Track`/`Artist` records
efficiently, each needs to be a `GObject`. Using the `glib::Properties` derive macro,
create thin wrappers:
- `AlbumObject` → holds `Album` + computes `image_url` lazily
- `ArtistObject`, `TrackObject`, `PlaylistObject` equivalents

These plug into `gio::ListStore::<AlbumObject>` and feed a `SignalListItemFactory`.
Avoid cloning — hold `Rc<Album>` internally.

Acceptance: a `gio::ListStore` of `AlbumObject` can back a `gtk::GridView` with a
bind-closure that populates a child template.

### Issue 7: `gio::Settings` schema + preferences integration
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** S

Author `data/org.jellify.Desktop.gschema.xml` with keys:
- `window-width`, `window-height`, `window-maximized`
- `last-server-url`, `last-username` (mirroring what core persists to SQLite, for
  quick-launch UX)
- `theme-preset` (enum: purple | dark | oled | light | teal — see theming)
- `color-scheme-follow-system` (bool)
- `use-gapless` (bool)
- `volume` (double 0..1)

Install via `build.rs` or packaging step to
`$prefix/share/glib-2.0/schemas/`, compile with `glib-compile-schemas` during dev.

Wire bindings via `gio::Settings::bind` so the window state properties auto-persist.

Acceptance: changing window size and restarting restores the same size via dconf.

### Issue 8: Credential storage verification (libsecret via `keyring` crate)
**Labels:** `area:linux`, `kind:chore`, `priority:p1`
**Effort:** S

The workspace already uses the `keyring` crate (v3). On Linux this must resolve to
the `secret-service` backend — **not** the Mock provider. Add an explicit feature
enablement in `core/Cargo.toml`:

```toml
[target.'cfg(target_os = "linux")'.dependencies]
keyring = { version = "3", features = ["linux-native-sync-persistent", "sync-secret-service"] }
```

Write a `linux/tests/credential_smoke.rs` integration test guarded behind a feature
flag `linux-smoke` that round-trips a token. Document in `linux/README.md` that the
target user session needs a running `gnome-keyring-daemon` or KDE wallet.

Acceptance: `cargo test -p jellify-desktop --features linux-smoke` passes under a
Linux session with a running secret service.

### Issue 9: Storage paths match XDG spec via `glib::user_data_dir()`
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** S

When constructing `CoreConfig` on Linux, set `data_dir =
glib::user_data_dir().join("jellify-desktop")` — this is already where the fallback
in `core/src/storage.rs::default_data_dir` lands under Flatpak
(`$XDG_DATA_HOME/jellify-desktop/`), but the app should pass the canonical glib path
explicitly so it works correctly inside Flatpak sandboxing (where `HOME` is remapped).

Artwork cache: introduce `ArtworkCache` module in `linux/src/artwork.rs` writing to
`glib::user_cache_dir().join("jellify-desktop/artwork/")` keyed by
`item_id + tag + size`. Use `reqwest` from core via `stream_url`-style helpers, or
`gdk-pixbuf` async loaders backed by `gio::File`.

Acceptance: running under Flatpak stores DB and artwork under
`~/.var/app/org.jellify.Desktop/data/` and `~/.var/app/org.jellify.Desktop/cache/`.

### Issue 10: GitHub Actions CI — Linux build + lint
**Labels:** `area:linux`, `kind:chore`, `priority:p1`
**Effort:** S

Add `.github/workflows/linux.yml`:
- `ubuntu-latest` runner
- Install apt deps: `libgtk-4-dev libadwaita-1-dev libgstreamer1.0-dev
  libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
  gstreamer1.0-libav libsoup-3.0-dev libsecret-1-dev`
- `cargo fmt --check`, `cargo clippy -p jellify-desktop -- -D warnings`
- `cargo build -p jellify-desktop --release`
- `cargo test -p jellify_core`

Acceptance: workflow runs green on PRs modifying `linux/` or `core/`.

---

## L-M2 — Core screens MVP (login → play via GStreamer)

### Issue 11: Login screen (`LoginPage` widget) with server probe + auth flow
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

`src/screens/login.rs` — composite template of:
- `AdwStatusPage` with logo + tagline
- `AdwEntryRow` for server URL, `AdwPasswordEntryRow` (username and password)
- `AdwSpinnerRow` for loading state
- Primary `gtk::Button` "Sign in"

Flow:
1. On URL blur → `core.probe_server` via worker → show server name or error toast
   (`AdwToast`).
2. On submit → `core.login` → on success fire an `app::SessionStarted` signal on the
   window, which swaps navigation view root to `MainShell`.

Errors surface via `adw::ToastOverlay`. Respect `keyring` restore: on page load, try
`CredentialStore::load_token` for `(last_server_id, last_username)` and auto-log-in
if found.

Acceptance: valid credentials reach the main shell; invalid show a toast; the login
page matches the macOS `LoginView.swift` visually (same Figma).

### Issue 12: Main shell — `AdwNavigationView` + sidebar via `AdwNavigationSplitView`
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

Use `AdwNavigationSplitView` (GNOME 45+) rather than the deprecated `AdwLeaflet` —
responsive two-pane automatically collapses to bottom-sheet / swipe nav on narrow
windows.

Sidebar content:
- `gtk::ListView` rows: Home, Library (Albums/Artists/Playlists expandable), Search,
  Now Playing.
- Sidebar row selection activates a navigation page in the content side via
  `AdwNavigationView::push`.

Header bar holds the sidebar toggle (auto-managed), window title, and the global
search entry when on compact screens.

Bottom of content side: persistent mini-player strip (`AdwBin` wrapping a custom
`MiniPlayer` widget — see Issue 21).

Acceptance: resizing the window below 600px collapses the sidebar to a bottom sheet
per GNOME HIG.

### Issue 13: Library (Albums + Artists) screen — `gtk::GridView`
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

`src/screens/library.rs`:
- `AdwViewStack` + `AdwViewSwitcherTitle` for Albums / Artists / Playlists tabs
- Each tab hosts a `gtk::ScrolledWindow` containing a `gtk::GridView`
- GridView backed by `gio::ListStore<AlbumObject>` with
  `SignalListItemFactory::setup`/`bind`
- Each cell: `AlbumCard` widget with cover art (`gtk::Picture` bound via custom
  property), title, artist subtitle
- Infinite scroll: connect `gtk::Adjustment::value-changed` on the scrolled window;
  when near bottom, fetch next page via `core.list_albums(offset, 50)` and append

Cover art comes from `ArtworkCache` — async `gdk::Texture::from_file` after download.

Acceptance: 1000-album library scrolls smoothly at 60fps on a 2020-era laptop
(Intel iGPU). Memory stays bounded via `gio::ListStore` view recycling.

### Issue 14: Font bundling + Pango registration
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** S

Bundle `Figtree-{Regular,Italic,Medium,SemiBold,Bold,ExtraBold,Black,Light}.otf`
(copied from `macos/Sources/Jellify/Resources/` — same source as macOS) into the
gresource under `/org/jellify/Desktop/fonts/`.

At app `startup`, extract them to a temp dir (or `$XDG_RUNTIME_DIR/jellify/fonts/`)
and call `pango::FontMap::add_font_file` (via fontconfig `FcConfigAppFontAddFile` if
the Pango API is not yet wrapped in gtk4-rs). Inside Flatpak, simpler: drop the .otf
files into `/app/share/fonts/jellify/` in the manifest and fontconfig picks them up
at runtime automatically.

Acceptance: `Pango::Context` resolves "Figtree" without falling back. Dark-mode login
screen matches the macOS version.

### Issue 15: GTK CSS theming + five presets
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** M

Author `linux/resources/css/`:
- `_base.css` — font stack, spacing scale, common widget classes
- `purple.css`, `dark.css`, `oled.css`, `light.css`, `teal.css` — preset overrides
  mirroring Jellify's Tamagui config + macOS `Theme.swift`

Approach: use libadwaita's accent-color API (`AdwStyleManager::set_accent_color`)
for hue-matched accents, supplemented with `gtk::CssProvider::load_from_resource` for
surfaces/backgrounds. The preset key in `gio::Settings::theme-preset` drives which
CSS provider is attached.

Honor system color scheme: on `AdwStyleManager::notify::system-supports-color-schemes`
and `dark` property changes, swap to `*-dark.css` variants when the user chose
"follow system" (Issue 7).

Acceptance: changing theme preset in Preferences hot-swaps the CSS without restart.
`org.freedesktop.appearance.color-scheme` XDG portal preference is respected.

### Issue 16: GStreamer `playbin3` audio engine
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** L

`src/audio.rs` — `AudioEngine` struct owning a `gstreamer::ElementFactory::make("playbin3")`
pipeline. Signatures mirror macOS `AudioEngine.swift`: `play(track)`, `pause()`,
`resume()`, `stop()`, `seek(seconds)`, `set_volume(f32)`, `on_track_ended: FnMut()`.

Core integration:
- `core.stream_url(track.id)` → `uri` property
- `core.auth_header()` value → attached via `source-setup` signal: when source is a
  `souphttpsrc`, set `extra-headers` to a `gst::Structure` containing `Authorization`.
  (Rust call: `source.set_property("extra-headers", &headers_struct)`.)

Bus handling: add a `gst::Bus` watch on the GLib main context to translate messages
into core state:
- `MessageView::StateChanged` → `core.mark_state(Playing/Paused/...)`
- `MessageView::Eos` → `core.mark_state(Ended)`, fire `on_track_ended`
- `MessageView::Error` → surface toast, stop pipeline
- `MessageView::Buffering` (percent < 100) → `core.mark_state(Loading)`

Position polling: `glib::timeout_add_seconds_local(1, ...)` while `Playing` →
`pipeline.query_position(gst::ClockTime)` → `core.mark_position(seconds)`.

Acceptance: selecting a track plays audible output. Seek, pause/resume, volume all
round-trip through `core.status()`.

### Issue 17: Gapless playback via `about-to-finish`
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** S

Connect `playbin3`'s `about-to-finish` signal. On fire:
1. Call `core.skip_next()` on the main loop (it's quick, no worker needed).
2. If `Some(next_track)` → `core.stream_url(next_track.id)` → set `uri` property
   *synchronously from the signal handler*. This is the critical detail that makes
   playbin gapless.
3. After the next track starts, `core.mark_track_started(next_track)` from the
   `StateChanged` bus handler so play history records correctly.

Gate behind the `use-gapless` settings key (default on).

Acceptance: playing a track list with contiguous audio (gapless album) reveals no
audible gap between tracks. `playerctl metadata` updates correctly at the boundary.

### Issue 18: Album Detail + track list (`gtk::ColumnView`)
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

`src/screens/album_detail.rs`:
- Hero: large cover via `gtk::Picture`, title, artist button (navigates to artist
  detail — Issue 19), year, duration summary, play + shuffle buttons
- Body: `gtk::ColumnView` with columns `#`, `Title`, `Duration`, `⋯` (context menu).
  Selection triggers `core.set_queue(album_tracks, index)` → audio engine plays.
- Header bar shows a back button auto-managed by `AdwNavigationView`.

Acceptance: tapping track #3 on an album jumps to track 3 and queues the rest of the
album. Tapping artist name navigates to artist detail.

### Issue 19: Artist Detail, Search, Playlist, Home screens
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** L

Parity with the macOS screens:
- **Home** — recently-added, recently-played `GridView` rails (horizontal scroll via
  `gtk::ScrolledWindow` with horizontal policy + snap). Reuse `AlbumCard`.
- **Artist Detail** — hero, "top tracks" `ColumnView`, albums grid.
- **Search** — `gtk::SearchEntry` in header bar debounced via
  `glib::timeout_add_local(300ms, ...)`, three result sections (artists, albums,
  tracks). Uses `core.search(query)`.
- **Playlist** — same shape as album detail but against `core.list_playlists` +
  `core.playlist_tracks` (will need a core addition if not present; check
  `core/src/client.rs` `playlists` / `playlist_tracks`).

Acceptance: all five screens render real data end-to-end with the logged-in test
server.

### Issue 20: Queue sidebar with drag-and-drop reorder
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** M

Toggle-able right-side queue pane via `AdwOverlaySplitView`. Content: `gtk::ListView`
of `TrackObject` sourced from a main-loop-synced mirror of `core.player.queue`
(core doesn't expose queue as a stream today — add a
`core.subscribe_player_status()` channel in a follow-up, or poll every 250ms for M2).

Drag and drop via `gtk::DragSource` + `gtk::DropTarget` accepting `TrackObject`.
On drop, compute new indices and call a new `core.move_queue_item(from, to)` method
(add to core if missing).

Acceptance: user can reorder up-next tracks; new order is reflected in playback
sequencing.

---

## L-M3 — Polish + MPRIS2 + accessibility

### Issue 21: Mini-player strip + full-screen "Now Playing"
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** M

Mini-player: fixed-height `gtk::Box` at bottom of content side — cover (48px),
title + artist (two `gtk::Label`), scrubber (`gtk::Scale` bound to core position),
previous/play-pause/next buttons, volume popover.

Clicking the mini-player expands to a full-screen "Now Playing" page pushed onto the
`AdwNavigationView` — large cover, big type, lyrics placeholder (future), queue
toggle.

Binding strategy: a `PlayerController` singleton owned by `AppModel` polls
`core.status()` every 250ms via `glib::timeout_add_local` and emits a single
`notify::status` signal; the mini-player and NPV both bind to it.

Acceptance: position scrubber updates smoothly; pressing space toggles play/pause
regardless of which screen has focus.

### Issue 22: MPRIS2 D-Bus service via `mpris-server` crate
**Labels:** `area:linux`, `kind:feat`, `priority:p0`
**Effort:** L

Add `mpris-server = "0.8"` (thin `zbus` wrapper exposing `Player` + `RootInterface`
trait objects). On app startup, spawn a `zbus` task registering
`org.mpris.MediaPlayer2.jellify`.

Trait impls:
- `PlaybackStatus` → maps `PlaybackState::Playing → "Playing"` etc.
- `Metadata` → `{ mpris:trackid: "/org/mpris/MediaPlayer2/Track/<id>", xesam:title,
  xesam:artist: [...], xesam:album, mpris:length (microseconds),
  mpris:artUrl: "file://$cache/artwork/<id>_600.jpg" }`
- `Volume`, `Position`, `Rate`, `CanPlay/CanPause/CanSeek/CanGoNext/CanGoPrevious`
- Methods: `PlayPause`, `Play`, `Pause`, `Next`, `Previous`, `Stop`, `Seek`,
  `SetPosition`, `OpenUri` (no-op initially)

Emit `PropertiesChanged` when `PlayerController` signals a change.

On Flathub/Flatpak: the `--socket=session-bus` finish-arg covers the D-Bus access —
already standard.

Acceptance: `playerctl -p jellify metadata` returns current track; `playerctl -p
jellify play-pause` toggles playback. GNOME Shell Quick Settings media widget shows
Jellify with cover art.

### Issue 23: Media key bindings verified on GNOME + KDE
**Labels:** `area:linux`, `kind:chore`, `priority:p1`
**Effort:** S

No app-side code needed beyond MPRIS2. Document in `linux/README.md` that media keys
are handled by the DE's MPRIS2 consumer (gnome-settings-daemon's media-keys plugin,
or KDE Plasma's KGlobalAccel + kded mpris support).

Add a manual QA checklist to the repo (`linux/docs/qa-checklist.md`) covering
play/pause, next/prev, stop on both GNOME 46+ and KDE Plasma 6.

Acceptance: checklist added; manual pass on one of each DE documented in a linked QA
run.

### Issue 24: `Gio::Notification` for track-changed + errors
**Labels:** `area:linux`, `kind:feat`, `priority:p2`
**Effort:** S

On track-change (user setting gated; default off when window focused, on when
backgrounded — query `gtk::Window::is_active`):
- `Gio::Notification::new("Now playing")` with body `"<track> — <artist>"`, hint
  image from artwork cache, `default-action` "app.raise"
- Error notifications on stream failures.

Acceptance: minimizing the window and skipping tracks shows a notification with
cover art.

### Issue 25: Keyboard shortcuts via `gtk::ShortcutController`
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** S

Register per-window shortcuts:
- `Space` — play/pause (guarded so it doesn't swallow when an entry has focus)
- `Ctrl+Right` / `Ctrl+Left` — next/previous
- `Ctrl+F` — focus search entry
- `Ctrl+,` — preferences
- `Ctrl+Q` — quit
- `F10` — primary menu
- `Ctrl+?` — shortcuts overlay (`gtk::ShortcutsWindow`)

Implement via `gtk::ShortcutController` attached at window scope + corresponding
GActions (so MPRIS2 and shortcuts converge on the same handlers).

Acceptance: shortcuts overlay opens with `Ctrl+?` listing all keys, matching GNOME
HIG.

### Issue 26: Accessibility — `gtk::Accessible` on custom widgets
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** M

For each custom widget (`AlbumCard`, `MiniPlayer`, `LoginPage`):
- Set `accessible-role` (`Button`, `Group`, etc.) via `gtk::AccessibleRole`
- Populate `accessible-label`, `accessible-description` via
  `update_property(&[Property::Label(...)])`
- Ensure focus order is logical
- Verify screen reader announcements via Orca on GNOME

Automated sanity check: spin up `dbus-monitor --session` on the
`org.a11y.Bus` address and confirm AT-SPI tree emits expected roles on launch.

Acceptance: Orca correctly reads track names when navigating the album list;
buttons announce their purpose, not "button, no name".

### Issue 27: Preferences window via `AdwPreferencesWindow`
**Labels:** `area:linux`, `kind:feat`, `priority:p1`
**Effort:** S

`src/screens/preferences.rs` — `AdwPreferencesWindow` with pages:
- **General** — theme preset (`AdwComboRow`), follow system color scheme
  (`AdwSwitchRow`), gapless playback
- **Library** — jellyfin server URL (read-only display, with sign-out button),
  clear artwork cache button
- **About** — `AdwAboutWindow` separately, invoked from primary menu

Bindings: `gio::Settings::bind` for each row so values round-trip to dconf.

Acceptance: toggling gapless + theme preset immediately affects playback and UI.

### Issue 28: Icon set (symbolic + app icon)
**Labels:** `area:linux`, `kind:chore`, `priority:p1`
**Effort:** S

- Symbolic icons (UI glyphs): `linux/resources/icons/scalable/` — `.svg` files with
  `*-symbolic.svg` suffix so libadwaita auto-recolors. Reference via
  `gtk::Image::from_resource("/org/jellify/Desktop/icons/scalable/<name>.svg")`.
  Reuse GNOME icon-set for common ones (play, pause, skip) to feel native.
- App icon: scalable `.svg` + rasterized PNG at 16/24/32/48/64/128/256 sizes. Install
  to `share/icons/hicolor/<size>x<size>/apps/org.jellify.Desktop.png` +
  `share/icons/hicolor/scalable/apps/org.jellify.Desktop.svg`.

Acceptance: GNOME Activities overview shows the Jellify icon at crisp native size.

### Issue 29: Localization scaffolding (gettext + `.po`)
**Labels:** `area:linux`, `kind:chore`, `priority:p2`
**Effort:** M

Add `gettext-rs` crate, bind `textdomain("jellify-desktop")` + `bindtextdomain` to
`$prefix/share/locale`. Wrap user-facing strings via `gettext::gettext!` /
`gettext!` macro. Add `po/POTFILES.in` + `po/LINGUAS`. Configure `xgettext` extraction
via a `Makefile.am`-style script at `linux/po/update-pot.sh`.

Ship with `en_US.po` stub initially; open the door for Flathub translators.

Acceptance: running with `LANG=de_DE.UTF-8` after adding a `de.po` stub with one
translated string shows the translated text.

---

## L-M4 — Flatpak distribution + Flathub submission

### Issue 30: Flatpak manifest (`org.jellify.Desktop.yaml`)
**Labels:** `area:linux`, `kind:chore`, `priority:p0`
**Effort:** M

Author `linux/flatpak/org.jellify.Desktop.yaml`:
- `runtime: org.gnome.Platform` version `46`
- `sdk: org.gnome.Sdk` version `46`
- `sdk-extensions: [org.freedesktop.Sdk.Extension.rust-stable]`
- `finish-args`:
  - `--share=network` (Jellyfin streaming)
  - `--share=ipc`
  - `--socket=fallback-x11`, `--socket=wayland`
  - `--socket=pulseaudio` (GStreamer audio out)
  - `--socket=session-bus` (MPRIS2)
  - `--device=dri` (GL acceleration for `gdk4`)
  - `--talk-name=org.freedesktop.Notifications`
  - `--talk-name=org.freedesktop.secrets` (libsecret)
- `modules`:
  - `figtree-fonts` — builds from upstream .zip, drops .otf into `/app/share/fonts/`
  - `jellify-desktop` — `buildsystem: simple`; `build-commands` invoke
    `cargo --offline build --release -p jellify-desktop` (requires a
    `cargo-sources.json` generated by `flatpak-cargo-generator.py`)
  - Install binary to `/app/bin/`, desktop file, appdata, icons

Acceptance: `flatpak-builder --user --install --force-clean build-dir
linux/flatpak/org.jellify.Desktop.yaml` builds locally; `flatpak run
org.jellify.Desktop` launches the app.

### Issue 31: Cargo-sources generator for Flatpak offline build
**Labels:** `area:linux`, `kind:chore`, `priority:p0`
**Effort:** S

Integrate `flatpak-cargo-generator.py` (from `flatpak-builder-tools`) into a
repo script at `linux/flatpak/gen-sources.sh`. Invoked with `Cargo.lock` path,
produces `cargo-sources.json` referenced from the manifest's `jellify-desktop`
module as `- cargo-sources.json`.

Document regeneration cadence in `CONTRIBUTING.md` ("run after every dependency
change").

Acceptance: `flatpak-builder` with `--disable-cache` builds fully offline after
running the generator.

### Issue 32: Desktop entry file (`.desktop`)
**Labels:** `area:linux`, `kind:chore`, `priority:p0`
**Effort:** S

`linux/data/org.jellify.Desktop.desktop`:
```
[Desktop Entry]
Name=Jellify
Comment=Music player for Jellyfin
Exec=jellify-desktop %U
Icon=org.jellify.Desktop
Type=Application
Categories=AudioVideo;Audio;Player;GNOME;GTK;
StartupNotify=true
Keywords=music;audio;jellyfin;player;
MimeType=x-scheme-handler/jellify;
X-GNOME-UsesNotifications=true
```

Validated via `desktop-file-validate`. Installed to `/app/share/applications/`.

Acceptance: `desktop-file-validate` passes with no errors; the entry appears in
GNOME Activities and KRunner.

### Issue 33: AppStream metainfo (`.metainfo.xml`)
**Labels:** `area:linux`, `kind:chore`, `priority:p0`
**Effort:** M

`linux/data/org.jellify.Desktop.metainfo.xml` — required for Flathub:
- `<id>org.jellify.Desktop</id>`
- `<metadata_license>CC0-1.0</metadata_license>`, `<project_license>GPL-3.0-only</project_license>`
- `<name>`, `<summary>`, long `<description>` with feature bullets
- `<screenshots>` — at least 3 hosted 1920×1080 PNGs (library, album detail, now
  playing) referenced by URL
- `<releases>` — per-version `<release version="x.y.z" date="YYYY-MM-DD">` + notes
- `<url type="homepage">`, `type="bugtracker"`, `type="vcs-browser"`,
  `type="help"`, `type="translate"`
- `<content_rating type="oars-1.1" />` (all "none" — no user-generated content)
- `<categories>AudioVideo;Audio;Player;</categories>`
- `<branding><color type="primary" scheme_preference="dark">#0C0622</color></branding>`

Validated via `appstreamcli validate`. Installed to
`/app/share/metainfo/org.jellify.Desktop.metainfo.xml`.

Acceptance: `appstreamcli validate` passes strictly (required for Flathub);
screenshots render in GNOME Software preview.

### Issue 34: Flathub submission (Flathub PR)
**Labels:** `area:linux`, `kind:chore`, `priority:p1`
**Effort:** M

Follow [Flathub submission process](https://docs.flathub.org/docs/for-app-authors/submission):
1. Validate manifest locally with `flatpak run
   org.flathub.flatpak-external-data-checker` (future use for update automation).
2. Run through the Flathub checklist: app-id reverse DNS, GPL-compat license,
   AppStream summary constraints (≤ 35 chars for summary, ≤ 350 for description
   excerpt shown in software center tiles).
3. Fork `flathub/flathub`, create a PR on the `new-pr` branch adding
   `org.jellify.Desktop.yaml` + support files to a new directory.
4. Respond to reviewer comments (typically: finish-args too permissive, AppStream
   formatting, OARS rating).
5. Once merged, the app appears on Flathub within ~6 hours and builds appear on
   `flathub-beta` for a soak period.

Acceptance: PR merged, `flatpak install flathub org.jellify.Desktop` works.

### Issue 35: Auto-update CI — tag → Flathub PR
**Labels:** `area:linux`, `kind:chore`, `priority:p2`
**Effort:** S

Add a repo GH Action triggered on `v*` tag:
1. Regenerate `cargo-sources.json` against the tagged `Cargo.lock`.
2. Commit the manifest update (version + commit SHA) to a fork of the Flathub repo.
3. Open a PR against the app's Flathub directory with changelog extracted from the
   release notes.

Alternatively, rely on Flathub's `flatpak-external-data-checker` bot; document which
route we choose.

Acceptance: tagging `v0.2.0` produces a Flathub PR within 10 minutes with the
updated version.

### Issue 36: KDE Plasma + adw-plasma smoke test
**Labels:** `area:linux`, `kind:chore`, `priority:p2`
**Effort:** S

Manual QA on a Plasma 6 live USB / VM:
- libadwaita under Plasma respects Plasma theme via `adw-plasma` package; verify
  accent color follows Plasma's system accent.
- MPRIS2 control from Plasma system tray media widget.
- Media keys via KGlobalAccel.

Document findings in `linux/docs/qa-checklist.md`. File follow-up issues for any
Plasma-specific regressions.

Acceptance: checklist pass recorded in a PR description or issue comment linked
from the issue.
