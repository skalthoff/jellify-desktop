use crate::error::{JellifyError, Result};
use crate::models::*;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION};
use reqwest::{Client as HttpClient, Response};
use serde::{Deserialize, Serialize};
use url::Url;

const CLIENT_NAME: &str = "Jellify Desktop";
const CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct JellyfinClient {
    http: HttpClient,
    base_url: Url,
    device_id: String,
    device_name: String,
    token: Option<String>,
    user_id: Option<String>,
}

impl JellyfinClient {
    pub fn new(base_url: &str, device_id: String, device_name: String) -> Result<Self> {
        let mut url = Url::parse(base_url)?;
        if !url.path().ends_with('/') {
            let path = format!("{}/", url.path());
            url.set_path(&path);
        }
        let http = HttpClient::builder()
            .user_agent(format!("{CLIENT_NAME}/{CLIENT_VERSION}"))
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| JellifyError::Network(e.to_string()))?;
        Ok(Self {
            http,
            base_url: url,
            device_id,
            device_name,
            token: None,
            user_id: None,
        })
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    pub fn http(&self) -> &HttpClient {
        &self.http
    }

    pub fn user_id(&self) -> Option<&str> {
        self.user_id.as_deref()
    }

    pub fn token(&self) -> Option<&str> {
        self.token.as_deref()
    }

    pub fn set_session(&mut self, token: String, user_id: String) {
        self.token = Some(token);
        self.user_id = Some(user_id);
    }

    fn auth_header(&self) -> String {
        let token_part = self
            .token
            .as_deref()
            .map(|t| format!(", Token=\"{t}\""))
            .unwrap_or_default();
        format!(
            "MediaBrowser Client=\"{client}\", Device=\"{device}\", DeviceId=\"{device_id}\", Version=\"{version}\"{token}",
            client = CLIENT_NAME,
            device = self.device_name,
            device_id = self.device_id,
            version = CLIENT_VERSION,
            token = token_part,
        )
    }

    pub fn build_headers(&self) -> Result<HeaderMap> {
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&self.auth_header())
                .map_err(|e| JellifyError::InvalidInput(e.to_string()))?,
        );
        Ok(headers)
    }

    fn endpoint(&self, path: &str) -> Result<Url> {
        let trimmed = path.trim_start_matches('/');
        self.base_url.join(trimmed).map_err(Into::into)
    }

    async fn check(resp: Response) -> Result<Response> {
        let status = resp.status();
        if status.is_success() {
            Ok(resp)
        } else {
            let message = resp.text().await.unwrap_or_default();
            Err(JellifyError::Server {
                status: status.as_u16(),
                message,
            })
        }
    }

    // ----- Public info / ping -----

    pub async fn public_info(&self) -> Result<PublicSystemInfo> {
        let url = self.endpoint("System/Info/Public")?;
        let resp = self.http.get(url).send().await?;
        Self::check(resp).await?.json().await.map_err(Into::into)
    }

    // ----- Auth -----

    pub async fn authenticate_by_name(&mut self, username: &str, password: &str) -> Result<Session> {
        let url = self.endpoint("Users/AuthenticateByName")?;
        let body = AuthByNameBody {
            username: username.to_string(),
            pw: password.to_string(),
        };
        let resp = self
            .http
            .post(url)
            .headers(self.build_headers()?)
            .json(&body)
            .send()
            .await?;
        let resp = Self::check(resp).await?;
        let auth: AuthResult = resp.json().await?;
        self.token = Some(auth.access_token.clone());
        self.user_id = Some(auth.user.id.clone());
        Ok(Session {
            server: Server {
                url: self.base_url.to_string(),
                name: auth.server_name.unwrap_or_default(),
                version: None,
                id: auth.server_id,
            },
            user: User {
                id: auth.user.id,
                name: auth.user.name,
                server_id: auth.user.server_id,
                primary_image_tag: auth.user.primary_image_tag,
            },
            access_token: auth.access_token,
            device_id: self.device_id.clone(),
        })
    }

    // ----- Library queries -----

    pub async fn artists(&self, paging: Paging) -> Result<Vec<Artist>> {
        let user_id = self.user_id.as_ref().ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Artists/AlbumArtists")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("userId", user_id);
            q.append_pair("Recursive", "true");
            q.append_pair("IncludeItemTypes", "MusicArtist");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("SortBy", "SortName");
            q.append_pair("SortOrder", "Ascending");
            q.append_pair("Fields", "Genres,PrimaryImageAspectRatio");
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(raw.items.into_iter().map(Artist::from).collect())
    }

    pub async fn albums(&self, paging: Paging) -> Result<Vec<Album>> {
        let user_id = self.user_id.as_ref().ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Recursive", "true");
            q.append_pair("IncludeItemTypes", "MusicAlbum");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("SortBy", "SortName");
            q.append_pair("SortOrder", "Ascending");
            q.append_pair("Fields", "Genres,ProductionYear,ChildCount,PrimaryImageAspectRatio");
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(raw.items.into_iter().map(Album::from).collect())
    }

    pub async fn album_tracks(&self, album_id: &str) -> Result<Vec<Track>> {
        let user_id = self.user_id.as_ref().ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("ParentId", album_id);
            q.append_pair("SortBy", "ParentIndexNumber,IndexNumber,SortName");
            q.append_pair("SortOrder", "Ascending");
            q.append_pair(
                "Fields",
                "MediaSources,UserData,ProductionYear,PrimaryImageAspectRatio",
            );
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(raw.items.into_iter().map(Track::from).collect())
    }

    pub async fn search(&self, query: &str) -> Result<SearchResults> {
        let user_id = self.user_id.as_ref().ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Recursive", "true");
            q.append_pair("SearchTerm", query);
            q.append_pair("IncludeItemTypes", "MusicArtist,MusicAlbum,Audio");
            q.append_pair("Limit", "50");
            q.append_pair("Fields", "Genres,ProductionYear,PrimaryImageAspectRatio");
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;

        let mut artists = Vec::new();
        let mut albums = Vec::new();
        let mut tracks = Vec::new();
        for item in raw.items {
            match item.kind.as_deref() {
                Some("MusicArtist") => artists.push(Artist::from(item)),
                Some("MusicAlbum") => albums.push(Album::from(item)),
                Some("Audio") => tracks.push(Track::from(item)),
                _ => {}
            }
        }
        Ok(SearchResults {
            artists,
            albums,
            tracks,
        })
    }

    // ----- Streaming -----

    /// Fetch the full audio payload for a track, authenticated. Returns the
    /// bytes plus the reported Content-Type (needed to pick the right decoder).
    pub async fn stream_bytes(&self, track_id: &str) -> Result<(Vec<u8>, Option<String>)> {
        let url = self.stream_url(track_id)?;
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let resp = Self::check(resp).await?;
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let bytes = resp.bytes().await?;
        Ok((bytes.to_vec(), content_type))
    }

    /// Build the URL to stream a given track.
    ///
    /// Advertises all containers AVFoundation / MediaPlayer handle natively,
    /// so Jellyfin direct-streams whenever the source matches. Exotic source
    /// formats fall back to a transcoded MP3 stream.
    pub fn stream_url(&self, track_id: &str) -> Result<Url> {
        let mut url = self.endpoint(&format!("Audio/{track_id}/universal"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", self.user_id.as_deref().unwrap_or(""));
            q.append_pair("DeviceId", &self.device_id);
            q.append_pair("MaxStreamingBitrate", "320000");
            q.append_pair("Container", "mp3,aac,m4a,flac,alac,wav,ogg,opus");
            q.append_pair("AudioCodec", "mp3,aac,flac,alac,pcm,vorbis,opus");
            q.append_pair("TranscodingContainer", "mp3");
            q.append_pair("TranscodingProtocol", "http");
            if let Some(token) = &self.token {
                q.append_pair("api_key", token);
            }
        }
        Ok(url)
    }

    /// Render the `Authorization` header value used for every Jellyfin request.
    /// Platform audio engines (AVPlayer on macOS, etc.) attach this when
    /// streaming from the URL returned by `stream_url`.
    pub fn auth_header_value(&self) -> String {
        self.auth_header()
    }

    /// Build image URL for a track/album/artist primary image.
    pub fn image_url(&self, item_id: &str, tag: Option<&str>, max_width: u32) -> Result<Url> {
        let mut url = self.endpoint(&format!("Items/{item_id}/Images/Primary"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("maxWidth", &max_width.to_string());
            q.append_pair("quality", "90");
            if let Some(t) = tag {
                q.append_pair("tag", t);
            }
        }
        Ok(url)
    }
}

// ============================================================================
// Wire types (Jellyfin's JSON shapes)
// ============================================================================

#[derive(Debug, Deserialize)]
pub struct PublicSystemInfo {
    #[serde(rename = "ServerName")]
    pub server_name: Option<String>,
    #[serde(rename = "Version")]
    pub version: Option<String>,
    #[serde(rename = "Id")]
    pub id: Option<String>,
}

#[derive(Serialize)]
struct AuthByNameBody {
    #[serde(rename = "Username")]
    username: String,
    #[serde(rename = "Pw")]
    pw: String,
}

#[derive(Debug, Deserialize)]
struct AuthResult {
    #[serde(rename = "AccessToken")]
    access_token: String,
    #[serde(rename = "ServerId")]
    server_id: Option<String>,
    #[serde(rename = "ServerName")]
    server_name: Option<String>,
    #[serde(rename = "User")]
    user: RawUser,
}

#[derive(Debug, Deserialize)]
struct RawUser {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "ServerId")]
    server_id: Option<String>,
    #[serde(rename = "PrimaryImageTag")]
    primary_image_tag: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawItems<T> {
    #[serde(rename = "Items", default)]
    items: Vec<T>,
    #[serde(rename = "TotalRecordCount", default)]
    #[allow(dead_code)]
    total_record_count: u32,
}

#[derive(Debug, Default, Deserialize)]
pub struct RawItem {
    #[serde(rename = "Id")]
    pub id: String,
    #[serde(rename = "Name", default)]
    pub name: String,
    #[serde(rename = "Type")]
    pub kind: Option<String>,
    #[serde(rename = "AlbumId")]
    pub album_id: Option<String>,
    #[serde(rename = "Album")]
    pub album: Option<String>,
    #[serde(rename = "AlbumArtist")]
    pub album_artist: Option<String>,
    #[serde(rename = "AlbumArtistId")]
    pub album_artist_id: Option<String>,
    #[serde(rename = "ArtistItems", default)]
    pub artist_items: Vec<NamedItem>,
    #[serde(rename = "Artists", default)]
    pub artists: Vec<String>,
    #[serde(rename = "ProductionYear")]
    pub production_year: Option<i32>,
    #[serde(rename = "IndexNumber")]
    pub index_number: Option<u32>,
    #[serde(rename = "ParentIndexNumber")]
    pub parent_index_number: Option<u32>,
    #[serde(rename = "RunTimeTicks", default)]
    pub runtime_ticks: u64,
    #[serde(rename = "ChildCount")]
    pub child_count: Option<u32>,
    #[serde(rename = "Genres", default)]
    pub genres: Vec<String>,
    #[serde(rename = "UserData")]
    pub user_data: Option<RawUserData>,
    #[serde(rename = "ImageTags", default)]
    pub image_tags: std::collections::HashMap<String, String>,
    #[serde(rename = "Container")]
    pub container: Option<String>,
    #[serde(rename = "Bitrate")]
    pub bitrate: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct NamedItem {
    #[serde(rename = "Id")]
    pub id: String,
    #[serde(rename = "Name", default)]
    pub name: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct RawUserData {
    #[serde(rename = "IsFavorite", default)]
    pub is_favorite: bool,
    #[serde(rename = "PlayCount", default)]
    pub play_count: u32,
}

// ============================================================================
// Conversions
// ============================================================================

impl From<RawItem> for Artist {
    fn from(r: RawItem) -> Self {
        Artist {
            id: r.id,
            name: r.name,
            album_count: 0,
            song_count: 0,
            genres: r.genres,
            image_tag: r.image_tags.get("Primary").cloned(),
        }
    }
}

impl From<RawItem> for Album {
    fn from(r: RawItem) -> Self {
        let artist_name = r
            .album_artist
            .clone()
            .or_else(|| r.artists.first().cloned())
            .unwrap_or_default();
        let artist_id = r
            .album_artist_id
            .clone()
            .or_else(|| r.artist_items.first().map(|a| a.id.clone()));
        Album {
            id: r.id,
            name: r.name,
            artist_name,
            artist_id,
            year: r.production_year,
            track_count: r.child_count.unwrap_or(0),
            runtime_ticks: r.runtime_ticks,
            genres: r.genres,
            image_tag: r.image_tags.get("Primary").cloned(),
        }
    }
}

impl From<RawItem> for Track {
    fn from(r: RawItem) -> Self {
        let artist_name = r
            .album_artist
            .clone()
            .or_else(|| r.artists.first().cloned())
            .unwrap_or_default();
        let artist_id = r
            .album_artist_id
            .clone()
            .or_else(|| r.artist_items.first().map(|a| a.id.clone()));
        let user_data = r.user_data.unwrap_or_default();
        Track {
            id: r.id,
            name: r.name,
            album_id: r.album_id,
            album_name: r.album,
            artist_name,
            artist_id,
            index_number: r.index_number,
            disc_number: r.parent_index_number,
            year: r.production_year,
            runtime_ticks: r.runtime_ticks,
            is_favorite: user_data.is_favorite,
            play_count: user_data.play_count,
            container: r.container,
            bitrate: r.bitrate,
            image_tag: r.image_tags.get("Primary").cloned(),
        }
    }
}
