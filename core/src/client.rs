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

    pub async fn authenticate_by_name(
        &mut self,
        username: &str,
        password: &str,
    ) -> Result<Session> {
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

    pub async fn artists(&self, paging: Paging) -> Result<PaginatedArtists> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
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
        Ok(PaginatedArtists {
            items: raw.items.into_iter().map(Artist::from).collect(),
            total_count: raw.total_record_count,
        })
    }

    pub async fn albums(&self, paging: Paging) -> Result<PaginatedAlbums> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Recursive", "true");
            q.append_pair("IncludeItemTypes", "MusicAlbum");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("SortBy", "SortName");
            q.append_pair("SortOrder", "Ascending");
            q.append_pair(
                "Fields",
                "Genres,ProductionYear,ChildCount,PrimaryImageAspectRatio",
            );
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(PaginatedAlbums {
            items: raw.items.into_iter().map(Album::from).collect(),
            total_count: raw.total_record_count,
        })
    }

    /// Fetch the most recently added albums in a library, respecting the
    /// authenticated user's parental controls (enforced server-side via
    /// `userId`). Backed by `GET /Items/Latest`.
    ///
    /// Notes:
    /// - The response is a bare `BaseItemDto[]` (not wrapped in
    ///   `{ Items, TotalRecordCount }` like most library endpoints).
    /// - `groupItems=true` asks the server to collapse audio children into
    ///   their parent album when both land in the "recent" window, so the
    ///   Home "Recently Added" row shows albums rather than loose tracks.
    /// - `library_id` is the music library's collection id (a "Views" item);
    ///   callers typically resolve it once at sign-in and cache it.
    ///
    /// # Pagination caveat
    ///
    /// The underlying `/Items/Latest` endpoint does NOT accept a
    /// `StartIndex` query parameter (see Jellyfin's
    /// `UserLibraryController.GetLatestMedia` — only `Limit` is exposed).
    /// To still offer a uniform `Paging` surface, this method asks the
    /// server for `offset + limit` items and slices the tail client-side.
    /// That means `offset` values larger than Jellyfin's internal
    /// "most recent" window will return an empty page even if more albums
    /// exist in the library. Callers that need the full catalog should use
    /// [`JellyfinClient::albums`] instead; `latest_albums` is optimized for
    /// the Home "Recently Added" row.
    ///
    /// `total_count` on the returned [`PaginatedAlbums`] is the number of
    /// items the server returned for this request, NOT the library total —
    /// `/Items/Latest` does not report `TotalRecordCount`.
    pub async fn latest_albums(&self, library_id: &str, paging: Paging) -> Result<PaginatedAlbums> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let limit = paging.limit.max(1);
        let server_limit = paging.offset.saturating_add(limit).max(1);
        let mut url = self.endpoint("Items/Latest")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("UserId", user_id);
            q.append_pair("ParentId", library_id);
            q.append_pair("IncludeItemTypes", "MusicAlbum");
            q.append_pair("Limit", &server_limit.to_string());
            q.append_pair("GroupItems", "true");
            q.append_pair(
                "Fields",
                "Genres,ProductionYear,ChildCount,PrimaryImageAspectRatio",
            );
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let items: Vec<RawItem> = Self::check(resp).await?.json().await?;
        let total_count = items.len() as u32;
        let sliced: Vec<Album> = items
            .into_iter()
            .skip(paging.offset as usize)
            .take(limit as usize)
            .map(Album::from)
            .collect();
        Ok(PaginatedAlbums {
            items: sliced,
            total_count,
        })
    }

    /// Recently played audio tracks for the current user, sorted by
    /// `DatePlayed` descending. Jellyfin implicitly omits tracks with a null
    /// `UserData.LastPlayedDate` from this sort, so the result is the user's
    /// listening history.
    ///
    /// `music_library_id` is the `MusicLibrary` CollectionFolder id; when
    /// provided it scopes the query via `ParentId`. When `None`, Jellyfin
    /// searches across all libraries the user can access.
    pub async fn recently_played(
        &self,
        music_library_id: Option<&str>,
        paging: Paging,
    ) -> Result<PaginatedTracks> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            if let Some(parent) = music_library_id {
                q.append_pair("ParentId", parent);
            }
            q.append_pair("Recursive", "true");
            q.append_pair("IncludeItemTypes", "Audio");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("SortBy", "DatePlayed");
            q.append_pair("SortOrder", "Descending");
            q.append_pair(
                "Fields",
                "ParentId,MediaSources,UserData,ProductionYear,PrimaryImageAspectRatio",
            );
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(PaginatedTracks {
            items: raw.items.into_iter().map(Track::from).collect(),
            total_count: raw.total_record_count,
        })
    }

    /// Fetch playlists the current user owns. Jellyfin stores user-owned
    /// playlists under the user's profile directory, so the returned `Path`
    /// contains `/data/` (e.g. `/config/data/users/<id>/playlists/...`);
    /// public/community playlists live elsewhere and are filtered out.
    ///
    /// `playlist_library_id` is the Playlists view id (the CollectionFolder
    /// with `CollectionType == "playlists"`). Resolving that id is tracked
    /// separately; callers pass it in here.
    ///
    /// `total_count` on the returned [`PaginatedPlaylists`] is the server's
    /// unfiltered `TotalRecordCount` (all playlists under the library view,
    /// both user- and public-owned) — the per-page `items.len()` may be
    /// smaller once the client-side `/data/` filter has been applied.
    pub async fn user_playlists(
        &self,
        playlist_library_id: &str,
        paging: Paging,
    ) -> Result<PaginatedPlaylists> {
        let raw = self.playlists_items(playlist_library_id, paging).await?;
        let items = raw
            .items
            .into_iter()
            .filter(|i| i.path.as_deref().is_some_and(|p| p.contains("/data/")))
            .map(Playlist::from)
            .collect();
        Ok(PaginatedPlaylists {
            items,
            total_count: raw.total_record_count,
        })
    }

    /// Fetch playlists visible to the current user that are NOT owned by
    /// them — i.e. public/community playlists. These live outside the user's
    /// profile directory, so their `Path` does not contain `/data/`.
    ///
    /// `playlist_library_id` is the Playlists view id (the CollectionFolder
    /// with `CollectionType == "playlists"`). Resolving that id is tracked
    /// separately; callers pass it in here.
    ///
    /// See [`JellyfinClient::user_playlists`] for the `total_count` caveat.
    pub async fn public_playlists(
        &self,
        playlist_library_id: &str,
        paging: Paging,
    ) -> Result<PaginatedPlaylists> {
        let raw = self.playlists_items(playlist_library_id, paging).await?;
        let items = raw
            .items
            .into_iter()
            .filter(|i| !i.path.as_deref().is_some_and(|p| p.contains("/data/")))
            .map(Playlist::from)
            .collect();
        Ok(PaginatedPlaylists {
            items,
            total_count: raw.total_record_count,
        })
    }

    /// Shared `GET /Items` request that returns all playlists under the
    /// given Playlists library view. `user_playlists` / `public_playlists`
    /// partition the result by `Path`. Returns the raw [`RawItems`] wrapper
    /// so callers can forward `total_record_count` to their paginated
    /// response shape.
    async fn playlists_items(
        &self,
        playlist_library_id: &str,
        paging: Paging,
    ) -> Result<RawItems<RawItem>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("ParentId", playlist_library_id);
            q.append_pair("UserId", user_id);
            q.append_pair("IncludeItemTypes", "Playlist");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("Fields", "ChildCount,Path");
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(raw)
    }

    /// Fetch the audio tracks on a playlist, preserving the server's playlist
    /// order. Backed by `GET /Items?ParentId={playlistId}&IncludeItemTypes=Audio`.
    ///
    /// Order is load-bearing: playlists are ordered collections, so this
    /// endpoint intentionally does NOT pass `SortBy`/`SortOrder` — Jellyfin
    /// returns items in the playlist's stored order when no sort is specified.
    /// Callers that need a different sort can do it client-side.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    pub async fn playlist_tracks(
        &self,
        playlist_id: &str,
        paging: Paging,
    ) -> Result<PaginatedTracks> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("ParentId", playlist_id);
            q.append_pair("UserId", user_id);
            q.append_pair("IncludeItemTypes", "Audio");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
            q.append_pair("Fields", "MediaSources,ParentId,Path,SortName");
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawItems<RawItem> = Self::check(resp).await?.json().await?;
        Ok(PaginatedTracks {
            items: raw.items.into_iter().map(Track::from).collect(),
            total_count: raw.total_record_count,
        })
    }

    pub async fn album_tracks(&self, album_id: &str) -> Result<Vec<Track>> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
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

    /// Fetch a single item by id with a caller-selected set of `Fields`.
    ///
    /// Uses `GET /Items?Ids={id}&Fields=...` as a workaround for the
    /// deprecated `/Users/{userId}/Items/{itemId}` endpoint. Returns the
    /// first element of the `Items` array as raw JSON so callers can pick
    /// whichever fields they asked for without this layer pre-projecting.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no `user_id` is set.
    ///
    /// Returns [`JellifyError::Server`] with status `404` when the server
    /// responds successfully but the `Items` array is empty (item not
    /// found or not visible to the current user).
    pub async fn fetch_item(&self, item_id: &str, fields: &[&str]) -> Result<serde_json::Value> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Items")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Ids", item_id);
            if !fields.is_empty() {
                q.append_pair("Fields", &fields.join(","));
            }
            q.append_pair("userId", user_id);
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let mut body: serde_json::Value = Self::check(resp).await?.json().await?;
        let items = body
            .get_mut("Items")
            .and_then(|v| v.as_array_mut())
            .ok_or_else(|| {
                JellifyError::Decode("fetch_item: response missing Items array".into())
            })?;
        if items.is_empty() {
            return Err(JellifyError::Server {
                status: 404,
                message: format!("item not found: {item_id}"),
            });
        }
        Ok(items.swap_remove(0))
    }

    /// Mark an item as a favorite for the current user.
    ///
    /// Uses the preferred `POST /UserFavoriteItems/{itemId}` endpoint, where
    /// the current user is inferred from the authentication token. If the
    /// server does not support that route (404/405 — older Jellyfin builds),
    /// this falls back to the legacy `POST /Users/{userId}/FavoriteItems/{itemId}`
    /// endpoint when a `user_id` is available.
    ///
    /// Returns the updated [`FavoriteState`] so callers can refresh UI state
    /// without refetching the item.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn set_favorite(&self, item_id: &str) -> Result<FavoriteState> {
        self.token.as_ref().ok_or(JellifyError::NotAuthenticated)?;

        let url = self.endpoint(&format!("UserFavoriteItems/{item_id}"))?;
        let resp = self
            .http
            .post(url)
            .headers(self.build_headers()?)
            .send()
            .await?;

        if resp.status().is_success() {
            return resp.json().await.map_err(Into::into);
        }

        if matches!(
            resp.status(),
            reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::METHOD_NOT_ALLOWED
        ) {
            if let Some(user_id) = self.user_id.as_ref() {
                let legacy_url =
                    self.endpoint(&format!("Users/{user_id}/FavoriteItems/{item_id}"))?;
                let legacy_resp = self
                    .http
                    .post(legacy_url)
                    .headers(self.build_headers()?)
                    .send()
                    .await?;
                return Self::check(legacy_resp)
                    .await?
                    .json()
                    .await
                    .map_err(Into::into);
            }
        }

        Self::check(resp).await?.json().await.map_err(Into::into)
    }

    /// Remove the favorite flag from an item for the current user.
    ///
    /// Uses the preferred `DELETE /UserFavoriteItems/{itemId}` endpoint, where
    /// the current user is inferred from the authentication token. If the
    /// server does not support that route (404/405 — older Jellyfin builds),
    /// this falls back to the legacy `DELETE /Users/{userId}/FavoriteItems/{itemId}`
    /// endpoint when a `user_id` is available.
    ///
    /// Returns the updated [`FavoriteState`] so callers can refresh UI state
    /// without refetching the item.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn unset_favorite(&self, item_id: &str) -> Result<FavoriteState> {
        self.token.as_ref().ok_or(JellifyError::NotAuthenticated)?;

        let url = self.endpoint(&format!("UserFavoriteItems/{item_id}"))?;
        let resp = self
            .http
            .delete(url)
            .headers(self.build_headers()?)
            .send()
            .await?;

        if resp.status().is_success() {
            return resp.json().await.map_err(Into::into);
        }

        if matches!(
            resp.status(),
            reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::METHOD_NOT_ALLOWED
        ) {
            if let Some(user_id) = self.user_id.as_ref() {
                let legacy_url =
                    self.endpoint(&format!("Users/{user_id}/FavoriteItems/{item_id}"))?;
                let legacy_resp = self
                    .http
                    .delete(legacy_url)
                    .headers(self.build_headers()?)
                    .send()
                    .await?;
                return Self::check(legacy_resp)
                    .await?
                    .json()
                    .await
                    .map_err(Into::into);
            }
        }

        Self::check(resp).await?.json().await.map_err(Into::into)
    }

    /// Report current playback progress to Jellyfin. Jellify calls this
    /// roughly every 10 seconds during playback, and whenever pause/resume/
    /// seek transitions occur, so the server can drive "Now Playing" state
    /// and durable resume points.
    ///
    /// Uses `POST /Sessions/Playing/Progress` with a
    /// `PlaybackProgressInfo`-shaped JSON body. `position_ticks` is in
    /// Jellyfin's 100-ns tick units (i.e. `seconds * 10_000_000`).
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] when no token is set.
    pub async fn report_playback_progress(
        &self,
        item_id: &str,
        position_ticks: i64,
        is_paused: bool,
    ) -> Result<()> {
        self.token.as_ref().ok_or(JellifyError::NotAuthenticated)?;

        let url = self.endpoint("Sessions/Playing/Progress")?;
        let body = PlaybackProgressBody {
            item_id: item_id.to_string(),
            position_ticks,
            is_paused,
        };
        let resp = self
            .http
            .post(url)
            .headers(self.build_headers()?)
            .json(&body)
            .send()
            .await?;
        Self::check(resp).await?;
        Ok(())
    }

    /// Full-search query against `Users/{id}/Items?SearchTerm=…`. Returns
    /// fully-hydrated records split into typed sections (artists / albums /
    /// tracks) — use this for a "See all results" page where the UI wants
    /// cards rather than raw hints. For a debounced omnibox, prefer
    /// [`JellyfinClient::search_hints`].
    ///
    /// `paging` applies to the combined response: Jellyfin does not offer
    /// per-type pagination on this endpoint, so `total_record_count` is the
    /// server's total across ALL matched item types. Callers that want to
    /// page a single kind (only tracks, only albums) should issue typed
    /// requests via [`JellyfinClient::albums`] / `artists` etc. with
    /// `SearchTerm` — a follow-up once the UI grows that affordance.
    pub async fn search(&self, query: &str, paging: Paging) -> Result<SearchResults> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint(&format!("Users/{user_id}/Items"))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("Recursive", "true");
            q.append_pair("SearchTerm", query);
            q.append_pair("IncludeItemTypes", "MusicArtist,MusicAlbum,Audio");
            q.append_pair("Limit", &paging.limit.max(1).to_string());
            q.append_pair("StartIndex", &paging.offset.to_string());
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
            total_record_count: raw.total_record_count,
        })
    }

    /// Fast typeahead search backed by `GET /Search/Hints`.
    ///
    /// Unlike [`JellyfinClient::search`], which issues a full
    /// `Users/{id}/Items` query and returns fully-hydrated records, this
    /// endpoint returns the server's trimmed [`SearchHint`] DTO: just the
    /// columns an omnibox/typeahead needs (`Name`, `Type`, `AlbumArtist`,
    /// `PrimaryImageTag`, `MatchedTerm`, ...). That makes it the right
    /// call for the debounced-per-keystroke case — cheap to fetch, cheap
    /// to render, and the results include `Type`/`MediaType` so a single
    /// flat list can be split into typed sections client-side.
    ///
    /// Scoped to music by default
    /// (`includeItemTypes=Audio,MusicAlbum,MusicArtist,Playlist`). Requires
    /// an authenticated session; returns [`JellifyError::NotAuthenticated`]
    /// if no `user_id` is set.
    ///
    /// `paging.offset` maps to Jellyfin's `startIndex` so callers can page
    /// deeper into the hint list ("Show more" in the typeahead). The
    /// returned `total_record_count` is the server-side unpaged total and
    /// is stable across pages for the same query.
    pub async fn search_hints(&self, query: &str, paging: Paging) -> Result<SearchHintResults> {
        let user_id = self
            .user_id
            .as_ref()
            .ok_or(JellifyError::NotAuthenticated)?;
        let mut url = self.endpoint("Search/Hints")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("userId", user_id);
            q.append_pair("searchTerm", query);
            q.append_pair("includeItemTypes", "Audio,MusicAlbum,MusicArtist,Playlist");
            q.append_pair("limit", &paging.limit.max(1).to_string());
            q.append_pair("startIndex", &paging.offset.to_string());
        }
        let resp = self
            .http
            .get(url)
            .headers(self.build_headers()?)
            .send()
            .await?;
        let raw: RawSearchHintResults = Self::check(resp).await?.json().await?;
        Ok(SearchHintResults {
            search_hints: raw.search_hints.into_iter().map(SearchHint::from).collect(),
            total_record_count: raw.total_record_count,
        })
    }

    // ----- Playback reporting -----

    /// Report that playback of an item has stopped.
    ///
    /// Backed by `POST /Sessions/Playing/Stopped` with body
    /// `{ItemId, PositionTicks}`. Drives Jellyfin's server-side PlayCount
    /// increment (for tracks) — the server treats a stop report with
    /// `PositionTicks` near `RunTimeTicks` as a completed play.
    ///
    /// Callers invoke this on track end, user-driven skip, and app quit.
    /// Pass the full `RunTimeTicks` as `position_ticks` when a song
    /// completed normally.
    ///
    /// Requires an authenticated session; returns
    /// [`JellifyError::NotAuthenticated`] if no token is set.
    pub async fn report_playback_stopped(&self, item_id: &str, position_ticks: i64) -> Result<()> {
        self.token.as_ref().ok_or(JellifyError::NotAuthenticated)?;
        let url = self.endpoint("Sessions/Playing/Stopped")?;
        let body = PlaybackStoppedBody {
            item_id: item_id.to_string(),
            position_ticks,
        };
        let resp = self
            .http
            .post(url)
            .headers(self.build_headers()?)
            .json(&body)
            .send()
            .await?;
        Self::check(resp).await?;
        Ok(())
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
    ///
    /// Retained for backwards compatibility; delegates to
    /// [`JellyfinClient::image_url_of_type`] with `ImageType::Primary`.
    pub fn image_url(&self, item_id: &str, tag: Option<&str>, max_width: u32) -> Result<Url> {
        self.image_url_of_type(
            item_id,
            ImageType::Primary,
            None,
            tag,
            Some(max_width),
            None,
        )
    }

    /// Build a Jellyfin image URL for any [`ImageType`].
    ///
    /// Endpoint: `GET /Items/{id}/Images/{type}/{index?}` with optional query
    /// parameters `maxWidth`, `maxHeight`, `quality`, and `tag`. `index` is
    /// meaningful for types that are keyed (notably `Backdrop`, which has one
    /// URL per entry in `BackdropImageTags`).
    pub fn image_url_of_type(
        &self,
        item_id: &str,
        image_type: ImageType,
        index: Option<u32>,
        tag: Option<&str>,
        max_width: Option<u32>,
        max_height: Option<u32>,
    ) -> Result<Url> {
        let path = match index {
            Some(i) => format!("Items/{item_id}/Images/{}/{i}", image_type.as_path()),
            None => format!("Items/{item_id}/Images/{}", image_type.as_path()),
        };
        let mut url = self.endpoint(&path)?;
        {
            let mut q = url.query_pairs_mut();
            if let Some(w) = max_width {
                q.append_pair("maxWidth", &w.to_string());
            }
            if let Some(h) = max_height {
                q.append_pair("maxHeight", &h.to_string());
            }
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

#[derive(Serialize)]
struct PlaybackProgressBody {
    #[serde(rename = "ItemId")]
    item_id: String,
    #[serde(rename = "PositionTicks")]
    position_ticks: i64,
    #[serde(rename = "IsPaused")]
    is_paused: bool,
}

#[derive(Serialize)]
struct PlaybackStoppedBody {
    #[serde(rename = "ItemId")]
    item_id: String,
    #[serde(rename = "PositionTicks")]
    position_ticks: i64,
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
    #[serde(rename = "Path")]
    pub path: Option<String>,
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

#[derive(Debug, Deserialize)]
struct RawSearchHintResults {
    #[serde(rename = "SearchHints", default)]
    search_hints: Vec<RawSearchHint>,
    #[serde(rename = "TotalRecordCount", default)]
    total_record_count: u32,
}

#[derive(Debug, Deserialize)]
struct RawSearchHint {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name", default)]
    name: String,
    #[serde(rename = "Type")]
    kind: Option<String>,
    #[serde(rename = "MediaType")]
    media_type: Option<String>,
    #[serde(rename = "Album")]
    album: Option<String>,
    #[serde(rename = "AlbumId")]
    album_id: Option<String>,
    #[serde(rename = "AlbumArtist")]
    album_artist: Option<String>,
    #[serde(rename = "MatchedTerm")]
    matched_term: Option<String>,
    #[serde(rename = "PrimaryImageTag")]
    primary_image_tag: Option<String>,
    #[serde(rename = "ProductionYear")]
    production_year: Option<i32>,
    #[serde(rename = "IndexNumber")]
    index_number: Option<u32>,
    #[serde(rename = "ParentIndexNumber")]
    parent_index_number: Option<u32>,
    #[serde(rename = "RunTimeTicks")]
    run_time_ticks: Option<u64>,
    #[serde(rename = "Artists", default)]
    artists: Vec<String>,
    #[serde(rename = "IsFolder")]
    is_folder: Option<bool>,
}

impl From<RawSearchHint> for SearchHint {
    fn from(r: RawSearchHint) -> Self {
        SearchHint {
            id: r.id,
            name: r.name,
            kind: r.kind,
            media_type: r.media_type,
            album: r.album,
            album_id: r.album_id,
            album_artist: r.album_artist,
            matched_term: r.matched_term,
            primary_image_tag: r.primary_image_tag,
            production_year: r.production_year,
            index_number: r.index_number,
            parent_index_number: r.parent_index_number,
            runtime_ticks: r.run_time_ticks,
            artists: r.artists,
            is_folder: r.is_folder,
        }
    }
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

impl From<RawItem> for Playlist {
    fn from(r: RawItem) -> Self {
        Playlist {
            id: r.id,
            name: r.name,
            track_count: r.child_count.unwrap_or(0),
            runtime_ticks: r.runtime_ticks,
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
