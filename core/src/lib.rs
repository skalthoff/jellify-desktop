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
            inner.db.set_setting("last_user_id", &session.user.id)?;
        }
        self.inner.lock().client = Some(client);
        Ok(session)
    }

    /// Rehydrate the previous session from persisted state. Returns
    /// `Ok(Some(session))` when all of `last_server_url`, `last_username`,
    /// `last_server_id`, `last_user_id`, and the keyring token for that
    /// user/server pair are present; otherwise `Ok(None)` so the caller can
    /// fall back to the login screen.
    ///
    /// Best-effort hydration: `server.name` and `user.primary_image_tag` are
    /// left blank — the next library call will refresh them, and we do NOT
    /// block this call on network availability so users launching offline
    /// still see their cached library instantly.
    pub fn resume_session(&self) -> std::result::Result<Option<Session>, JellifyError> {
        let (device_id, device_name, server_url, username, server_id, user_id) = {
            let inner = self.inner.lock();
            let server_url = match inner.db.get_setting("last_server_url")? {
                Some(v) => v,
                None => return Ok(None),
            };
            let username = match inner.db.get_setting("last_username")? {
                Some(v) => v,
                None => return Ok(None),
            };
            let server_id = match inner.db.get_setting("last_server_id")? {
                Some(v) => v,
                None => return Ok(None),
            };
            let user_id = match inner.db.get_setting("last_user_id")? {
                Some(v) => v,
                None => return Ok(None),
            };
            (
                inner.device_id.clone(),
                inner.device_name.clone(),
                server_url,
                username,
                server_id,
                user_id,
            )
        };

        let token = match CredentialStore::load_token(&server_id, &username)? {
            Some(t) => t,
            None => return Ok(None),
        };

        let mut client = JellyfinClient::new(&server_url, device_id, device_name)?;
        client.set_session(token.clone(), user_id.clone());
        let resolved_url = client.base_url().to_string();
        self.inner.lock().client = Some(client);

        Ok(Some(Session {
            server: Server {
                url: resolved_url,
                name: String::new(),
                version: None,
                id: Some(server_id.clone()),
            },
            user: User {
                id: user_id,
                name: username,
                server_id: Some(server_id),
                primary_image_tag: None,
            },
            access_token: token,
            device_id: self.inner.lock().device_id.clone(),
        }))
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
            // Clearing persisted session pointers on an explicit logout so the
            // next launch doesn't try to auto-restore a session the user just
            // signed out of. `forget_token` is the softer variant that keeps
            // the server URL / username around for a quick re-auth.
            let _ = inner.db.delete_setting("last_server_url");
            let _ = inner.db.delete_setting("last_username");
            let _ = inner.db.delete_setting("last_server_id");
            let _ = inner.db.delete_setting("last_user_id");
        }
        self.inner.lock().client = None;
        self.player.clear();
        Ok(())
    }

    /// Drop the stored access token (and the ids that key into it) without
    /// wiping the remembered server URL / username. Used by the auth-expired
    /// sheet so the login form pre-fills on the re-auth attempt.
    pub fn forget_token(&self) -> std::result::Result<(), JellifyError> {
        {
            let inner = self.inner.lock();
            if let (Ok(Some(server_id)), Ok(Some(username))) = (
                inner.db.get_setting("last_server_id"),
                inner.db.get_setting("last_username"),
            ) {
                let _ = CredentialStore::delete_token(&server_id, &username);
            }
            let _ = inner.db.delete_setting("last_server_id");
            let _ = inner.db.delete_setting("last_user_id");
        }
        self.inner.lock().client = None;
        self.player.clear();
        Ok(())
    }

    // ---------- Library ----------

    /// Albums in the user's library, paginated.
    ///
    /// Returns a [`PaginatedAlbums`] whose `total_count` is the full server
    /// total so callers can drive "N of M" indicators and near-end
    /// load-more triggers without issuing a separate count query.
    pub fn list_albums(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.albums(Paging::new(offset, limit))))
    }

    /// Artists in the user's library, paginated. See [`list_albums`].
    pub fn list_artists(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedArtists, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.artists(Paging::new(offset, limit))))
    }

    pub fn album_tracks(&self, album_id: String) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.album_tracks(&album_id)))
    }

    /// Fetch an artist's most-played tracks (by server-tracked `PlayCount`
    /// descending, `SortName` ascending as tiebreaker). Powers the artist
    /// detail "Top Tracks" section — see #229.
    pub fn artist_top_tracks(
        &self,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.artist_top_tracks(&artist_id, limit))
        })
    }

    /// Seed a station around any item (track, album, artist, playlist,
    /// genre) via Jellyfin's polymorphic `/Items/{id}/InstantMix`. Returns a
    /// freshly generated queue of audio tracks the caller drops into the
    /// player. Powers the "Start Radio" context-menu action.
    pub fn instant_mix(
        &self,
        item_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.instant_mix(&item_id, limit)))
    }

    /// Server-curated suggestions for the Home "You might like" row. More
    /// useful than recency-ordered recent-adds for long-tail discovery.
    pub fn suggestions(&self, limit: u32) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.suggestions(limit)))
    }

    /// Artists similar to `artist_id` — Jellyfin's tag/genre-based
    /// similarity. Powers the artist detail "Fans also like" shelf.
    pub fn similar_artists(
        &self,
        artist_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Artist>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.similar_artists(&artist_id, limit)))
    }

    /// Albums similar to `album_id`. Powers the album detail "Similar
    /// albums" shelf.
    pub fn similar_albums(
        &self,
        album_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<Album>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.similar_albums(&album_id, limit)))
    }

    /// Generic similar-items fallback — returns typed [`ItemRef`]s so the
    /// UI can dispatch to the right detail screen without re-fetching.
    pub fn similar_items(
        &self,
        item_id: String,
        limit: u32,
    ) -> std::result::Result<Vec<ItemRef>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.similar_items(&item_id, limit)))
    }

    /// Most frequently played tracks for the current user, ordered by the
    /// server's `PlayCount` descending. Powers the Home "Play It Again" /
    /// "On Repeat" row.
    pub fn frequently_played_tracks(
        &self,
        limit: u32,
    ) -> std::result::Result<Vec<Track>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.frequently_played_tracks(limit)))
    }

    /// All music genres in the user's library, paginated. Each [`Genre`]
    /// carries `song_count` / `album_count` via `Fields=ItemCounts`, so the
    /// Genres tab can render counts without a second round-trip.
    pub fn genres(
        &self,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedGenres, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.genres(Paging::new(offset, limit))))
    }

    /// Albums belonging to a genre, paginated. Powers the genre detail
    /// landing view.
    pub fn items_by_genre(
        &self,
        genre_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.items_by_genre(&genre_id, Paging::new(offset, limit)))
        })
    }

    /// Full artist record with biography, backdrop image tags, and
    /// external links (MusicBrainz / Last.fm / Discogs). Feeds the artist
    /// detail header.
    pub fn artist_detail(
        &self,
        artist_id: String,
    ) -> std::result::Result<ArtistDetail, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.artist_detail(&artist_id)))
    }

    /// Fetch lyrics for a track. Returns `None` when the server reports 404
    /// (no lyrics available — common). Handles both synced LRC and plain
    /// text; `LyricLine::time_seconds` is pre-converted out of Jellyfin's
    /// 100-ns tick units.
    pub fn lyrics(&self, track_id: String) -> std::result::Result<Option<Lyrics>, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.lyrics(&track_id)))
    }

    /// Recently added albums for the Home "Recently Added" row.
    ///
    /// Server-side filtering respects the user's parental controls; the
    /// response is grouped by album so loose tracks never appear. Callers
    /// resolve `library_id` (the music collection view id) once at sign-in.
    ///
    /// Pagination caveat: Jellyfin's `/Items/Latest` endpoint does not
    /// accept `StartIndex`, so `offset` is applied client-side by slicing
    /// the top of the returned "most-recent" window. See
    /// [`JellyfinClient::latest_albums`] for details. `total_count` on the
    /// returned [`PaginatedAlbums`] is the number of items the server
    /// returned for this request, not the library total.
    pub fn latest_albums(
        &self,
        library_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedAlbums, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.latest_albums(&library_id, Paging::new(offset, limit)))
        })
    }

    /// Every audio track in the user's library, paginated and sorted by
    /// `SortName` ascending. Pass `music_library_id` to scope to a single
    /// `MusicLibrary` CollectionFolder; pass `None` to span every library
    /// the user can access.
    ///
    /// Returns a [`PaginatedTracks`] whose `total_count` is the server's
    /// `TotalRecordCount` so callers can drive "N of M" sublines and
    /// near-end load-more triggers without issuing a separate count query.
    pub fn list_tracks(
        &self,
        music_library_id: Option<String>,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.list_tracks(music_library_id.as_deref(), Paging::new(offset, limit)))
        })
    }

    /// Recently played tracks for the current user, sorted by server-side
    /// `DatePlayed` descending. Pass `music_library_id` to scope to a single
    /// `MusicLibrary` CollectionFolder.
    pub fn recently_played(
        &self,
        music_library_id: Option<String>,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, JellifyError> {
        self.with_client(|c| {
            self.runtime.block_on(
                c.recently_played(music_library_id.as_deref(), Paging::new(offset, limit)),
            )
        })
    }

    /// Playlists owned by the current user. Filtered client-side based on
    /// whether `Path` contains `/data/` (profile directory). `total_count`
    /// on the returned [`PaginatedPlaylists`] is the server's unfiltered
    /// count across both user- and public-owned playlists — see
    /// [`JellyfinClient::user_playlists`].
    pub fn user_playlists(
        &self,
        playlist_library_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedPlaylists, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.user_playlists(&playlist_library_id, Paging::new(offset, limit)))
        })
    }

    /// Public / community playlists visible to the current user — anything
    /// under the Playlists library whose `Path` does NOT contain `/data/`.
    pub fn public_playlists(
        &self,
        playlist_library_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedPlaylists, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.public_playlists(&playlist_library_id, Paging::new(offset, limit)))
        })
    }

    /// Tracks on a playlist, in the server's playlist order. Pass `offset`
    /// and `limit` for paging; the underlying `/Items` request does NOT sort
    /// server-side so the playlist's stored order is preserved. The
    /// returned [`PaginatedTracks`] carries the server total so callers can
    /// drive a page-until-done loop.
    pub fn playlist_tracks(
        &self,
        playlist_id: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<PaginatedTracks, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.playlist_tracks(&playlist_id, Paging::new(offset, limit)))
        })
    }

    /// Append items (tracks/albums/artists) to a playlist in a single
    /// round-trip. Mirrors Jellify's `addManyToPlaylist`; callers should
    /// invalidate their `playlist_tracks` cache after this returns.
    pub fn add_to_playlist(
        &self,
        playlist_id: String,
        item_ids: Vec<String>,
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| {
            let id_refs: Vec<&str> = item_ids.iter().map(String::as_str).collect();
            self.runtime
                .block_on(c.add_to_playlist(&playlist_id, &id_refs))
        })
    }

    /// Full-search query. Returns hydrated records split into typed
    /// sections (artists / albums / tracks), plus `total_record_count` so
    /// the UI can offer "Show all N results" affordances when more are
    /// available past the current page.
    pub fn search(
        &self,
        query: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<SearchResults, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.search(&query, Paging::new(offset, limit)))
        })
    }

    /// Fast typeahead search — backed by Jellyfin's `/Search/Hints`.
    ///
    /// Use this for debounced omnibox queries. It returns a single flat
    /// list of [`SearchHint`] entries carrying the server-supplied `Type`
    /// so the UI can split results into typed sections without extra
    /// round-trips. Prefer [`JellifyCore::search`] for "see all results".
    ///
    /// `offset` maps to Jellyfin's `startIndex`; `total_record_count` on
    /// the returned [`SearchHintResults`] is stable across pages.
    pub fn search_hints(
        &self,
        query: String,
        offset: u32,
        limit: u32,
    ) -> std::result::Result<SearchHintResults, JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.search_hints(&query, Paging::new(offset, limit)))
        })
    }

    /// Mark an item (track, album, artist, playlist) as a favorite for the
    /// current user. Returns the updated [`FavoriteState`] so the UI can
    /// refresh without refetching. Errors with
    /// [`JellifyError::NotAuthenticated`] if no session is active.
    pub fn set_favorite(
        &self,
        item_id: String,
    ) -> std::result::Result<FavoriteState, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.set_favorite(&item_id)))
    }

    /// Remove the favorite flag from an item for the current user. Returns the
    /// updated [`FavoriteState`] so the UI can refresh without refetching.
    /// Errors with [`JellifyError::NotAuthenticated`] if no session is active.
    pub fn unset_favorite(
        &self,
        item_id: String,
    ) -> std::result::Result<FavoriteState, JellifyError> {
        self.with_client(|c| self.runtime.block_on(c.unset_favorite(&item_id)))
    }

    /// Create a new playlist for the current user. Returns the new
    /// playlist id — callers refetch the full [`Playlist`] via
    /// [`JellifyCore::fetch_item`] if they need the populated record.
    /// `item_ids` may be empty to create an empty playlist. Errors with
    /// [`JellifyError::NotAuthenticated`] if no session is active.
    pub fn create_playlist(
        &self,
        name: String,
        item_ids: Vec<String>,
    ) -> std::result::Result<String, JellifyError> {
        self.with_client(|c| {
            let id_refs: Vec<&str> = item_ids.iter().map(String::as_str).collect();
            self.runtime.block_on(c.create_playlist(&name, &id_refs))
        })
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

    /// Report that playback has stopped for an item — backed by
    /// `POST /Sessions/Playing/Stopped`.
    ///
    /// Drives Jellyfin's server-side PlayCount increment for tracks. Callers
    /// invoke this on track end, user-driven skip, and app quit. When a song
    /// completed normally, pass the full `RunTimeTicks` as `position_ticks`.
    pub fn report_playback_stopped(
        &self,
        item_id: String,
        position_ticks: i64,
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.report_playback_stopped(&item_id, position_ticks))
        })
    }

    pub fn mark_state(&self, state: PlaybackState) {
        self.player.mark_state(state);
    }

    pub fn mark_position(&self, seconds: f64) {
        self.player.mark_position(seconds);
    }

    /// Report playback progress to the server. Called by the platform
    /// playback engine roughly every 10 seconds and on pause/resume/seek
    /// transitions so Jellyfin can drive "Now Playing" state and resume
    /// points. `position_ticks` is in Jellyfin's 100-ns tick units.
    pub fn report_playback_progress(
        &self,
        item_id: String,
        position_ticks: i64,
        is_paused: bool,
    ) -> std::result::Result<(), JellifyError> {
        self.with_client(|c| {
            self.runtime
                .block_on(c.report_playback_progress(&item_id, position_ticks, is_paused))
        })
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
