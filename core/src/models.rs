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
    pub run_time_ticks: Option<u64>,
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
