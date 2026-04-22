# UX Patterns Research — Jellify Desktop (macOS)

Research brief for building a polished, premium-feeling Jellyfin music client on macOS. This document extracts concrete, actionable patterns from shipping apps (Apple Music, Spotify, Doppler, Cider, Tidal, Marvis Pro) and translates them into specific GitHub issues.

Scope: interaction design, information architecture, and flow. Visual tokens (colors, type, spacing) are captured separately.

---

## Cross-cutting design principles

Before the section-by-section breakdown, the patterns that consistently separate premium music apps from generic ones:

1. **Album and artist are first-class**, not just metadata. The content (cover art, artist image) *is* the navigation.
2. **Right-click is load-bearing.** Context menus are where power lives; the primary UI stays clean.
3. **Queue is transparent and editable.** Users can see what's next, reorder it, clear the auto-fill, distinguish "I asked for this" from "the app chose this."
4. **Search is instant and categorized.** Results appear as you type, grouped by type, with a "Top Result" hero card.
5. **Keyboard navigation actually works.** Arrow keys through lists, Space for play/pause, Return to play selection, Cmd+F to focus search, Cmd+L to focus search results.
6. **Native touches compound.** Trackpad gestures, haptics (where applicable), proper window chrome, vibrancy, focus rings. Each one is small; absence of them all makes an app feel "Electron-y."
7. **Loading and empty states are authored, not placeholder.** Skeletons match the grid they replace; empty states explain what should be there and offer an action.
8. **Now Playing context is always surfaced.** "Playing from [Album / Playlist / Artist Radio]" persists so the user always knows why a track is queued.

Jellyfin exposes the metadata you need: `DatePlayed`, `PlayCount`, `UserData.IsFavorite`, `DateCreated` (added), `SortBy=DatePlayed|PlayCount|DateCreated|Random`, `/Genres`, `/Items` with `ParentId`, `/Playlists/{id}/Items`, `/Users/{userId}/Items/Latest`, and the `GetInstantMixFromItem` family of endpoints. Bios, related artists, and editorial data are available if the server admin populates them via MusicBrainz/TheAudioDB plugins.

---

## 1. Home Screen

The home screen is the discovery and "come back to" surface. For a self-hosted library, there are no server-side recommendations by default — we build everything from local metadata.

Priority order of information on home:
1. Time-aware greeting (or library summary if greeting is suppressed)
2. **Continue / Jump Back In** — the last few albums a user partially played
3. **Recently Played** — last N tracks/albums, newest first
4. **Quick Picks** — heavy rotation: top-played albums over the last 30 days
5. **Recently Added** — newly ingested releases
6. **Favorites** — starred items, rotated/random
7. **Random from Library / Rediscover** — a shuffled slice of the catalog
8. Optionally: **Top Genres**, **For Decade**, **Artist Spotlight** (random artist with their top tracks)

### Issue 1: Home — layout scaffolding with sectioned carousels
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Build the Home screen as a vertical stack of horizontally-scrollable carousels. Each section has a header (title, optional subtitle, "See All" button), 8-12 items in a row, native horizontal scroll with two-finger swipe and momentum. Row heights differ by content type: 180pt for album/playlist tiles, 220pt for tracks-with-artwork, 140pt for artist circles. Scrolling feels premium when rows snap lightly to card boundaries on trackpad flick.

Acceptance:
- Vertical scroll inside the Home view snaps smoothly; carousels scroll horizontally with two-finger swipe and ⌘←/⌘→ when focused.
- Each section header has an overflow `•••` that can hide/reorder the section.
- The scaffolding renders with skeleton placeholders before data arrives — same dimensions, subtle shimmer.
- The carousel supports "teaser" behavior (the next item's edge is visible) so users know to scroll.

References: Apple Music Listen Now, Spotify Home, Marvis Pro's 30-section configurable Home.

### Issue 2: Home — time-aware greeting with dynamic subtitle
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Header shows "Good morning / afternoon / evening, [name]" plus a dynamic subtitle like "You've played 12 albums this week" or "3 new albums in your library." Avoid twee copy — match the Apple Music Listen Now tone ("Your music. Your mix."). Suppressible in settings.

Acceptance: greeting updates on view appear; name pulls from `user.Name`; subtitle rotates through 3-4 fact types; dismissible with preference.

### Issue 3: Home — "Jump Back In" row (last-played albums)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Query Jellyfin `Items?IncludeItemTypes=MusicAlbum&SortBy=DatePlayed&SortOrder=Descending&Limit=12&Filters=IsPlayed`. Render as 180pt album tiles with art + album name + artist. Clicking plays from where they left off *or* opens the album page (both behaviors seen in Apple Music — resume on single-click, open on click-and-hold; use double-click to open). Right-click offers Play, Shuffle, Add to Queue, Play Next, Go to Album, Go to Artist.

Acceptance: tiles show correct art at 2x; empty state shows illustration + "Play something to jump back in"; updates in real time as playback state changes.

### Issue 4: Home — "Recently Played" row (tracks)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Track-level recency, not album-level. Query `/Items?IncludeItemTypes=Audio&SortBy=DatePlayed&SortOrder=Descending&Limit=20`. Render as compact track rows with thumbnail + title + artist (no row index). Track the Jellyfin playback report properly so DatePlayed actually updates — if the playback reporting plugin isn't installed, advise the user in settings.

Acceptance: clicking plays the track; right-click has full track context menu; "Go to Album" navigates correctly.

### Issue 5: Home — "Quick Picks" (heavy rotation, last 30 days)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

"Quick Picks" is the name Apple Music uses for rotating frequent favorites. Query albums sorted by `PlayCount` desc with a date-played filter window of 30 days (client-side filter if the server doesn't support it). Show 8 tiles. Reshuffle daily so it doesn't feel static.

Acceptance: picks change at least once per day; tiles show play count on hover as a subtle badge ("42 plays"); empty state hidden until user has played 10+ tracks.

### Issue 6: Home — "Recently Added" row
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Use `/Users/{userId}/Items/Latest?IncludeItemTypes=MusicAlbum&Limit=20` (returns items sorted by `DateCreated` desc, server-side). Render identically to other album carousels but with a "NEW" badge on items added within the last 7 days.

Acceptance: badge renders; carousel respects library parent if user has scoped library; handles multi-library setups (Collections).

### Issue 7: Home — "Favorites" carousel with shuffle CTA
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Shuffled random favorite albums, 12 visible, refreshes on app launch or user pull-to-refresh. Include a header button "Shuffle All Favorites" that plays all favorited tracks shuffled.

Acceptance: shuffle respects favorite status at track+album level; empty state explains how to favorite ("Tap the heart on any album").

### Issue 8: Home — section customization (add/remove/reorder)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** L

Marvis-style: let users add, remove, and reorder home sections. Catalog of available sections: Jump Back In, Recently Played, Quick Picks, Recently Added, Favorites, Random Artist, For [Decade], Top [Genre], Unplayed Gems (albums with PlayCount=0 and DateAdded >90d), High-Rated, Most-Played This Year. Accessible via a "Customize Home" button or long-press on a section header.

Acceptance: reorder persists across launches; settings stored in MMKV/CoreData; can reset to defaults.

### Issue 9: Home — "Rediscover" section (unplayed / long-unplayed library)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** M

Show 8 albums that either have PlayCount=0 and DateAdded >90 days, or DatePlayed >1 year ago. This is the "archaeology" feature — helps users find things they forgot they had. Randomize each session.

Acceptance: distinct from "Recently Added" and "Quick Picks"; clicking plays the whole album.

---

## 2. Artist Page

The artist page is where dedicated listeners spend time. Get this right and the app feels serious.

Apple Music's artist page structure: motion artwork / hero image → Latest Release → Essential Albums → Top Songs → Full Albums → Singles & EPs → Appears On → Artist Playlists → Similar Artists → About. This proven hierarchy should be our baseline.

### Issue 10: Artist page — hero header with shuffle-all and play-all
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Full-width hero (360pt tall) with large artist image (gradient-faded at the bottom), artist name as H1 overlaid on the image bottom-left, listener stats subtitle ("[N] tracks · [N] albums · last played [date]"). Primary CTAs right-aligned: "Play" (plays all tracks shuffled from all albums) and "Shuffle" (same but random seed). Secondary: "Follow" (local favorite toggle — we don't have server-side follow), "Radio" (Instant Mix from this artist).

Acceptance: artist image comes from Jellyfin primary tag; if missing, render a generated gradient with initials; CTAs keyboard-accessible; Play uses current Play behavior (new queue, start at top).

### Issue 11: Artist page — "Top Songs" section (by play count)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Query `/Items?ArtistIds={id}&IncludeItemTypes=Audio&SortBy=PlayCount&SortOrder=Descending&Limit=10`. Render as a two-column list (5 rows x 2 cols on wide, single column narrow) with track number (Billboard-style), album thumbnail, title, play count. Apple Music shows only a handful (usually 5), then a "See All" expander.

Acceptance: expands to show 20 more on click; handles zero-play-count edge case by falling back to sort-by-album-order.

### Issue 12: Artist page — discography split by release type
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Split the discography into tabs or sequential sections: **Albums**, **Singles & EPs**, **Compilations**, **Live**, **Appears On**. Use Jellyfin's album metadata fields: `AlbumType` (if MusicBrainz plugin populated it), otherwise heuristic — treat an album with ≤3 tracks as Single/EP, check for "Live" in name, "Compilation" or "Greatest Hits" in name/tags, and "Appears On" = albums where the artist is a track artist but not album artist.

Acceptance: sort each section by year descending; each tile shows year; horizontal scroll within each; empty sections collapse silently.

### Issue 13: Artist page — "Similar Artists" carousel
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

Jellyfin `/Artists/{id}/Similar` endpoint if present (requires MusicBrainz / LastFM plugin). Fall back to: artists in shared genres, ranked by genre overlap count. Render as 140pt circular artist tiles.

Acceptance: graceful fallback if server has no similar-artists data; cap at 12; circular avatars with vibrancy-aware border.

### Issue 14: Artist page — biography section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Render the artist bio (pulled from `Artists/{id}` → `Overview` field, populated by metadata plugins). Truncate to 4 lines with "Read more" expander that opens a popover. Include born/formed, country, active years if available.

Acceptance: hidden if Overview is empty; supports plain text only (strip any HTML); "Read more" is keyboard accessible.

### Issue 15: Artist page — "Playlists featuring this artist"
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** M

Scan the user's playlists for ones containing ≥1 track by this artist. Display as a carousel at the bottom of the page. This is a "you probably forgot about these" moment.

Acceptance: surfaces user playlists only (not editorial); deduplicates; excludes auto-generated queues.

### Issue 16: Artist page — follow/favorite toggle
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Since Jellyfin's favorite is per-item, use favoriting the artist entity as the "follow" signal. Button reads "Follow" / "Following" with the icon state. Favoriting an artist should flag a home-screen "New from artists you follow" section in the future.

Acceptance: calls `POST /Users/{userId}/FavoriteItems/{artistId}`; reflects state on load; optimistic update.

---

## 3. Album Page

The album page is the most-visited detail page. Tidal set the bar with rich liner-note credits; Apple Music's editorial notes add warmth; disc-number grouping is table stakes.

### Issue 17: Album page — liner-note credits section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Render below the tracklist: **Released** (year + original year if reissue), **Label**, **Format** (CD / Vinyl / Digital, from file tags), **Total Runtime**, **Track Count**, **Disc Count**. If track-level credits exist (composer, producer, mixer, mastering engineer, from Jellyfin ID3 tags), aggregate them into a "Credits" subsection with clickable role → person lists.

Acceptance: matches Tidal's depth where data exists; degrades cleanly when fields are empty; credits are selectable text (for copy-paste).

### Issue 18: Album page — disc number grouping
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

When `ParentIndexNumber` (disc number) varies across tracks, insert a sticky header ("Disc 1" / "Disc 2") between groups. Track numbers reset per disc visually (even if `IndexNumber` is global). Apple Music shows "DISC 1" in small caps; we should match.

Acceptance: hidden for single-disc albums; handles disc numbers 1-20; tracks sort by (disc, track) ascending.

### Issue 19: Album page — "Related albums" carousel
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

At the bottom, show "More by [Artist]" (other albums by album artist, excluding current) and "Listeners also played" (heuristic: other albums in shared genres sorted by play count). Cap at 10 each.

Acceptance: both rows render; excludes current album; handles solo-artist edge case (one album only).

### Issue 20: Album page — editorial notes if present
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Some Jellyfin setups populate `Overview` on the album entity itself (Apple Music-style "About this album" editorial blurbs via MetaBrainz). Render below the hero, above the tracklist, with "Read more" expansion at 4 lines.

Acceptance: hidden when empty; supports emoji/unicode; max-height 400pt when expanded (then scrolls).

### Issue 21: Album page — hover-to-play track row affordance
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Apple Music replaces the track number with a play button on row hover. Match this: on hover, track number dims and a play triangle fades in at the same position. On click, play. Favorite heart appears on hover on the right (between duration and overflow menu). The whole row stays selectable with single click for context menu target.

Acceptance: hover transition is snappy (<150ms); focus ring visible with keyboard; respects Reduce Motion.

### Issue 22: Album page — Play, Shuffle, Radio, Download CTAs
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Below the hero image (top-left) and name/year metadata (right), a horizontal row of CTA buttons: **Play** (primary, filled), **Shuffle** (secondary), **Radio** (Instant Mix from album), **Download** (if offline mode enabled), **•••** (overflow: Add to Playlist, Share, Go to Artist, Mark Played, Edit Metadata, Copy Album Link).

Acceptance: keyboard-focusable in Tab order; Radio calls Jellyfin `GetInstantMixFromAlbum`.

---

## 4. Playlist CRUD

Playlists are where users commit their taste. Every affordance matters.

### Issue 23: Playlist — create dialog with instant name edit
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Cmd+N in the Playlists sidebar context creates a new playlist with placeholder name ("New Playlist") in edit mode. Hitting Return commits; Escape cancels. No modal — inline in the sidebar.

Acceptance: calls `POST /Playlists` with MediaType=Audio; new playlist appears at top (sort by DateCreated desc initially); auto-scrolls to it.

### Issue 24: Playlist — "Add to Playlist" popover
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Right-click a track / album / selection → "Add to Playlist…" opens a popover anchored to the menu item. Popover shows: (1) "New Playlist…" at top, (2) a search/filter field, (3) a scrolling list of existing playlists alphabetized, with a tiny "+" icon that instantly adds on click. Arrow keys navigate, Return adds. Matches Apple Music's pattern exactly.

Acceptance: popover dismisses on Esc or click-outside; supports multi-select from tracklist; shows confirmation toast ("Added 3 songs to [Playlist]").

### Issue 25: Playlist — drag-reorder tracks
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Click-and-drag a track row to reorder. Show a grabber icon (three bars) on hover left-side of the row. During drag, show a drop indicator line between rows. Support multi-select drag (hold Shift or Cmd). Persists via `POST /Playlists/{id}/Items/{itemId}/Move`.

Acceptance: works with keyboard (Alt+Up / Alt+Down to move selected rows); respects Reduce Motion; no visual jank during drag.

### Issue 26: Playlist — remove tracks (multi-select)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Select tracks (Cmd+Click, Shift+Click) → Delete or Backspace removes. Right-click → "Remove from Playlist". No confirmation dialog for removals — use undo toast pattern ("Removed 3 songs. Undo"). Calls `DELETE /Playlists/{id}/Items`.

Acceptance: undo is non-destructive for 10s; multi-select removal is atomic; tracks remain in library.

### Issue 27: Playlist — rename, duplicate, delete
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Right-click a playlist in the sidebar → "Rename" (inline edit), "Duplicate" (creates "[Name] Copy" with same tracks), "Delete" (confirm dialog since this is destructive, with "Don't ask again" checkbox).

Acceptance: rename persists; duplicate copies all items; delete uses `DELETE /Items/{id}` and confirms before removing.

### Issue 28: Playlist — export to .m3u / .m3u8
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** M

File menu: Export Playlist… opens save panel; writes an .m3u8 file with relative or absolute paths (user preference). Include #EXTINF metadata (duration, "artist - title"). Useful for users who sync to other devices.

Acceptance: valid m3u8 UTF-8; optional absolute-path toggle in the save panel; drag a playlist onto Finder/Desktop triggers export.

### Issue 29: Smart Playlists — rule builder
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** XL

Marvis/iTunes-style rule builder: "Match [all/any] of the following rules." Rule types: Artist, Album, Genre, Year (is/before/after/between), PlayCount (>/</=), DateAdded (last N days), DatePlayed (last N days/never), Favorite (is/isn't), Rating, Duration, File Format, Bitrate. "Limit to [N] items selected by [random/most played/least played/recently added]." "Live update" toggle.

Acceptance: saves as a local smart playlist (computed client-side from library snapshot since Jellyfin doesn't natively support smart playlists); re-evaluates on view; persists rules.

### Issue 30: Playlist — collaborative / shared playlists (future hook)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Jellyfin supports `Playlists` with multiple users via `UserId` sharing. Surface "Public" / "Private" toggle when creating/editing. For now, stub the UI — full collab is a future story.

Acceptance: toggle sends correct `IsPublic` flag to Jellyfin; display lock icon in sidebar for private playlists.

---

## 5. Up Next / Queue

The queue is the most-overlooked piece of a music player, and the place where Spotify and Apple Music diverge sharply from the pack. We want the best of both.

Three distinct concepts the UI must express:
- **Now Playing** — the track playing right now.
- **Up Next (user-added)** — things the user explicitly asked for via "Play Next" or "Add to Queue."
- **Auto-queue (continuation)** — the rest of the album, playlist, or radio continuation that's queued because of the current context.

### Issue 31: Queue — right-side Up Next inspector panel
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** L

Toggleable right-side panel (like Apple Music's inspector). 320pt wide. Three stacked sections from top: (1) **Now Playing** — big thumbnail, title, artist, scrubber. (2) **Up Next** — user-added queue with a "Clear" button and a "Playing from [context]" subtitle. (3) **[Context name]** (e.g., "From album Moon Safari") — the auto-queue continuation. Each section has a collapse/expand disclosure.

Acceptance: toggle bound to Cmd+Option+U; drag to resize 280-400pt; remembers state across launches.

### Issue 32: Queue — drag reorder + remove within Up Next
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

User-added items in Up Next are draggable to reorder and show an X on hover to remove. The auto-queue below is read-only (can only "jump to" a track, not reorder). This distinction is what Spotify users complain is missing.

Acceptance: drag works with trackpad; keyboard reorder via Option+Up/Down; remove with Delete.

### Issue 33: Queue — full-page Play Queue view
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

In addition to the inspector, a dedicated full-page queue (accessible via Cmd+U). Shows entire queue, history (played tracks), and upcoming in a larger format suitable for bulk editing. Matches Spotify's dedicated Queue page.

Acceptance: Cmd+U opens; shows last 50 played tracks above Now Playing for "Recently in this session" context; "Save Queue as Playlist" button.

### Issue 34: Queue — "Playing from [context]" persistent label
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

In both the inspector and the mini player, persistently show "Playing from [Album / Playlist / Artist Radio / Mix / Liked Songs]." The context label is clickable and navigates to that source. This is one of Spotify's best details.

Acceptance: label updates instantly when context changes; clickable; truncates with ellipsis on narrow layouts.

### Issue 35: Queue — auto-queue disable toggle
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Some users hate endless autoplay. Add a toggle in the queue header: "Autoplay similar music when queue ends." Default on. When off, playback stops at the end of the user-added queue.

Acceptance: persists; affects Instant Mix generation only (not explicit album-end).

### Issue 36: Queue — "Save current queue as playlist"
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Header overflow menu in the full queue page: "Save as Playlist." Creates a playlist with the current queue contents, opens it, and puts name in edit mode.

Acceptance: includes Up Next + remaining auto-queue; skips history.

---

## 6. Search

A great search is instant, categorized, keyboard-navigable, and has a clear "Top Result."

### Issue 37: Search — instant-results dropdown with "Top Result" hero
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** L

Cmd+F focuses the search field (Cmd+L is also common for "location/search" on macOS). As the user types, a dropdown appears below the field with results categorized: **Top Result** (a hero card: large thumbnail, name, type label, play CTA — usually the highest-relevance match across all types), then **Artists**, **Albums**, **Tracks**, **Playlists**, **Genres**, each showing 3-5 items with "See All Songs" / "See All Albums" expanders. Debounce 200ms. Calls Jellyfin `/Items?searchTerm=X&IncludeItemTypes=...&Recursive=true`.

Acceptance: arrow keys navigate across categories; Return plays the Top Result; Esc dismisses; handles "no results" gracefully.

### Issue 38: Search — full search results page
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Pressing Return in search or clicking "See All" opens a full page with tabs (All / Artists / Albums / Tracks / Playlists / Genres) and richer results.

Acceptance: tab state preserved on navigation; "All" tab mirrors dropdown layout but with ~20 per category; per-type tabs paginate.

### Issue 39: Search — recent searches + suggested searches
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

When search field is focused but empty, show "Recent Searches" (last 10, locally stored) with X to remove each. Below that, "Suggested" — rotating genres, decades, or lightly-played artists to encourage exploration.

Acceptance: clear all button; recent searches persist via MMKV/UserDefaults.

### Issue 40: Search — scoped search
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

When viewing an artist or playlist, a Cmd+F press focuses a scoped search within that view (e.g., filter tracks on the artist page). Separate from global search (accessible via the top-bar search button or Cmd+Shift+F).

Acceptance: scoped search is visually distinct (smaller bar inside the content area); clears on navigation away.

---

## 7. Lyrics

Jellyfin supports lyrics via the jellyfin-plugin-lyricfind plugin (or similar) — LRC (time-synced) and plain text formats.

### Issue 41: Lyrics — full-screen lyrics view with time sync
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** L

Lyrics view accessible via a button in the player bar (quote icon) or Cmd+Option+L. View takes over the main content area (not a modal). Layout: large album art left, lyrics right, both on a gradient background sourced from the album art. For time-synced (LRC) lyrics, auto-scroll keeps current line centered vertically with smooth animation; current line is 100% opacity + brighter, past/future lines fade to 50%/30%. Tap any line to seek to that timestamp.

Acceptance: fetches from Jellyfin `/Audio/{id}/Lyrics`; handles LRC parsing; falls back to plain text (non-scrolling) when timestamps absent; keyboard arrow keys seek by verse.

### Issue 42: Lyrics — Apple Music "Sing"-style polish
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** M

For LRC lyrics, give each word an individual fade-in synchronized to its timestamp (if word-level timestamps exist — increasingly common). If only line-level, each line fades in as it arrives with a subtle scale (99%→100%) and bloom. Respect Reduce Motion by disabling all animation.

Acceptance: fades smoothly at 60fps; no animation when Reduce Motion enabled.

### Issue 43: Lyrics — inline mode in Now Playing
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

In the Up Next inspector, below Now Playing info, add a compact lyrics snippet showing 3 lines (previous, current highlighted, next). For users who don't want the full-screen takeover.

Acceptance: auto-scrolls in sync; clickable to open full lyrics view; gracefully omitted when no lyrics.

---

## 8. Radio / Instant Mix

Jellyfin has `/Items/{itemId}/InstantMix` endpoints at the song, album, artist, genre, and playlist levels. This is the magic ingredient for endless listening.

### Issue 44: Radio — "Song Radio" via right-click on a track
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Right-click any track → "Start Song Radio." Calls `/Items/{trackId}/InstantMix?Limit=50`. Replaces the current queue with this mix; playback starts from the first track; "Playing from: [Track Name] Radio" as the context label.

Acceptance: works on Audio items, albums, artists, genres, playlists (show correct Radio name per source); auto-extends when queue drops below 10 remaining.

### Issue 45: Radio — dedicated Radio/Mixes section in sidebar
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** M

A sidebar section "Stations" lists user-saved radio seeds. Save a radio: while listening to a mix, click "Save Radio" → persists the seed item. Returning to it regenerates a fresh mix from that seed. Like Apple Music's "Personal Stations."

Acceptance: persists locally; "Generated fresh N minutes ago" in the detail view; one-click regenerate.

### Issue 46: Radio — Genre stations
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

On the Genres page or from a Genre chip on any item, "Start Genre Radio" calls `/Genres/{id}/InstantMix`. These are long-form continuous listening.

Acceptance: works from any genre tag; surfaces "Genre Radio" as an artist page CTA too.

---

## 9. Context Menus

Complete menu coverage, per-entity. Every action should be here. The primary UI surfaces the most important 2-3; the menu surfaces everything.

### Issue 47: Context menu — tracks
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Right-click a track in any list. Menu order (Apple Music + Spotify convention, grouped with dividers):
1. **Play** (⏎)
2. **Play Next** (adds to top of Up Next)
3. **Add to Queue** (appends to Up Next)
— divider —
4. **Start Song Radio**
5. **Add to Playlist →** (submenu / popover)
— divider —
6. **Go to Album**
7. **Go to Artist**
8. **Show Track Credits** (if present)
— divider —
9. **Favorite** / **Unfavorite** (♥ toggle)
10. **Mark as Played** / **Mark as Unplayed**
— divider —
11. **Copy Link** (copies a Jellify-scheme URL)
12. **Share** (macOS share sheet)
— divider —
13. **Edit Metadata…** (opens metadata editor if user has admin rights)
14. **Show in Finder** (for users with local path access — admin-only)

Acceptance: multi-select adjusts titles (e.g., "Play 5 Songs Next"); keyboard shortcuts displayed on right side of each item; items hidden if not applicable.

### Issue 48: Context menu — albums
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

1. **Play**
2. **Shuffle**
3. **Play Next**
4. **Add to Queue**
— divider —
5. **Start Album Radio**
6. **Add to Playlist →**
— divider —
7. **Go to Artist**
8. **Go to Album** (if invoked from a context outside the album page)
— divider —
9. **Favorite Album**
10. **Mark All as Played**
— divider —
11. **Download** (if offline mode)
12. **Edit Album Info…**
13. **Copy Link**
14. **Share**

Acceptance: matches Apple Music convention; "Download" hidden when offline mode disabled.

### Issue 49: Context menu — artists
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

1. **Play All** (shuffle all tracks)
2. **Shuffle All**
3. **Play Next** (appends artist's top N)
— divider —
4. **Start Artist Radio**
— divider —
5. **Follow** / **Unfollow**
6. **Go to Artist Page** (if invoked elsewhere)
— divider —
7. **Copy Link**, **Share**

Acceptance: "Play All" respects any active filter (e.g., if on a genre page, plays only that genre's tracks by the artist).

### Issue 50: Context menu — playlists (sidebar)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

1. **Play**
2. **Shuffle**
3. **Play Next**
4. **Add to Queue**
— divider —
5. **Rename** (inline)
6. **Duplicate**
7. **Delete** (with confirm)
— divider —
8. **Export as .m3u8…**
9. **Copy Link**

Acceptance: Delete confirmation per Issue 27; sortable in sidebar via drag.

---

## 10. Empty, Loading, Error States

### Issue 51: Empty state — first-run (logged in, no library)
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

User is logged in but has zero music items in their view. Full-bleed empty state: large illustration (a turntable or stack of records), headline "No music yet," body "Your Jellyfin admin hasn't added any audio items to this library, or you don't have access to any music libraries. Reach out to them to get started." CTA: "Change Library" (opens library picker if multiple libraries exist).

Acceptance: only shows when library query returns 0 items after successful auth; no perpetual spinner; hidden once items appear.

### Issue 52: Loading state — skeleton shimmer matching target grid
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Never render a spinner alone for list/grid loads. Render skeleton shapes matching the final grid: rectangles sized like album tiles with a gentle shimmer (200ms linear gradient sweep). On data arrival, crossfade skeletons to real content over 120ms.

Acceptance: shimmer respects Reduce Motion (static gray with same geometry); skeleton count matches expected page size.

### Issue 53: Error state — network disconnected
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Top-of-window non-modal banner when server unreachable: "Can't reach [server]. Trying again…" with a "Retry" button. If user has offline-downloaded content, route the UI to offline library view automatically.

Acceptance: banner dismisses on reconnect with a success flash; offline mode preserves playback for cached tracks.

### Issue 54: Error state — stream error / playback failure
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

If a track fails to stream (404, 403, decode error), show a toast "Couldn't play [Track Name]" with a "Skip to Next" and "Report" action. Don't silently advance — the user needs to know why the music stopped.

Acceptance: log error with track ID and server response; supports offline fallback if file is cached locally.

### Issue 55: Empty state — search no results
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Search yields zero results: centered "No results for '[query]'." Below, suggestions: "Try a different spelling," "Check your library scope," or link to "Browse by Genre." For fun, optional: rotate a tiny "Did you mean…" based on closest Levenshtein match across artists.

Acceptance: didYouMean only suggests if edit distance ≤2.

---

## 11. Keyboard Navigation

macOS users expect keyboard-first to actually work.

### Issue 56: Keyboard — global shortcut map
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Implement the full shortcut table:
- **Space** — Play/Pause (even when main window not focused? no — scope to window; media keys handle global)
- **→ / ←** — Next / Previous track
- **↑ / ↓** — Volume up/down (in player bar focus); list navigation (in list focus)
- **⌘F** — Focus search
- **⌘L** — Go to currently playing (focus Now Playing context)
- **⌘U** — Open Play Queue (full page)
- **⌘⌥U** — Toggle Up Next inspector
- **⌘⌥L** — Toggle Lyrics view
- **⌘⌥P** — Toggle Mini Player
- **⌘,** — Settings
- **⌘1-9** — Jump to sidebar section 1-9
- **⌘N** — New Playlist
- **⌘R** — Refresh / Reload library
- **⌘⏎** (in a tracklist) — Play selected
- **⌘⇧⏎** — Play selected next
- **⌥⏎** — Play selected now (replaces queue)
- **⌫** — Remove from playlist/queue
- **?** or **⌘/** — Open shortcut cheat sheet overlay

Acceptance: every one works; cheat sheet overlay lists all bindings in an HUD.

### Issue 57: Keyboard — list arrow key navigation with Return to play
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Clicking any list focuses the list. Arrow keys navigate rows (with auto-scroll into view). Shift+Arrow extends selection. Cmd+Arrow extends to endpoints. Return plays the selected item(s). Space play/pauses. Typing a letter does type-ahead to jump to items starting with that letter (within 500ms of last keystroke).

Acceptance: focus ring visible per macOS conventions; accessibility labels read by VoiceOver; keeps selection when switching windows.

### Issue 58: Keyboard — hover tooltips reveal shortcut
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Spotify does this perfectly: every toolbar button's tooltip shows the action name + its shortcut. "Play · Space," "Next Track · →." Teaches shortcuts passively.

Acceptance: all toolbar and player-bar buttons have tooltips; appear after 500ms hover; dismiss on mouseout.

### Issue 59: Keyboard — Tab moves between regions
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

Tab/Shift+Tab cycle between: Sidebar → Content pane → Up Next inspector → Player bar → Search. Within each region, the focusable subtree is well-defined. Matches macOS's "Full Keyboard Access" convention.

Acceptance: works with or without Full Keyboard Access enabled; focus ring visible on each region transition.

---

## 12. Mini Player

A mini player is the "I'm working, leave the music alone" mode.

### Issue 60: Mini Player — detached borderless window
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** L

Cmd+Option+P toggles. Size: 320×120pt default (resizable 280-480pt wide). Borderless (no chrome), rounded corners, vibrancy background. Draggable from anywhere. Contents: album art (square, left), track title (truncated), artist (smaller, below), transport row (previous / play-pause / next / volume popover). On hover: show scrub bar and a "return to full window" button.

Acceptance: always-on-top toggle in mini-player settings menu (per Apple Music's MiniPlayer); closing returns to full window; supports drag by album art area.

### Issue 61: Mini Player — progressive disclosure on hover
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

When not hovered, mini player is a minimal card. On hover, overlay fades in showing all controls plus a small expand button and favorite heart. Mimics Silicio's pattern.

Acceptance: hover overlay fades in/out smoothly; pointer idle timeout 2s to hide overlay; respects Reduce Motion.

### Issue 62: Mini Player — click-through area for artwork
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Clicking the album art opens the album; clicking the artist name opens the artist page in the main window. Main window is restored if hidden.

Acceptance: artwork click opens correct context; avoids accidental triggers during drag (use drag threshold).

---

## 13. Onboarding

First launch. User hasn't logged in, or logged in but library is syncing.

### Issue 63: Onboarding — login screen with server discovery
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

First launch shows a centered login card: Jellify logo, "Connect to your Jellyfin server," server URL field (with Bonjour/mDNS-discovered servers as a dropdown below if any are found on the local network), Continue button. Second step: username + password, Quick Connect code option. Remember URL history in dropdown for future logins.

Acceptance: Bonjour discovery for `_jellyfin._tcp`; Quick Connect fallback link; clear error messages for cert / auth / network issues.

### Issue 64: Onboarding — post-login library preparation splash
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

Immediately after login, if library is empty or metadata is still syncing, show a friendly splash: "Welcome, [name]! Preparing your library… [spinner] [N albums indexed so far]." Progress indicator advances as album/artist counts arrive. Dismisses to Home when first batch is ready (don't make the user wait for everything).

Acceptance: first batch = 50 albums; background prefetch continues after dismiss; counts update live.

### Issue 65: Onboarding — first-run tour
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** M

After first successful load: a short, dismissible tour (3-4 callouts) highlights key features: "Right-click anything for more options," "Press Space to play/pause," "Cmd+F to search," "Cmd+Option+P for mini player." Don't force — show a "?" button in the toolbar that re-opens it.

Acceptance: dismissible at any step; coach marks use macOS-native popover styling; "Don't show again" persists.

---

## 14. Settings

A music app's settings are deep. Structure matters.

### Issue 66: Settings — top-level organization
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

Settings window follows macOS System Settings pattern: left sidebar with sections, content pane on the right. Sections: **General**, **Server**, **Playback**, **Audio**, **Library**, **Appearance**, **Keyboard Shortcuts**, **Advanced**, **About**. Window is 720×560pt, non-resizable in height.

Acceptance: Cmd+, opens; sections deep-linkable; cmd+W closes.

### Issue 67: Settings — Server section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** S

Current server info: URL, server name, server version. Connected user: name, avatar, role. Buttons: "Switch Server," "Sign Out," "Change User."

Acceptance: displays fetched server info; graceful offline display; sign-out confirms.

### Issue 68: Settings — Playback section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

**Crossfade** (slider: Off, 1-12s), **Gapless playback** (on/off, default on), **Normalization** (Off / Track / Album — ReplayGain if tags present), **Pre-gain** (dB slider ±12), **Stop after current track** (toggle), **Autoplay similar music** (toggle).

Acceptance: changes apply live; crossfade slider tooltips seconds; ReplayGain reads `albumGain` / `trackGain` from file tags.

### Issue 69: Settings — Audio quality section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p0`
**Effort:** M

**Streaming quality** (Low 96kbps / Normal 192 / High 320 / Lossless / Original). **Download quality** (same options). **Transcoding preference** (Direct Play when possible / Always Transcode / etc.). **Audio output device** (list of CoreAudio devices). **Exclusive mode** (toggle, if device supports).

Acceptance: maps to Jellyfin transcoding profile; bitrate caps enforced; device switching works live.

### Issue 70: Settings — Appearance section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

**Theme preset** (Purple / Ocean / Forest / Sunset / Peanut). **Mode** (System / Light / Dark / OLED). **Accent override** (color picker). **Window tint** (follow-artwork / static). **Density** (Compact / Comfortable / Spacious). **Reduce motion** (inherits System but overridable).

Acceptance: applies instantly; OLED mode uses true black; theme changes animate for ~200ms.

### Issue 71: Settings — Library section
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** M

**Default library** (picker if multiple). **Default sort for Albums** (Name / Artist / Year / DateAdded / PlayCount / Random). **Default sort for Songs** (same). **Show/hide sections in sidebar**. **Show track numbers** (toggle). **Show play counts on hover** (toggle).

Acceptance: changes persist and reflect in list views.

### Issue 72: Settings — Keyboard Shortcuts customization
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** L

List of all shortcuts in a table. Each row has Action, Current Shortcut, Record button. Clicking Record shows "Press keys…" state; conflicts are detected and warned. Reset All and Reset per-item.

Acceptance: shortcut state persists; conflicts shown inline; works with modifier combos.

### Issue 73: Settings — Lyrics source
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

Lyrics source: **Jellyfin server only** / **Jellyfin + fallback to LRCLib** / **None**. LRCLib fallback fetches from https://lrclib.net for tracks without server lyrics.

Acceptance: fallback is async and cached locally per track; failure is silent.

### Issue 74: Settings — Notifications
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

**Track change notifications** (on/off). **Only when Jellify is in the background** (toggle). **Show album art** (toggle). These use `UNNotificationCenter` with rich content.

Acceptance: notifications match macOS native look; respect Do Not Disturb; user-revocable.

### Issue 75: Settings — About
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p1`
**Effort:** S

App version, build number, Jellyfin server version, Rust core version. Links to GitHub repo, release notes, licenses (third-party attributions), report-a-bug (opens prefilled issue template), Matrix/Discord community.

Acceptance: all links open in default browser; version info pulled from bundle and server API.

---

## Summary of scope

- **Total issues: 75** across Home, Artist, Album, Playlists, Queue, Search, Lyrics, Radio, Context Menus, Empty/Loading/Error States, Keyboard Navigation, Mini Player, Onboarding, and Settings.
- **p0 (ship to feel complete):** roughly 40 issues — the minimum set that makes a Jellyfin client feel like a real music app.
- **p1:** the polish that separates "good" from "premium."
- **p2:** power-user features (smart playlists, shortcut customization, rich onboarding tour).

## Key reference apps by pattern

| Pattern | Best reference |
|---|---|
| Sidebar + inspector layout | Apple Music |
| "Top Result" search hero | Apple Music, Spotify |
| Right-click Song Radio | Spotify |
| Liner-note credits | Tidal |
| Customizable home sections | Marvis Pro |
| Smart playlist rules | iTunes / Marvis |
| Time-synced lyrics | Apple Music Sing |
| Minimalist keyboard-first | Doppler |
| Plugin/theme customization | Cider |
| Mini player window | Apple Music MiniPlayer, Silicio |
| Progressive disclosure on hover | Silicio |
| "Playing from" context label | Spotify |
| "Jump Back In" row | Apple Music Listen Now |

## Jellyfin metadata capabilities confirmed

- `UserData.PlayCount`, `UserData.LastPlayedDate`, `UserData.IsFavorite` — all per user
- Sort: `DatePlayed`, `PlayCount`, `DateCreated`, `SortName`, `ProductionYear`, `Random`
- Filters: `Filters=IsPlayed|IsUnplayed|IsFavorite`, `Years=`, `Genres=`, `Artists=`
- `/Items/{id}/InstantMix` and family — generates smart radio
- `/Users/{uid}/Items/Latest` — server-side recently added
- `/Artists/{id}/Similar` — similar artists (if metadata plugin populated)
- `/Audio/{id}/Lyrics` — lyrics, LRC format when available
- `/Playlists` CRUD — full support via `POST/DELETE/GET` on `/Playlists/{id}/Items`, with `Move` endpoint for reorder

## Sources

- [Apple Music on Mac: Optimizations for a better UX (Medium)](https://medium.com/design-bootcamp/apple-music-on-mac-optimizations-for-a-better-ux-a247c5f0d665)
- [Doppler for Mac review (MacStories)](https://www.macstories.net/reviews/doppler-for-mac-offers-an-excellent-album-and-artist-focused-listening-experience-for-your-owned-music-collection/)
- [Marvis Review: The Ultra-Customizable Apple Music Client (MacStories)](https://www.macstories.net/reviews/marvis-review-the-ultra-customizable-apple-music-client/)
- [Cider Collective](https://cider.sh/)
- [TIDAL Credits feature](https://tidal.com/credits)
- [Tidal adds liner notes (Musically)](https://musically.com/2017/11/06/tidal-adds-liner-notes-tracks-albums/)
- [Apple Music MiniPlayer (Apple Support)](https://support.apple.com/guide/music/use-music-miniplayer-mus71d7dcfce/mac)
- [Apple Music Queue (Apple Support)](https://support.apple.com/guide/music/queue-your-songs-musb1e6d1c76/mac)
- [Apple Music Smart Playlists (Apple Support)](https://support.apple.com/guide/music/create-edit-and-delete-smart-playlists-mus1712973f4/mac)
- [Apple Music lyrics on Mac (9to5Mac)](https://9to5mac.com/2020/03/26/mac-how-to-use-time-synced-lyrics-apple-music/)
- [Apple Music Sing feature (MacRumors)](https://www.macrumors.com/how-to/use-apple-music-sing-karaoke-feature/)
- [Spotify keyboard shortcuts](https://support.spotify.com/us/article/keyboard-shortcuts/)
- [Tuneful app (native Mac)](https://tuneful.app/)
- [Silicio Mini Player](https://apps.apple.com/us/app/silicio-mini-player/id933627574?mt=12)
- [Jellyfin API overview (James Harvey)](https://jmshrv.com/posts/jellyfin-api/)
- [Jellyfin Music docs](https://jellyfin.org/docs/general/server/media/music/)
- [Empty state design (Nielsen Norman Group)](https://www.nngroup.com/articles/empty-state-interface-design/)
- [Apple HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [SwiftUI keyboard shortcuts (Swift with Majid)](https://swiftwithmajid.com/2020/11/17/keyboard-shortcuts-in-swiftui/)
