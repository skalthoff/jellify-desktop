//! Jellify core — shared Rust library for the desktop apps.
//!
//! The public surface is the [`JellifyCore`] type, which owns the Jellyfin
//! HTTP client, the local database, and queue/player bookkeeping. Platform
//! UIs consume this either via UniFFI bindings (Swift/C#) or directly (GTK /
//! Rust).
//!
//! Audio output is NOT in the core — it lives on the platform side
//! (AVFoundation on macOS, MediaPlayer on Windows, GStreamer on Linux).
//! The core exposes authenticated stream URLs; the platform decides how to
//! play them and calls back with status updates.

pub mod client;
pub mod error;
pub mod models;
pub mod player;
pub mod storage;

pub use error::{JellifyError, Result};
pub use models::*;
pub use player::{PlaybackState, Player, PlayerStatus};

use crate::client::{JellyfinClient, PublicSystemInfo};
use crate::storage::{CredentialStore, Database};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::Arc;
use uuid::Uuid;

uniffi::setup_scaffolding!();

/// The main handle a UI holds.
#[derive(uniffi::Object)]
pub struct JellifyCore {
    inner: Arc<Mutex<Inner>>,
    player: Arc<Player>,
    runtime: tokio::runtime::Runtime,
}

struct Inner {
    client: Option<JellyfinClient>,
    db: Database,
    device_id: String,
    device_name: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreConfig {
    pub data_dir: String,
    pub device_name: String,
}

#[uniffi::export]
impl JellifyCore {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> std::result::Result<Arc<Self>, JellifyError> {
        let data_dir = if config.data_dir.is_empty() {
            storage::default_data_dir()
        } else {
            PathBuf::from(&config.data_dir)
        };
        let db_path = data_dir.join("jellify.db");
        let db = Database::open(&db_path)?;

        let device_id = match db.get_setting("device_id")? {
            Some(id) => id,
            None => {
                let id = Uuid::new_v4().to_string();
                db.set_setting("device_id", &id)?;
                id
            }
        };

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| JellifyError::Other(format!("tokio runtime: {e}")))?;

        Ok(Arc::new(Self {
            inner: Arc::new(Mutex::new(Inner {
                client: None,
                db,
                device_id,
                device_name: config.device_name,
            })),
            player: Arc::new(Player::new()),
            runtime,
        }))
    }

    pub fn device_id(&self) -> String {
        self.inner.lock().device_id.clone()
    }

    pub fn probe_server(&self, url: String) -> std::result::Result<Server, JellifyError> {
        let (device_id, device_name) = {
            let inner = self.inner.lock();
            (inner.device_id.clone(), inner.device_name.clone())
        };
        let client = JellyfinClient::new(&url, device_id, device_name)?;
        let info: PublicSystemInfo = self.runtime.block_on(client.public_info())?;
        Ok(Server {
            url: client.base_url().to_string(),
            name: info.server_name.unwrap_or_else(|| "Jellyfin".to_string()),
            version: info.version,
            id: info.id,
        })
    }

    pub fn login(
        &self,
        url: String,
        username: String,
        password: String,
    ) -> std::result::Result<models::Session, JellifyError> {
        let (device_id, device_name) = {
            let inner = self.inner.lock();
            (inner.device_id.clone(), inner.device_name.clone())
        };
        let mut client = JellyfinClient::new(&url, device_id, device_name)?;
        let session = self
            .runtime
            .block_on(client.authenticate_by_name(&username, &password))?;

        if let Some(server_id) = &session.server.id {
            let _ =
                CredentialStore::save_token(server_id, &session.user.name, &session.access_token);
        }
        {
            let inner = self.inner.lock();
            inner
                .db
                .set_setting("last_server_url", &session.server.url)?;
            inner.db.set_setting("last_username", &session.user.name)?;
            if let Some(server_id) = &session.server.id {
                inner.db.set_setting("last_server_id", server_id)?;
            }
        }
        self.inner.lock().client = Some(client);
        Ok(session)
    }

    pub fn logout(&self) -> std::result::Result<(), JellifyError> {
        {
            let inner = self.inner.lock();
            if let (Ok(Some(server_id)), Ok(Some(username))) = (
                inner.db.get_setting("last_server_id"),
                inner.db.get_setting("last_username"),
            ) {
                let _ = CredentialStore::delete_token(&server_id, &username);
            }
        }
        self.inner.lock().client = None;
        self.player.clear();
        Ok(())
    }

    // ---------- Library ----------

    pub fn list_albums(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<Vec<Album>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.albums(Paging::new(offset, limit))))
    }

    pub fn list_artists(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<Vec<Artist>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.artists(Paging::new(offset, limit))))
    }

    pub fn album_tracks(&self, album_id: String) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.album_tracks(&album_id)))
    }

    /// Recently added albums for the Home "Recently Added" row.
    ///
    /// Server-side filtering respects the user's parental controls; the
    /// response is grouped by album so loose tracks never appear. Callers
    /// resolve `library_id` (the music collection view id) once at sign-in.
    pub fn latest_albums(
        &self,
        library_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Album>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.latest_albums(&library_id, limit)))
    }

    /// Recently played tracks for the current user, sorted by server-side
    /// `DatePlayed` descending. Pass `music_library_id` to scope to a single
    /// `MusicLibrary` CollectionFolder.
    pub fn recently_played(
        &self,
        music_library_id: Option<String>,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| {
            self.runtime.block_on(
                c.recently_played(music_library_id.as_deref(), Paging::new(offset, limit)),
            )
        })
    }

    pub fn search(&self, query: String) -> std::result::Result<SearchResults, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.search(&query)))
    }

    /// Mark an item (track, album, artist, playlist) as a favorite for the
    /// current user. Errors with [`JellifyError::NotAuthenticated`] if no
    /// session is active.
    pub fn set_favorite(&self, item_id: String) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.set_favorite(&item_id)))
    }

    /// Remove the favorite flag from an item for the current user. Errors with
    /// [`JellifyError::NotAuthenticated`] if no session is active.
    pub fn unset_favorite(&self, item_id: String) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.unset_favorite(&item_id)))
    }

    /// Fetch a single item by id with a caller-selected `fields` projection
    /// (e.g. `["Overview", "Genres", "Tags", "People"]`). Returns the raw
    /// JSON object serialized as a string — callers decode whichever
    /// fields they asked for.
    pub fn fetch_item(
        &self,
        item_id: String,
        fields: Vec<String>,
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            let field_refs: Vec<&str> = fields.iter().map(String::as_str).collect();
            let value = self.runtime.block_on(c.fetch_item(&item_id, &field_refs))?;
            serde_json::to_string(&value).map_err(JellifyError::from)
        })
    }

    pub fn image_url(
        &self,
        item_id: String,
        tag: Option<String>,
        max_width: u32,
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            Ok(c.image_url(&item_id, tag.as_deref(), max_width)?
                .to_string())
        })
    }

    /// Build an image URL for any [`ImageType`] (Primary, Backdrop, Thumb, Disc,
    /// Logo, Banner, Art, Box). `index` is required for keyed types like
    /// `Backdrop` (one URL per `BackdropImageTags` entry); pass `None` for the
    /// first/only image.
    pub fn image_url_of_type(
        &self,
        item_id: String,
        image_type: ImageType,
        index: Option<u32>,
        tag: Option<String>,
        max_width: Option<u32>,
        max_height: Option<u32>,
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            Ok(c.image_url_of_type(
                &item_id,
                image_type,
                index,
                tag.as_deref(),
                max_width,
                max_height,
            )?
            .to_string())
        })
    }

    // ---------- Playback ----------

    /// Returns the fully-authenticated stream URL for a track. The platform
    /// audio engine (AVPlayer etc.) fetches from this, attaching the
    /// `Authorization` header returned by [`auth_header`].
    pub fn stream_url(&self, track_id: String) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| Ok(c.stream_url(&track_id)?.to_string()))
    }

    /// The `Authorization` header value to attach to streaming requests.
    /// Cloudflare-fronted Jellyfin servers reject query-key-only auth.
    pub fn auth_header(&self) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| Ok(c.auth_header_value()))
    }

    /// Set the queue to a list of tracks and mark `tracks[start_index]` as
    /// the current track. Returns the track that should start playing now.
    pub fn set_queue(
        &self,
        tracks: Vec<Track>,
        start_index: u32,
    ) -> std::result::Result<Option<Track>, JellifyError> {
        if tracks.is_empty() {
            return Err(JellifyError::InvalidInput("empty queue".into()));
        }
        self.player.set_queue(tracks, start_index);
        Ok(self.player.current_in_queue())
    }

    pub fn mark_track_started(&self, track: Track) {
        self.player.set_current(track.clone());
        let now = chrono::Utc::now().timestamp();
        let _ = self.inner.lock().db.record_play(&track.id, now);
    }

    pub fn mark_state(&self, state: PlaybackState) {
        self.player.mark_state(state);
    }

    pub fn mark_position(&self, seconds: f64) {
        self.player.mark_position(seconds);
    }

    pub fn skip_next(&self) -> Option<Track> {
        self.player.skip_next()
    }

    pub fn skip_previous(&self) -> Option<Track> {
        self.player.skip_previous()
    }

    pub fn set_volume(&self, volume: f32) {
        self.player.set_volume(volume);
    }

    pub fn stop(&self) {
        self.player.clear();
    }

    pub fn status(&self) -> PlayerStatus {
        self.player.status()
    }
}

impl JellifyCore {
    fn with_client<T, F>(&self, f: F) -> std::result::Result<T, JellifyError>
    where
        F: FnOnce(&JellyfinClient) -> std::result::Result<T, JellifyError>,
    {
        let inner = self.inner.lock();
        let client = inner.client.as_ref().ok_or(JellifyError::NoSession)?;
        f(client)
    }
}

#[cfg(test)]
mod tests;
