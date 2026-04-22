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
