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
