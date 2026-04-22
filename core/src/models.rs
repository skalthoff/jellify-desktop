use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Server {
    pub url: String,
    pub name: String,
    pub version: Option<String>,
    pub id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct User {
    pub id: String,
    pub name: String,
    pub server_id: Option<String>,
    pub primary_image_tag: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Session {
    pub server: Server,
    pub user: User,
    pub access_token: String,
    pub device_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub album_count: u32,
    pub song_count: u32,
    pub genres: Vec<String>,
    pub image_tag: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Album {
    pub id: String,
    pub name: String,
    pub artist_name: String,
    pub artist_id: Option<String>,
    pub year: Option<i32>,
    pub track_count: u32,
    pub runtime_ticks: u64,
    pub genres: Vec<String>,
    pub image_tag: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Track {
    pub id: String,
    pub name: String,
    pub album_id: Option<String>,
    pub album_name: Option<String>,
    pub artist_name: String,
    pub artist_id: Option<String>,
    pub index_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub year: Option<i32>,
    pub runtime_ticks: u64,
    pub is_favorite: bool,
    pub play_count: u32,
    pub container: Option<String>,
    pub bitrate: Option<u32>,
    pub image_tag: Option<String>,
}

impl Track {
    pub fn duration_seconds(&self) -> f64 {
        self.runtime_ticks as f64 / 10_000_000.0
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub track_count: u32,
    pub runtime_ticks: u64,
    pub image_tag: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct SearchResults {
    pub artists: Vec<Artist>,
    pub albums: Vec<Album>,
    pub tracks: Vec<Track>,
    /// Total number of items (across all item types) the server reports for
    /// this query, as returned in `TotalRecordCount`. When the total is
    /// greater than `artists.len() + albums.len() + tracks.len()`, more
    /// results are available past the current page.
    pub total_record_count: u32,
}

/// Page of albums returned by `albums` and `latest_albums`. `total_count`
/// comes from Jellyfin's `TotalRecordCount`, so callers can detect when more
/// pages exist beyond the current `items.len()` + `offset`. UniFFI doesn't
/// support generics, so there is one of these per item type.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedAlbums {
    pub items: Vec<Album>,
    pub total_count: u32,
}

/// Page of artists returned by `artists`. See [`PaginatedAlbums`].
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedArtists {
    pub items: Vec<Artist>,
    pub total_count: u32,
}

/// Page of tracks returned by `recently_played` and `playlist_tracks`.
/// See [`PaginatedAlbums`].
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedTracks {
    pub items: Vec<Track>,
    pub total_count: u32,
}

/// Page of playlists returned by `user_playlists` and `public_playlists`.
/// Note: these two endpoints filter the server's response client-side by
/// `Path`, so `total_count` is the server-reported total across BOTH user
/// and public playlists (i.e. what Jellyfin would return without the
/// client-side partition). Callers should treat it as an upper bound on the
/// page size they need to fetch, not as `items.len()`'s true total.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedPlaylists {
    pub items: Vec<Playlist>,
    pub total_count: u32,
}

/// A music genre, as returned by `GET /MusicGenres`. Counts come from the
/// server's `ItemCounts` projection — both populate on the same request, so
/// callers can render "42 songs · 6 albums" style sublines without a second
/// round-trip. `image_tag` mirrors Jellyfin's `ImageTags.Primary` and feeds
/// [`JellyfinClient::image_url`] when present.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Genre {
    pub id: String,
    pub name: String,
    pub song_count: u32,
    pub album_count: u32,
    pub image_tag: Option<String>,
}

/// Page of genres returned by `genres`. See [`PaginatedAlbums`].
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct PaginatedGenres {
    pub items: Vec<Genre>,
    pub total_count: u32,
}

/// A typed reference to a Jellyfin item — minimal shape used by
/// `similar_items`. `kind` carries the server's `Type` field so the UI can
/// dispatch to the right detail screen (`MusicAlbum` → album view,
/// `MusicArtist` → artist view, `Audio` → track row) without a second fetch.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ItemRef {
    pub id: String,
    pub name: String,
    /// Server-supplied `Type` field (e.g. `Audio`, `MusicAlbum`,
    /// `MusicArtist`).
    pub kind: Option<String>,
    pub image_tag: Option<String>,
}

/// An external link on an artist/album record — one entry in Jellyfin's
/// `ExternalUrls` array. Surfaced by [`JellyfinClient::artist_detail`] so the
/// artist page can render MusicBrainz / Last.fm / Discogs shortcut icons.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ExternalUrl {
    pub name: String,
    pub url: String,
}

/// Extended artist record returned by [`JellyfinClient::artist_detail`].
/// Mirrors the base [`Artist`] fields, then layers on biography, backdrops,
/// and external links for the artist detail header. `overview` is returned
/// verbatim from Jellyfin — callers may need to strip HTML if their UI
/// expects plain text.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ArtistDetail {
    pub id: String,
    pub name: String,
    pub genres: Vec<String>,
    pub image_tag: Option<String>,
    /// Long-form biography. May contain HTML / Markdown — the UI decides
    /// whether to render inline or plain-text.
    pub overview: Option<String>,
    /// `BackdropImageTags` from the server — one entry per backdrop image.
    /// Pass the index to [`JellyfinClient::image_url_of_type`] with
    /// [`ImageType::Backdrop`] to build per-backdrop URLs.
    pub backdrop_image_tags: Vec<String>,
    /// Parallel to `BackdropImageTags`: the underlying item ids that carry
    /// the backdrop tags. When empty, callers should use `id` directly.
    pub external_urls: Vec<ExternalUrl>,
}

/// One line in a `Lyrics` payload. `time_seconds` is derived from
/// Jellyfin's `Start` field (100-ns ticks) so callers can compare it
/// directly against the platform audio engine's playback position.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct LyricLine {
    pub time_seconds: f64,
    pub text: String,
}

/// Lyrics payload for a track, as returned by `GET /Audio/{id}/Lyrics`.
/// When `is_synced` is `true`, `lines[i].time_seconds` increases
/// monotonically and can drive a karaoke-style highlight; when `false`
/// there is typically a single line with `time_seconds == 0.0`.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Lyrics {
    pub is_synced: bool,
    pub lines: Vec<LyricLine>,
}

/// A lightweight, typed-heterogeneous search result returned by
/// `GET /Search/Hints`. Jellyfin trims its `BaseItemDto` down to just the
/// columns the typeahead UI needs, so `SearchHint` is the preferred shape
/// for debounced omnibox-style search: cheap to fetch, cheap to render.
///
/// `kind` carries the server-supplied `Type` (`Audio`, `MusicAlbum`,
/// `MusicArtist`, `Playlist`, etc.), so a single flat list can be split
/// into typed sections client-side without issuing per-type queries.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct SearchHint {
    pub id: String,
    pub name: String,
    /// Server-supplied `Type` field (e.g. `Audio`, `MusicAlbum`,
    /// `MusicArtist`, `Playlist`). Kept as a raw string so we don't have
    /// to exhaustively enumerate every `BaseItemKind` the server may return.
    pub kind: Option<String>,
    /// The `MediaType` as reported by Jellyfin (`Audio`, `Video`, `Unknown`, ...).
    pub media_type: Option<String>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub album_artist: Option<String>,
    /// The exact substring from the query that matched this hint. Useful for
    /// highlighting the matched portion of `name` in the UI.
    pub matched_term: Option<String>,
    pub primary_image_tag: Option<String>,
    pub production_year: Option<i32>,
    pub index_number: Option<u32>,
    pub parent_index_number: Option<u32>,
    pub runtime_ticks: Option<u64>,
    pub artists: Vec<String>,
    pub is_folder: Option<bool>,
}

/// Response envelope for `GET /Search/Hints`:
/// `{ SearchHints: [...], TotalRecordCount }`. The total is the unpaged
/// count so clients can show "Showing X of Y" hints in the typeahead.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct SearchHintResults {
    pub search_hints: Vec<SearchHint>,
    pub total_record_count: u32,
}

/// Subset of Jellyfin's `UserItemDataDto` surfaced by favorite mutations so
/// callers can update UI state without refetching the item. `last_played` is
/// a raw ISO 8601 string as returned by the server (or `null` when the item
/// has never been played).
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct FavoriteState {
    #[serde(rename = "IsFavorite", default)]
    pub is_favorite: bool,
    #[serde(rename = "PlayCount", default)]
    pub play_count: Option<u32>,
    #[serde(rename = "LastPlayedDate", default)]
    pub last_played: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, uniffi::Record)]
pub struct Paging {
    pub offset: u32,
    pub limit: u32,
}

impl Paging {
    pub fn new(offset: u32, limit: u32) -> Self {
        Self { offset, limit }
    }
}

/// Jellyfin image variants served from `GET /Items/{id}/Images/{type}`.
/// Mirrors the `ImageType` routes defined by the Jellyfin `ImageController`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ImageType {
    Primary,
    Backdrop,
    Thumb,
    Disc,
    Logo,
    Banner,
    Art,
    Box,
}

impl ImageType {
    /// Path segment as Jellyfin expects it in the URL.
    pub fn as_path(&self) -> &'static str {
        match self {
            ImageType::Primary => "Primary",
            ImageType::Backdrop => "Backdrop",
            ImageType::Thumb => "Thumb",
            ImageType::Disc => "Disc",
            ImageType::Logo => "Logo",
            ImageType::Banner => "Banner",
            ImageType::Art => "Art",
            ImageType::Box => "Box",
        }
    }
}
