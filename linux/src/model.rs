//! App-wide model — owns the shared [`jellify_core::JellifyCore`] and the
//! `gio::ListStore`s that back `gtk::ListView` / `gtk::GridView` widgets.
//!
//! Threading model:
//! - `AppModel` lives on the GTK main loop (held behind `Rc<_>` on the
//!   window). Its methods are `&self`-only.
//! - `JellifyCore` is `Send + Sync` and internally runs blocking Jellyfin
//!   HTTP calls on its own Tokio runtime via `block_on`. Screens that need
//!   to invoke a core method dispatch it to a worker via `gio::spawn_blocking`
//!   (to be added in a follow-up batch) and post results back to the main
//!   loop through `async-channel` + `glib::MainContext::spawn_local`.
//! - The wrapper GObjects below (`AlbumObject`, `ArtistObject`,
//!   `TrackObject`) are main-loop-only and carry only `Clone`-friendly data
//!   snapshots — never a `JellifyCore` handle — so they can be safely held
//!   by `gio::ListStore` and bound to `SignalListItemFactory` rows.
//!
//! No network calls are issued in this bootstrap batch: `AppModel::new`
//! just constructs the core and empty list stores. Screens added in later
//! batches will populate the stores on sign-in.

use std::sync::Arc;

use anyhow::{Context, Result};
use gio::prelude::*;
use glib::subclass::prelude::*;
use jellify_core::{Album, Artist, CoreConfig, JellifyCore, Track};

/// Device name reported to the Jellyfin server during authentication.
/// Shows up under "Dashboard → Sessions" on the server; matches the macOS
/// client's pattern so admins can visually distinguish Linux desktops.
const DEVICE_NAME: &str = "Jellify Desktop (Linux)";

/// Top-level app state. One instance per window, held by the window behind
/// `Rc<AppModel>`. Children reach it via `window.model()`.
pub struct AppModel {
    /// Shared Rust core — HTTP client, SQLite cache, auth, queue. Held as
    /// `Arc` because the same handle is shared with any worker thread that
    /// issues blocking core calls on behalf of the UI.
    pub core: Arc<JellifyCore>,

    /// Backing store for the Library → Albums grid. Populated by the
    /// library screen once a session is active.
    pub albums: gio::ListStore,
    /// Backing store for the Library → Artists grid.
    pub artists: gio::ListStore,
    /// Backing store for the Now Playing queue sidebar.
    pub queue: gio::ListStore,
}

impl std::fmt::Debug for AppModel {
    // `JellifyCore` intentionally does not implement `Debug` (it owns a
    // Tokio runtime and locked HTTP client state). Derive a minimal
    // manual impl so containers holding `AppModel` — notably the window's
    // `OnceCell<Rc<AppModel>>` inside the `CompositeTemplate`-derived
    // imp struct — can still derive `Debug` themselves.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppModel")
            .field("albums_len", &self.albums.n_items())
            .field("artists_len", &self.artists.n_items())
            .field("queue_len", &self.queue.n_items())
            .finish_non_exhaustive()
    }
}

impl AppModel {
    /// Construct a fresh `AppModel`, initializing the core against the
    /// default XDG data directory (`$XDG_DATA_HOME/jellify-desktop/`, by
    /// convention via `core::storage::default_data_dir`). Follow-up
    /// batches may switch to an explicit `glib::user_data_dir()` path so
    /// the sandboxed Flatpak case stays deterministic.
    pub fn new() -> Result<Self> {
        let core = JellifyCore::new(CoreConfig {
            // Empty string = use core's default (`dirs::data_dir`), which
            // today resolves to `$XDG_DATA_HOME/jellify-desktop/` on Linux.
            data_dir: String::new(),
            device_name: DEVICE_NAME.to_string(),
        })
        .map_err(|e| anyhow::anyhow!("core init: {e}"))
        .context("JellifyCore::new failed")?;

        Ok(Self {
            core,
            albums: gio::ListStore::new::<AlbumObject>(),
            artists: gio::ListStore::new::<ArtistObject>(),
            queue: gio::ListStore::new::<TrackObject>(),
        })
    }
}

// ---------------------------------------------------------------------------
// Wrapper GObjects
//
// `gtk::ListView`, `gtk::GridView`, and the `SignalListItemFactory` machinery
// require each row to be a GObject so they can be bound via properties. The
// wrappers below expose the fields a row template typically reads — enough
// for the bootstrap batch; follow-up batches will add computed properties
// (e.g. formatted duration, cached artwork URIs) as screens need them.
//
// Storage layout: each wrapper keeps the core record in a private field
// (accessed via property getters) rather than re-exposing every field
// individually, which minimizes boilerplate while still giving GTK the
// property access it needs for bindings.
// ---------------------------------------------------------------------------

// ---------- AlbumObject ----------

mod album_imp {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::AlbumObject)]
    pub struct AlbumObject {
        #[property(get = Self::id)]
        pub _id: std::marker::PhantomData<String>,
        #[property(get = Self::name)]
        pub _name: std::marker::PhantomData<String>,
        #[property(get = Self::artist_name)]
        pub _artist_name: std::marker::PhantomData<String>,
        #[property(get = Self::year)]
        pub _year: std::marker::PhantomData<i32>,
        #[property(get = Self::track_count)]
        pub _track_count: std::marker::PhantomData<u32>,

        pub inner: RefCell<Option<Album>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for AlbumObject {
        const NAME: &'static str = "JellifyAlbumObject";
        type Type = super::AlbumObject;
    }

    #[glib::derived_properties]
    impl ObjectImpl for AlbumObject {}

    impl AlbumObject {
        fn with_inner<T: Default>(&self, f: impl FnOnce(&Album) -> T) -> T {
            self.inner.borrow().as_ref().map(f).unwrap_or_default()
        }

        fn id(&self) -> String {
            self.with_inner(|a| a.id.clone())
        }
        fn name(&self) -> String {
            self.with_inner(|a| a.name.clone())
        }
        fn artist_name(&self) -> String {
            self.with_inner(|a| a.artist_name.clone())
        }
        /// Returns `0` when the album has no year set — callers hide the
        /// label in that case. UniFFI models expose `Option<i32>` but
        /// `glib::Properties` doesn't derive optional scalars cleanly, so
        /// we flatten.
        fn year(&self) -> i32 {
            self.with_inner(|a| a.year.unwrap_or(0))
        }
        fn track_count(&self) -> u32 {
            self.with_inner(|a| a.track_count)
        }
    }
}

glib::wrapper! {
    /// GObject wrapper around a [`jellify_core::Album`]. Backs rows in the
    /// Library → Albums grid.
    pub struct AlbumObject(ObjectSubclass<album_imp::AlbumObject>);
}

impl AlbumObject {
    pub fn new(album: Album) -> Self {
        let obj: Self = glib::Object::new();
        obj.imp().inner.replace(Some(album));
        obj
    }

    /// Clone of the underlying core record. Used by detail screens that
    /// need the full struct (genres, runtime, etc.) rather than the
    /// GObject-exposed subset.
    pub fn snapshot(&self) -> Option<Album> {
        self.imp().inner.borrow().clone()
    }
}

// ---------- ArtistObject ----------

mod artist_imp {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::ArtistObject)]
    pub struct ArtistObject {
        #[property(get = Self::id)]
        pub _id: std::marker::PhantomData<String>,
        #[property(get = Self::name)]
        pub _name: std::marker::PhantomData<String>,
        #[property(get = Self::album_count)]
        pub _album_count: std::marker::PhantomData<u32>,
        #[property(get = Self::song_count)]
        pub _song_count: std::marker::PhantomData<u32>,

        pub inner: RefCell<Option<Artist>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ArtistObject {
        const NAME: &'static str = "JellifyArtistObject";
        type Type = super::ArtistObject;
    }

    #[glib::derived_properties]
    impl ObjectImpl for ArtistObject {}

    impl ArtistObject {
        fn with_inner<T: Default>(&self, f: impl FnOnce(&Artist) -> T) -> T {
            self.inner.borrow().as_ref().map(f).unwrap_or_default()
        }

        fn id(&self) -> String {
            self.with_inner(|a| a.id.clone())
        }
        fn name(&self) -> String {
            self.with_inner(|a| a.name.clone())
        }
        fn album_count(&self) -> u32 {
            self.with_inner(|a| a.album_count)
        }
        fn song_count(&self) -> u32 {
            self.with_inner(|a| a.song_count)
        }
    }
}

glib::wrapper! {
    /// GObject wrapper around a [`jellify_core::Artist`]. Backs rows in
    /// the Library → Artists grid.
    pub struct ArtistObject(ObjectSubclass<artist_imp::ArtistObject>);
}

impl ArtistObject {
    pub fn new(artist: Artist) -> Self {
        let obj: Self = glib::Object::new();
        obj.imp().inner.replace(Some(artist));
        obj
    }

    pub fn snapshot(&self) -> Option<Artist> {
        self.imp().inner.borrow().clone()
    }
}

// ---------- TrackObject ----------

mod track_imp {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::TrackObject)]
    pub struct TrackObject {
        #[property(get = Self::id)]
        pub _id: std::marker::PhantomData<String>,
        #[property(get = Self::name)]
        pub _name: std::marker::PhantomData<String>,
        #[property(get = Self::artist_name)]
        pub _artist_name: std::marker::PhantomData<String>,
        #[property(get = Self::album_name)]
        pub _album_name: std::marker::PhantomData<String>,
        #[property(get = Self::runtime_seconds)]
        pub _runtime_seconds: std::marker::PhantomData<f64>,
        #[property(get = Self::is_favorite)]
        pub _is_favorite: std::marker::PhantomData<bool>,

        pub inner: RefCell<Option<Track>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for TrackObject {
        const NAME: &'static str = "JellifyTrackObject";
        type Type = super::TrackObject;
    }

    #[glib::derived_properties]
    impl ObjectImpl for TrackObject {}

    impl TrackObject {
        fn with_inner<T: Default>(&self, f: impl FnOnce(&Track) -> T) -> T {
            self.inner.borrow().as_ref().map(f).unwrap_or_default()
        }

        fn id(&self) -> String {
            self.with_inner(|t| t.id.clone())
        }
        fn name(&self) -> String {
            self.with_inner(|t| t.name.clone())
        }
        fn artist_name(&self) -> String {
            self.with_inner(|t| t.artist_name.clone())
        }
        fn album_name(&self) -> String {
            self.with_inner(|t| t.album_name.clone().unwrap_or_default())
        }
        fn runtime_seconds(&self) -> f64 {
            self.with_inner(|t| t.duration_seconds())
        }
        fn is_favorite(&self) -> bool {
            self.with_inner(|t| t.is_favorite)
        }
    }
}

glib::wrapper! {
    /// GObject wrapper around a [`jellify_core::Track`]. Backs rows in
    /// the queue sidebar, album track lists, and playlist track lists.
    pub struct TrackObject(ObjectSubclass<track_imp::TrackObject>);
}

impl TrackObject {
    pub fn new(track: Track) -> Self {
        let obj: Self = glib::Object::new();
        obj.imp().inner.replace(Some(track));
        obj
    }

    pub fn snapshot(&self) -> Option<Track> {
        self.imp().inner.borrow().clone()
    }
}
