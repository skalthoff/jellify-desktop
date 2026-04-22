# Jellyfin API Coverage Roadmap — Jellify Desktop (Rust `JellyfinClient`)

Scope: endpoints the desktop client needs beyond the current
(`public_info`, `authenticate_by_name`, `artists`, `albums`, `album_tracks`,
`search`, `stream_url`, `auth_header_value`, `image_url`).

Authoritative sources consulted:
- `/Users/skalthoff/Code/active/openSourceWork/workspaces/jellyfin/Jellyfin.Api/Controllers/` — route attributes show canonical paths.
- `/Users/skalthoff/Code/active/openSourceWork/workspaces/jellify/src/api/{queries,mutations}/` — shows what a mature music client actually hits and the parameter shapes.

Conventions:
- `Labels`: `area:core` = Rust client; `area:api` = wire/model type; `area:ui` = consumer screens; `kind:feat|fix|refactor|infra`; priority `p0` ship-blocker for MVP music client, `p1` core feature parity, `p2` polish.
- Effort: **S** ≤1 day, **M** 1–3 days, **L** ≥3 days.
- All methods assume `&self` with `self.user_id` and `self.token` already set via `authenticate_by_name`.
- Canonical parent-ID is `library.musicLibraryId` (the `MusicLibrary` CollectionFolder). Several issues depend on resolving that once — see Issue 35.

---

## Domain: Playlists

### Issue 1: Add `list_playlists` (user-owned and public)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S
**Depends on:** Issue 35 (resolve `playlistLibraryId`)

- Endpoint: `GET /Items` with `parentId={playlistLibraryId}&userId=...&includeItemTypes=Playlist&Fields=ChildCount,Genres,Path`.
  - Jellify splits user-owned (Path contains `/data/`) vs public (does not). Controller: `UserViewsController` → `/UserViews` to discover `CollectionType=="playlists"`, then `ItemsController.GetItems`.
- Returns: `{ Items: BaseItemDto[], TotalRecordCount }`.
- Client methods:
  - `pub async fn user_playlists(&self, paging: Paging) -> Result<Vec<Playlist>>`
  - `pub async fn public_playlists(&self, paging: Paging) -> Result<Vec<Playlist>>`
- Consumers: Playlists sidebar section; Home "Your Playlists" row; Discover "Community Playlists".
- Acceptance: Returns `Vec<Playlist>` with `track_count` populated (`ChildCount`), paginates via offset, empty vec when none.

### Issue 2: Add `playlist_tracks`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `GET /Items?ParentId={playlistId}&IncludeItemTypes=Audio&Fields=MediaSources,ParentId,Path,SortName`. Controller: `ItemsController.GetItems` (preserves playlist order — do NOT pass `SortBy`).
- Returns: `{ Items: BaseItemDto[] }`.
- Client method: `pub async fn playlist_tracks(&self, playlist_id: &str, paging: Paging) -> Result<Vec<Track>>`.
- Consumers: Playlist detail screen; "Play playlist" action in sidebar context menu.
- Acceptance: Order matches server playlist order; track `ListItemId` retained for remove/reorder if needed (add to `Track` or sibling type).

### Issue 3: Add `create_playlist`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `POST /Playlists` with JSON `{ Name, Ids: string[], UserId, MediaType: "Audio", IsPublic }`. Controller: `PlaylistsController.CreatePlaylist` (line 75).
- Returns: `PlaylistCreationResult { Id }`.
- Client method: `pub async fn create_playlist(&self, name: &str, item_ids: &[String], is_public: bool) -> Result<Playlist>`.
- Consumers: "New Playlist" dialog; "Add to playlist → New…" from track/album/artist context menus.
- Acceptance: Returns the new playlist ID (refetched via `fetch_item` to populate full `Playlist`).

### Issue 4: Add `add_to_playlist`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `POST /Playlists/{playlistId}/Items?Ids=id1,id2&UserId=...`. Controller: `PlaylistsController` line 367. Accepts comma-separated `Ids`.
- Returns: 204.
- Client method: `pub async fn add_to_playlist(&self, playlist_id: &str, item_ids: &[String]) -> Result<()>`.
- Consumers: Track/album/artist "Add to playlist" context menu; drag-drop onto a playlist in sidebar.
- Acceptance: Accepts batch adds (mirrors Jellify's `addManyToPlaylist`); invalidates `playlist_tracks` cache in callers.

### Issue 5: Add `remove_from_playlist`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `DELETE /Playlists/{playlistId}/Items?EntryIds=eid1,eid2`. Controller line 443. Note: `EntryIds` are playlist-entry IDs (`PlaylistItemId` on each returned item), not item IDs.
- Returns: 204.
- Client method: `pub async fn remove_from_playlist(&self, playlist_id: &str, entry_ids: &[String]) -> Result<()>`.
- Consumers: Playlist detail right-click "Remove"; multi-select remove.
- Acceptance: Requires exposing `PlaylistItemId` in a `PlaylistTrack` struct or enriching `Track` (new field `playlist_entry_id: Option<String>`). Update `playlist_tracks` to parse `PlaylistItemId`.

### Issue 6: Add `move_playlist_item`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `POST /Playlists/{playlistId}/Items/{itemId}/Move/{newIndex}`. Controller line 405. `{itemId}` here is the **PlaylistItemId** (entry id).
- Returns: 204.
- Client method: `pub async fn move_playlist_item(&self, playlist_id: &str, entry_id: &str, new_index: u32) -> Result<()>`.
- Consumers: Drag-to-reorder in playlist detail screen.
- Acceptance: Order persists server-side; call followed by refetch or optimistic swap.

### Issue 7: Add `update_playlist` (rename + reset order)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `POST /Playlists/{playlistId}` with `UpdatePlaylistDto { Name?, Ids?, IsPublic?, Users? }`. Controller line 116.
- Returns: 204.
- Client method: `pub async fn update_playlist(&self, playlist_id: &str, name: Option<&str>, item_ids: Option<&[String]>, is_public: Option<bool>) -> Result<()>`.
- Consumers: "Rename playlist" dialog; "Make public/private" toggle.
- Acceptance: Name-only update works without clobbering track list.

### Issue 8: Add `delete_playlist`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `DELETE /Items/{itemId}` (playlists are regular items). Controller: `LibraryController.DeleteItem` line 356.
- Returns: 204.
- Client method: `pub async fn delete_playlist(&self, playlist_id: &str) -> Result<()>`.
- Consumers: Sidebar right-click "Delete playlist"; playlist header kebab menu.
- Acceptance: Server returns 204; downstream cache invalidation is caller's job.

### Issue 9: Add playlist collaborator endpoints (share with user)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** M
**Depends on:** Issue 1

- Endpoints:
  - `GET /Playlists/{id}/Users` (line 194) → `Vec<PlaylistUserPermissions>`.
  - `POST /Playlists/{id}/Users/{userId}` body `UpdatePlaylistUserDto { CanEdit }` (line 276).
  - `DELETE /Playlists/{id}/Users/{userId}` (line 322).
- Client methods: `playlist_collaborators`, `add_playlist_collaborator(playlist_id, user_id, can_edit)`, `remove_playlist_collaborator`.
- Consumers: Playlist "Sharing" dialog in playlist header.
- Acceptance: Covers 3-tier perms model (owner / editor / viewer).

---

## Domain: Favorites & Ratings

### Issue 10: Add `set_favorite` / `unset_favorite`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoints: `POST /UserFavoriteItems/{itemId}` and `DELETE /UserFavoriteItems/{itemId}` (preferred; current user inferred from token). Legacy variant `/Users/{userId}/FavoriteItems/{itemId}` also works. Controller: `UserLibraryController` lines 213, 260.
- Returns: `UserItemDataDto`.
- Client methods:
  - `pub async fn set_favorite(&self, item_id: &str) -> Result<UserItemData>`
  - `pub async fn unset_favorite(&self, item_id: &str) -> Result<UserItemData>`
- Consumers: Heart icon on track row, album header, artist header, Now Playing bar. Must work on tracks, albums, artists, playlists (any `BaseItemDto`).
- Acceptance: Returns updated `UserItemData` so UI can reflect `is_favorite` without refetch.

### Issue 11: Add `set_item_rating`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `POST /UserItems/{itemId}/Rating?likes=true|false` (controller line 355) and `DELETE /UserItems/{itemId}/Rating` (line 307) to clear.
- Returns: `UserItemDataDto`.
- Client methods: `set_rating(item_id, likes: bool)`, `clear_rating(item_id)`.
- Consumers: Thumb up/down on track context menu (stretch feature).
- Acceptance: Thumb state round-trips correctly; reflected in `UserItemData.Likes`.

### Issue 12: Add `user_item_data` (read)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /UserItems/{itemId}/UserData` (controller `ItemsController` line 967).
- Returns: `UserItemDataDto { IsFavorite, Played, PlayCount, PlaybackPositionTicks, LastPlayedDate, Likes, Rating }`.
- Client method: `pub async fn user_item_data(&self, item_id: &str) -> Result<UserItemData>`.
- Consumers: Per-item heart/played state after navigation where list didn't include `UserData` field; resume from "Continue listening".
- Acceptance: Add `UserItemData` model record (see Issue 39).

### Issue 13: Add `update_user_item_data`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `POST /UserItems/{itemId}/UserData` body `UpdateUserItemDataDto { Played?, LastPlayedDate?, PlaybackPositionTicks?, IsFavorite?, Likes?, Rating? }` (controller line 1022).
- Returns: 200.
- Client method: `pub async fn update_user_item_data(&self, item_id: &str, patch: UserItemDataPatch) -> Result<()>`.
- Consumers: Manually mark album/playlist as played (Jellify uses this for non-tracks — the server only auto-tracks track playback).
- Acceptance: Patch struct uses `Option` for partial updates.

---

## Domain: Play State (Mark Played/Unplayed)

### Issue 14: Add `mark_played` / `mark_unplayed`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoints: `POST /UserPlayedItems/{itemId}?datePlayed=...` (controller `PlaystateController` line 72) and `DELETE /UserPlayedItems/{itemId}` (line 138).
- Returns: `UserItemDataDto`.
- Client methods: `mark_played(item_id, date_played: Option<DateTime<Utc>>)`, `mark_unplayed(item_id)`.
- Consumers: Track/album context menu "Mark as played/unplayed".
- Acceptance: Affects PlayCount; reflected in `UserItemData`.

---

## Domain: Playback Reporting (Now Playing sync)

### Issue 15: Add `report_playback_started`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** M

- Endpoint: `POST /Sessions/Playing` with `PlaybackStartInfo { ItemId, SessionId, PositionTicks?, PlayMethod, MediaSourceId, AudioStreamIndex?, PlaybackStartTimeTicks, CanSeek, IsPaused, IsMuted, VolumeLevel?, PlaylistIndex?, PlaylistLength? }` (controller line 199).
- Returns: 204.
- Client method: `pub async fn report_playback_started(&self, info: PlaybackStartInfo) -> Result<()>`.
- Consumers: Called by `core::player` on track load so Jellyfin Web shows "Now playing on macOS" for this device.
- Acceptance: Introduces new `PlaybackStartInfo` wire struct; `SessionId` obtained from `/Sessions` or post-capabilities response (see Issue 32).

### Issue 16: Add `report_playback_progress`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S
**Depends on:** Issue 15

- Endpoint: `POST /Sessions/Playing/Progress` with `PlaybackProgressInfo { ItemId, SessionId, PositionTicks, IsPaused, IsMuted, VolumeLevel, PlayMethod, ... }` (controller line 215). Jellify calls this ~every 10s during playback.
- Returns: 204.
- Client method: `pub async fn report_playback_progress(&self, info: PlaybackProgressInfo) -> Result<()>`.
- Consumers: Player engine heartbeat; updates remote Now Playing state.
- Acceptance: Works for pause/resume/seek state transitions; tolerates network flake (log, don't propagate failure).

### Issue 17: Add `report_playback_stopped`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S
**Depends on:** Issue 15

- Endpoint: `POST /Sessions/Playing/Stopped` with `PlaybackStopInfo { ItemId, SessionId, PositionTicks, Failed?, NextMediaType?, PlaylistItemId? }` (controller line 245).
- Returns: 204.
- Client method: `pub async fn report_playback_stopped(&self, info: PlaybackStopInfo) -> Result<()>`.
- Consumers: On track end, skip, and app quit. This endpoint is what drives Jellyfin's PlayCount increment (for tracks only — playlists/albums need Issue 13).
- Acceptance: Final `PositionTicks` = full RunTimeTicks when song completed normally.

### Issue 18: Add `report_playback_ping` (keep-alive)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `POST /Sessions/Playing/Ping?playSessionId=...` (controller line 231). Used by the server to keep a transcoding job alive.
- Returns: 204.
- Client method: `pub async fn ping_playback(&self, play_session_id: &str) -> Result<()>`.
- Consumers: Only needed if we end up using the transcoding pipeline for remote streams.
- Acceptance: No-op safe when not transcoding; timer-driven if used.

---

## Domain: Playback Info / Media Sources

### Issue 19: Add `playback_info` (POST — canonical)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** M

- Endpoint: `POST /Items/{itemId}/PlaybackInfo` body `PlaybackInfoDto { UserId?, StartTimeTicks?, MediaSourceId?, DeviceProfile: DeviceProfile, EnableDirectStream?, EnableDirectPlay?, EnableTranscoding?, MaxStreamingBitrate?, AutoOpenLiveStream? }` (controller `MediaInfoController` line 116). POST variant is what the Jellyfin SDK uses (Jellify's `fetchMediaInfo`).
- Returns: `PlaybackInfoResponse { MediaSources: MediaSourceInfo[], PlaySessionId, ErrorCode? }`. Each `MediaSourceInfo` has `Id, Path, Container, Bitrate, SupportsDirectPlay, SupportsDirectStream, SupportsTranscoding, TranscodingUrl, TranscodingSubProtocol, MediaStreams[]`.
- Client method: `pub async fn playback_info(&self, item_id: &str, profile: &DeviceProfile, start_position_ticks: Option<u64>) -> Result<PlaybackInfoResponse>`.
- Consumers: Before every stream, to decide direct-stream vs transcode and to obtain `PlaySessionId` (fed to Issue 15/18). Replaces the current best-effort `stream_url` for anything non-MP3.
- Acceptance: Device profile encodes AVFoundation/CoreAudio capabilities. Use response's `TranscodingUrl` when present; otherwise build direct URL from `Path`/`Container`.

### Issue 20: Move `stream_url` to use `PlaybackInfo` result
**Labels:** `area:core`, `kind:refactor`, `priority:p1`
**Effort:** M
**Depends on:** Issue 19

- Current `stream_url` hardcodes `Container` and `AudioCodec` advertised to `/Audio/{id}/universal`. Replace with: call `playback_info` first, pick the first supported `MediaSource`, then either direct-stream from `MediaSources[0].Path`/universal with `MediaSourceId` pinned, or transcode via the returned `TranscodingUrl`.
- Client method: `pub async fn prepare_stream(&self, item_id: &str) -> Result<StreamPlan>` returning `{ url, play_session_id, media_source_id, is_transcoding, content_type_hint }`.
- Consumers: Player engine.
- Acceptance: Direct-streams natively decoded containers (FLAC/ALAC/MP3/AAC/Opus); transparently falls back to MP3 transcode for WavPack, DSF, etc.

### Issue 21: Add `open_live_stream` / `close_live_stream`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** M

- Endpoints: `POST /LiveStreams/Open` (controller line 269) and `POST /LiveStreams/Close` (line 314). Needed when `PlaybackInfoResponse` returns a `LiveStreamId` requiring explicit open.
- Client methods: `open_live_stream`, `close_live_stream`.
- Consumers: Player engine — only exercised when server hands us a live stream handle.
- Acceptance: Works with HLS transcodes that require explicit session setup.

---

## Domain: Instant Mix / Suggestions / Similar

### Issue 22: Add `instant_mix` (polymorphic)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoints (controller `InstantMixController`):
  - `/Items/{id}/InstantMix` (generic; line 276)
  - `/Artists/{id}/InstantMix` (line 233)
  - `/Albums/{id}/InstantMix` (line 112)
  - `/Songs/{id}/InstantMix` (line 69)
  - `/Playlists/{id}/InstantMix` (line 155)
  - `/MusicGenres/{name}/InstantMix` (line 197)
  - All accept `userId, limit, fields, enableUserData`.
- Returns: `{ Items: BaseItemDto[] }` of `Audio` items.
- Client methods: single polymorphic `pub async fn instant_mix(&self, item_id: &str, limit: u32) -> Result<Vec<Track>>` using `/Items/{id}/InstantMix` (works for any item kind); optional specialized variants for callers that want them.
- Consumers: Context menu "Start Radio" on track/album/artist/genre; Now Playing "More like this" shelf.
- Acceptance: Seeds a new queue. Jellify calls `getInstantMixFromArtists` indiscriminately, which is technically wrong but works — use the generic endpoint instead.

### Issue 23: Add `suggestions`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /Items/Suggestions?userId=...&mediaType=Audio&type=MusicAlbum,MusicArtist&limit=12` (controller `SuggestionsController` line 59).
- Returns: `{ Items: BaseItemDto[], TotalRecordCount }`.
- Client method: `pub async fn suggestions(&self, media_types: &[&str], types: &[&str], limit: u32) -> Result<Vec<Item>>`.
- Consumers: Home "You might like" row.
- Acceptance: Server-driven; more useful than `recently_added` for long-tail discovery.

### Issue 24: Add `similar_artists` / `similar_albums` / `similar_items`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoints (controller `LibraryController` line 728):
  - `GET /Artists/{id}/Similar?userId=...&limit=12`
  - `GET /Albums/{id}/Similar?userId=...&limit=12`
  - `GET /Items/{id}/Similar` (generic fallback)
- Returns: `{ Items: BaseItemDto[] }`.
- Client methods: `similar_artists(artist_id, limit)`, `similar_albums(album_id, limit)`.
- Consumers: Artist detail "Fans also like" row; Album detail "Similar albums" row.
- Acceptance: Server uses tag/genre similarity — reasonable even on modest libraries.

---

## Domain: Discovery / Home / Recents / Frequents

### Issue 25: Add `latest_items` (Recently Added)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `GET /Items/Latest?userId=...&parentId={musicLibraryId}&includeItemTypes=MusicAlbum&limit=24&groupItems=true` (controller `UserLibraryController` line 522).
- Returns: `BaseItemDto[]` (not wrapped).
- Client method: `pub async fn latest_albums(&self, limit: u32) -> Result<Vec<Album>>` (filter to `MusicAlbum`). Add overload `latest_items(types, limit)` for Audio too if needed.
- Consumers: Home "Recently Added" row.
- Acceptance: Results respect user's parental controls; grouped by album.

### Issue 26: Add `recently_played_tracks`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `GET /Items?includeItemTypes=Audio&parentId={musicLibraryId}&recursive=true&sortBy=DatePlayed&sortOrder=Descending&fields=ParentId&limit=50`.
- Returns: `{ Items: BaseItemDto[], TotalRecordCount }`.
- Client method: `pub async fn recently_played(&self, paging: Paging) -> Result<Vec<Track>>`.
- Consumers: Home "Recently Played" row (Jellify collapses to album when 3+ tracks from same album — do this client-side).
- Acceptance: Only returns tracks with `UserData.LastPlayedDate != null` implicitly via `DatePlayed` sort.

### Issue 27: Add `frequently_played_tracks`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /Items?includeItemTypes=Audio&parentId={musicLibraryId}&recursive=true&sortBy=PlayCount&sortOrder=Descending&limit=50`.
- Returns: `{ Items: BaseItemDto[] }`.
- Client method: `pub async fn frequently_played(&self, paging: Paging) -> Result<Vec<Track>>`.
- Consumers: Home "Play It Again" / "On Repeat" row.
- Acceptance: Sorted by server-side PlayCount.

### Issue 28: Add `resume_items`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `GET /UserItems/Resume?mediaTypes=Audio&limit=12` (controller line 823). Audio is rarely long enough to resume — keep as p2.
- Returns: `{ Items }`.
- Client method: `pub async fn resume_items(&self) -> Result<Vec<Track>>`.
- Consumers: Home "Continue listening" row (only meaningful for audiobooks/long mixes).
- Acceptance: Populates `playback_position_seconds` on returned tracks.

---

## Domain: Genres / Years / Filters

### Issue 29: Add `genres`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /MusicGenres?parentId={musicLibraryId}&userId=...&fields=ItemCounts` (controller `MusicGenresController` line 73). The plain `/Genres` controller is obsolete for music.
- Returns: `{ Items: BaseItemDto[] }` with `ChildCount`/`SongCount`/`AlbumCount`.
- Client method: `pub async fn genres(&self, paging: Paging) -> Result<Vec<Genre>>` (new `Genre { id, name, song_count, album_count, image_tag }` model).
- Consumers: Genres tab; genre filter dropdown.
- Acceptance: Counts populated; paginates.

### Issue 30: Add `items_by_genre`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /Items?genreIds=...&includeItemTypes=MusicAlbum|Audio|MusicArtist&...`. Same `ItemsController.GetItems` with `GenreIds` param.
- Client methods: `albums_by_genre(genre_id, paging)`, `tracks_by_genre(genre_id, paging)`, `artists_by_genre(genre_id, paging)`.
- Consumers: Genre detail screen.
- Acceptance: Filter composes with existing `albums`/`artists`/`tracks` — consider refactoring to builder: Issue 38.

### Issue 31: Add `library_years`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `GET /Items/Filters?userId=...&parentId={musicLibraryId}&includeItemTypes=MusicAlbum` (controller `FilterController` line 48). Returns `ItemFilters { Genres, Years, Tags, OfficialRatings }`.
- Client method: `pub async fn library_years(&self) -> Result<Vec<u32>>` (extract `Years`, sorted ascending).
- Consumers: Year-range slider on Albums tab.
- Acceptance: Works for music albums; Jellify matches this exactly.

### Issue 32: Add `items_filters` (generic) and composable filters
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** M

- Endpoints: `GET /Items/Filters` (generic, above) and `GET /Items/Filters2` (controller line 135, `QueryFiltersLegacy` vs `QueryFilters`).
- Client method: `pub async fn filters(&self, parent_id: &str, types: &[&str]) -> Result<LibraryFilters>` returning `{ genres, years, tags, official_ratings }`.
- Consumers: Powers Genres tab, Years tab, Tags filter.
- Acceptance: Single call populates all filter pickers.

---

## Domain: Metadata (Artist / Album / Track detail)

### Issue 33: Add `fetch_item` (single-item lookup with rich fields)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `GET /Items?ids={id}&fields=Overview,Genres,Tags,ProductionYear,Studios,ProviderIds,People,ExternalUrls,ParentId,SortName,ChildCount,MediaSources`. Jellify's `fetchItem` uses `ids=` to work around `/Users/{userId}/Items/{itemId}` deprecation noise.
- Returns: `{ Items: [BaseItemDto] }`.
- Client method: `pub async fn fetch_item(&self, item_id: &str, fields: &[&str]) -> Result<RawItem>` — return raw shape so callers pick what they need.
- Consumers: Navigating to an item via deep-link/context; priming artist/album detail screen.
- Acceptance: Returns a single item; propagates server errors.

### Issue 34: Add `artist_detail` (bio, overview, image tags)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /Items?ids={id}&fields=Overview,Genres,Tags,ProviderIds,ExternalUrls,ImageTags,BackdropImageTags` (via Issue 33) OR `GET /Artists/{name}?userId=...` (controller `ArtistsController` line 463 — looks up by name).
- Returns: artist `BaseItemDto` with `Overview` (bio), `ExternalUrls` (MusicBrainz, LastFM, Discogs), `BackdropImageTags[]`.
- Client method: extend `Artist` model with `overview`, `backdrop_image_tags`, `external_urls: Vec<ExternalUrl>`; add `pub async fn artist_detail(&self, artist_id: &str) -> Result<ArtistDetail>`.
- Consumers: Artist detail header (bio, backdrop), external-link icons.
- Acceptance: `overview` rendered as plain text or HTML-stripped markdown; backdrops chosen via `image_url_of_type`.

### Issue 35: Add library resolution (`/UserViews` + playlist library)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoints:
  - `GET /UserViews?userId=...` → all user views (controller `UserViewsController` line 64). Filter `CollectionType == "music"` for the `musicLibraryId`.
  - `GET /Items?userId=...&includeItemTypes=ManualPlaylistsFolder&excludeItemTypes=CollectionFolder`, filter `CollectionType == "playlists"` — gives `playlistLibraryId`.
- Client methods:
  - `pub async fn user_views(&self) -> Result<Vec<Library>>` (`Library { id, name, collection_type }`).
  - `pub async fn music_library_id(&self) -> Result<String>` (cached; called once post-auth).
  - `pub async fn playlist_library_id(&self) -> Result<String>`.
- Consumers: Every query scoped to music (Albums/Artists/Tracks/Genres/Years); dep of nearly every issue above.
- Acceptance: Cache results on `JellyfinClient` after first call; invalidate on re-auth.

### Issue 36: Add `album_detail` (rich metadata)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S
**Depends on:** Issue 33

- Uses `fetch_item` with `fields=Overview,Studios,Tags,ProviderIds,ProductionLocations,OfficialRating,PremiereDate`.
- Client method: extend `Album` struct or add `AlbumDetail { album: Album, overview, studios, tags, provider_ids, premiere_date }`.
- Consumers: Album detail header; MusicBrainz/Spotify deep-links.
- Acceptance: `provider_ids` keyed by `"MusicBrainzAlbum"`, `"MusicBrainzReleaseGroup"`, `"Spotify"`, etc.

### Issue 37: Add `album_discs` helper (grouped by disc)
**Labels:** `area:core`, `kind:feat`, `priority:p2`
**Effort:** S

- Server-side: same `album_tracks` endpoint but group by `ParentIndexNumber` client-side (Jellify's `fetchAlbumDiscs`).
- Client method: `pub async fn album_discs(&self, album_id: &str) -> Result<Vec<Disc>>` where `Disc { number, tracks }`.
- Consumers: Album detail screen rendering of multi-disc releases.
- Acceptance: Single disc returns one `Disc { number: 1, tracks }`.

---

## Domain: Search

### Issue 38: Add `search_hints` (preferred fast-search)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** S

- Endpoint: `GET /Search/Hints?searchTerm=...&includeItemTypes=Audio,MusicAlbum,MusicArtist,Playlist&limit=24&userId=...` (controller `SearchController` line 79).
- Returns: `SearchHintResult { SearchHints: SearchHint[], TotalRecordCount }`. `SearchHint` is a trimmed DTO with `Id, Name, Type, MediaType, AlbumArtist, Album, PrimaryImageTag, MatchedTerm`.
- Client method: `pub async fn search_hints(&self, query: &str, limit: u32) -> Result<SearchHintResults>`.
- Consumers: Omnibox/global search in header; should replace current `/Users/{id}/Items?searchTerm=` flow for typeahead.
- Acceptance: Keep current `search` as full-results fallback; `search_hints` is the debounced typeahead call.

### Issue 39: Refactor `search` to use typed item-kind filter
**Labels:** `area:core`, `kind:refactor`, `priority:p1`
**Effort:** S

- Extend current `search` signature: `pub async fn search(&self, query: &str, kinds: &[ItemKind], limit: u32, offset: u32) -> Result<SearchResults>` where `ItemKind` is an enum (Artist, Album, Track, Playlist).
- Consumers: Full search results screen with segmented tabs.
- Acceptance: Backwards-compatible call-site wrapper; adds offset for "Load more".

---

## Domain: Images (beyond Primary)

### Issue 40: Generalize `image_url` to any `ImageType`
**Labels:** `area:core`, `kind:refactor`, `priority:p0`
**Effort:** S

- Endpoint pattern: `GET /Items/{id}/Images/{type}/{index?}?maxWidth=&maxHeight=&quality=&tag=&fillHeight=&fillWidth=&blur=` (controller `ImageController`, routes defined for every `ImageType`).
- Client method: `pub fn image_url_of_type(&self, item_id: &str, image_type: ImageType, index: Option<u32>, tag: Option<&str>, max_width: Option<u32>, max_height: Option<u32>) -> Result<Url>`. `ImageType` enum: `Primary, Backdrop, Thumb, Disc, Logo, Banner, Art, Box`.
- Consumers: Artist backdrop (uses `Backdrop` with `backdrop_image_tags[i]`); album disc art; playlist cover (uses `Primary`); Now Playing full-screen uses `Backdrop` fallback to `Primary`.
- Acceptance: Current `image_url` keeps working; new method used where needed.

### Issue 41: Add URL helper for artist photo with fallback chain
**Labels:** `area:core`, `kind:feat`, `priority:p1`
**Effort:** S

- Helper that mirrors Jellify's `getItemImageUrl`: prefer item's own image, fall back to `AlbumPrimaryImageTag`, then first `AlbumArtists[0].Id`/`ArtistItems[0].Id` primary.
- Client method: `pub fn track_artwork_url(&self, track: &Track, max: u32) -> Option<Url>`.
- Consumers: Track row thumbnails (some tracks have per-track art, most inherit from album).
- Acceptance: Never returns 404 for a track that has any derivable artwork.

---

## Domain: Lyrics

### Issue 42: Add `lyrics`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /Audio/{itemId}/Lyrics` (controller `LyricsController` line 67).
- Returns: `LyricDto { Metadata: { Artist, Album, Title, Author, Length, Offset, IsSynced, ... }, Lyrics: LyricLine[] { Start: number (ticks), Text: string } }`.
- Client method: `pub async fn lyrics(&self, item_id: &str) -> Result<Option<Lyrics>>`. New `Lyrics { is_synced, lines: Vec<LyricLine { time_seconds, text }> }`. Return `Ok(None)` for 404 (no lyrics available — common).
- Consumers: Now Playing lyrics pane with karaoke-style highlighting (need synced lyrics via `is_synced`).
- Acceptance: Handles both timed LRC (`IsSynced=true`) and plain text (single line, `Start=0`).

### Issue 43: Add lyrics remote search (stretch)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** M

- Endpoints: `GET /Audio/{itemId}/RemoteSearch/Lyrics` (line 176), `POST /Audio/{itemId}/RemoteSearch/Lyrics/{lyricId}` to apply (line 200).
- Client methods: `search_remote_lyrics(item_id)`, `apply_remote_lyrics(item_id, lyric_id)`.
- Consumers: "Find lyrics online" button when local lyrics missing.
- Acceptance: Requires user with `LyricManagement` policy — gate in UI.

---

## Domain: Downloads / Offline

### Issue 44: Add `download_item`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** M

- Endpoint: `GET /Items/{itemId}/Download` (controller `LibraryController` line 664). Returns original file bytes (400+ response modes depending on user policy).
- Client method: `pub async fn download_to<W: AsyncWrite>(&self, item_id: &str, writer: W) -> Result<u64>` streaming to disk to avoid buffering large FLACs.
- Consumers: "Download" context action; Offline Cache service.
- Acceptance: Honors user's `EnableContentDownloading` policy (see Issue 45 — returns 403 if disabled); writes Content-Length bytes.

### Issue 45: Add `current_user` / `user_policy`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /Users/Me` — not in v10.10; use `GET /Users/{userId}` (controller `UserController` line 127) with self ID. Returns `UserDto { Id, Name, ServerId, PrimaryImageTag, Policy: UserPolicy { IsAdministrator, EnableContentDownloading, MaxParentalRatingScore, AllowedTags, BlockedTags, EnabledChannels, ... }, Configuration }`.
- Client method: `pub async fn current_user(&self) -> Result<UserDetail>` returning user + policy (new `UserPolicy { can_download, is_admin, max_bitrate }`).
- Consumers: Hide Download button if `!can_download`; bitrate picker caps at `max_bitrate`; admin-only settings panels.
- Acceptance: Caches result; refreshes on re-auth.

---

## Domain: Server / System

### Issue 46: Add `server_info` (authenticated)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /System/Info` (controller `SystemController` line 67) — full server info (version, OS, hardware, paths).
- Returns: `SystemInfo { Version, ProductName, OperatingSystem, ProductName, Id, ... }`.
- Client method: `pub async fn server_info(&self) -> Result<SystemInfo>`.
- Consumers: Settings → "About Server" panel; capability detection (feature flag based on version).
- Acceptance: Distinguish from `public_info` (already implemented, `/System/Info/Public`).

### Issue 47: Add `ping`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `GET /System/Ping` or `POST /System/Ping` (line 102).
- Returns: `"Jellyfin Server"` plain text.
- Client method: `pub async fn ping(&self) -> Result<()>`.
- Consumers: Connection health indicator in status bar; reconnect loop.
- Acceptance: Light-weight; runs every N seconds when offline, on any network change.

### Issue 48: Add `endpoint_info`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `GET /System/Endpoint` (line 185).
- Returns: `EndPointInfo { IsLocal, IsInNetwork }`.
- Client method: `pub async fn endpoint_info(&self) -> Result<EndpointInfo>`.
- Consumers: Used to pick "local" vs remote bitrate caps on mobile; low value on desktop.
- Acceptance: Optional — skip if no time.

---

## Domain: Session / Capabilities

### Issue 49: Add `post_capabilities` (session registration)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** Issue 19

- Endpoint: `POST /Sessions/Capabilities/Full` body `ClientCapabilitiesDto { PlayableMediaTypes, SupportedCommands, SupportsMediaControl, SupportsPersistentIdentifier, DeviceProfile, AppStoreUrl, IconUrl }` (controller `SessionController` line 377).
- Returns: 204.
- Client method: `pub async fn post_capabilities(&self, caps: ClientCapabilities) -> Result<()>`.
- Consumers: Called after auth so the server knows we're a music playback target (enables remote control from Jellyfin Web, "Play on macOS").
- Acceptance: Must include full `DeviceProfile` with audio codec/container support (shared with Issue 19).

### Issue 50: Add `sessions` (for remote control discovery)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoint: `GET /Sessions?controllableByUserId=...&activeWithinSeconds=...` (controller `SessionController` line 52).
- Returns: `SessionInfo[]`.
- Client method: `pub async fn sessions(&self) -> Result<Vec<SessionInfo>>`.
- Consumers: "Play on another device" picker (advanced).
- Acceptance: Filter to non-self sessions with `SupportsRemoteControl`.

### Issue 51: Add `logout_session`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p1`
**Effort:** S

- Endpoint: `POST /Sessions/Logout` (line 419). Invalidates current token.
- Client method: `pub async fn logout(&mut self) -> Result<()>` (clears `self.token`, `self.user_id` on success).
- Consumers: Settings → "Sign out" button; also called on server switcher.
- Acceptance: `token`/`user_id` are `None` after call even if network fails (best-effort logout).

---

## Domain: Live Sync (WebSocket)

### Issue 52: Add `socket` client (library-updated, now-playing push)
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** L

- Endpoint: `GET /socket?api_key=...&deviceId=...` upgraded to WebSocket.
- Messages (from server): `Sessions` (all active sessions), `LibraryChanged { ItemsAdded, ItemsUpdated, ItemsRemoved, FoldersAddedTo, FoldersRemovedFrom }`, `UserDataChanged`, `Play` / `Playstate` / `GeneralCommand` (remote control).
- Client type: `pub struct JellyfinSocket` with `connect()`, `subscribe(&self, topic: SocketTopic)`, `next_event()` stream.
- Consumers: Invalidate cached album/artist lists on `LibraryChanged`; update Now Playing when another device plays; accept remote-control commands (play/pause/next).
- Acceptance: Reconnects with exponential backoff; gracefully disabled if server unreachable.

---

## Domain: Collections

### Issue 53: Add `create_collection` / `add_to_collection` / `remove_from_collection`
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p2`
**Effort:** S

- Endpoints (controller `CollectionController`):
  - `POST /Collections?name=...&ids=...&isLocked=true|false` (line 49).
  - `POST /Collections/{id}/Items?ids=...` (line 85).
  - `DELETE /Collections/{id}/Items?ids=...` (line 102).
- Client methods: `create_collection`, `add_to_collection`, `remove_from_collection`.
- Consumers: "Add to collection" context menu on albums/artists (user-curated boxsets).
- Acceptance: Requires `CollectionManagement` policy; gate in UI.

---

## Domain: Refactors / Infra

### Issue 54: Add typed enums for `ItemKind`, `ImageType`, `ItemSortBy`, `SortOrder`, `ItemField`
**Labels:** `area:core`, `kind:refactor`, `priority:p1`
**Effort:** S

- Rationale: current code passes raw strings for `IncludeItemTypes`, `SortBy`, `Fields`. Error-prone and bloats every call site. The Jellyfin SDK generates enums for these; mirror them.
- Introduce `src/wire.rs` or `src/enums.rs` with serde-renamed enums; update existing methods.
- Consumers: All API methods.
- Acceptance: No string literals for these params in `client.rs`.

### Issue 55: Introduce `ItemsQuery` builder
**Labels:** `area:core`, `kind:refactor`, `priority:p1`
**Effort:** M

- Most queries are `GET /Items` with varying params. Instead of a new method for each filter combo, build:
```rust
pub struct ItemsQuery { parent_id, user_id?, types, sort_by, sort_order, limit, offset,
    is_favorite, genre_ids, artist_ids, album_artist_ids, years, search_term, fields, ... }
impl ItemsQuery { pub fn fetch(&self, client: &JellyfinClient) -> Result<Items<RawItem>> }
```
- Client method: `pub fn items_query(&self) -> ItemsQuery` returning a fluent builder.
- Consumers: `albums`, `artists`, `album_tracks`, `tracks_by_genre`, `search`, `recently_played`, etc. all become thin wrappers.
- Acceptance: Removes duplicated URL-building code; keeps wrapper methods for discoverability.

### Issue 56: Add `DeviceProfile` model + default builder
**Labels:** `area:core`, `area:api`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** Issue 19

- `DeviceProfile` is a hefty DTO with `CodecProfiles[], ContainerProfiles[], DirectPlayProfiles[], TranscodingProfiles[], SubtitleProfiles[], MaxStaticBitrate, MaxStreamingBitrate, MusicStreamingTranscodingBitrate`.
- Provide a static `default_macos_profile()` advertising AVFoundation support: direct-play FLAC/ALAC/MP3/AAC/Opus/OGG/WAV; transcode everything else to MP3 320.
- Consumers: Issue 19, Issue 49.
- Acceptance: Single source of truth for what the desktop client can play; matches Jellify's streaming profile shape (see `src/stores/device-profile.ts`).

### Issue 57: Add `UserItemData` model and propagate into Album/Artist
**Labels:** `area:api`, `kind:refactor`, `priority:p1`
**Effort:** S

- Current `Track` has `is_favorite, play_count`. Album/Artist are missing equivalent fields despite being favoritable.
- Add `UserItemData { is_favorite, played, play_count, playback_position_seconds, last_played_at, likes, rating }` and add `user_data: Option<UserItemData>` to each model record.
- Acceptance: Single struct reused across all item types; drives heart/played UI uniformly.

### Issue 58: Add structured error mapping for auth vs rate-limit vs not-found
**Labels:** `area:core`, `kind:refactor`, `priority:p1`
**Effort:** S

- Current `JellifyError::Server { status, message }` is too coarse. Differentiate 401 (reauth needed), 403 (policy denied), 404 (missing), 429 (rate-limited), 5xx (retryable).
- Consumers: UI retry logic; automatic re-auth when token expires.
- Acceptance: Typed variants; public helper `is_retryable()`.

---

## Out-of-scope (music-client perspective)

- `/Shows/NextUp`, `/Videos/*`, `/Trailers/*`, `/LiveTv/*` — TV-only.
- `/Movies/Recommendations` — unused by music.
- `/Channels/*` — plugin-only.
- `/Sync/*` — deprecated in v10.9+ (Jellyfin removed sync endpoints; offline now via `/Items/{id}/Download` + client-side cache — covered by Issue 44).
- `/Shows/NextUp` — TV only; music clients roll their own (Issue 22 InstantMix covers the equivalent).
- "ListGenre/Style/Mood" — these are free-form `Tags` on items. Filter by passing `tags=` to `/Items`. Low priority; not a separate endpoint family.

---

## Suggested grouping for issue-tracker milestones

- **M1 — Playback MVP (p0):** 10, 15, 16, 17, 19, 20, 25, 26, 35, 38, 40, 45, 49, 56. (14 issues; unblocks end-to-end playback with Now Playing sync.)
- **M2 — Library parity (p1):** 1, 2, 3, 4, 5, 12, 14, 22, 23, 24, 27, 29, 30, 33, 34, 41, 42, 46, 47, 51, 54, 55, 57, 58.
- **M3 — Polish (p2):** 6, 7, 8, 9, 11, 13, 18, 21, 28, 31, 32, 36, 37, 43, 44, 48, 50, 52, 53.
