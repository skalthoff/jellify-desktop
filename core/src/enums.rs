//! Typed enums for Jellyfin API query parameters.
//!
//! Historically the client crate built query strings with string literals
//! sprinkled through [`crate::client`] (`IncludeItemTypes=MusicAlbum`,
//! `SortBy=PlayCount,SortName`, ...). That was quick to land but scattered
//! the allowed values across the call sites — a typo in a call site would
//! silently fail server-side, and consumers of the Swift FFI had no way to
//! discover the accepted values short of reading the Rust source.
//!
//! The enums here centralise those allowed values as `PascalCase`-
//! serialising Rust enums:
//!
//! - [`ItemKind`] mirrors Jellyfin's `BaseItemKind` (the subset a music app
//!   hits).
//! - [`ImageType`] mirrors the `ImageController` routes served from
//!   `/Items/{id}/Images/{type}`.
//! - [`ItemSortBy`] mirrors the `ItemSortBy` strings accepted by the `/Items`
//!   family of endpoints.
//! - [`SortOrder`] is the two-value direction (Ascending / Descending).
//! - [`ItemField`] mirrors the `Fields` projection parameter.
//!
//! Every enum derives `Serialize` / `Deserialize` with
//! `#[serde(rename_all = "PascalCase")]`, so building query strings is a
//! plain `serde_json::to_value` away (or, when writing query strings
//! directly, [`Self::as_str`] yields the exact server-facing token).

use serde::{Deserialize, Serialize};

/// The item-type subset Jellify Desktop cares about.
///
/// Mirrors Jellyfin's `BaseItemKind` — we only expose the variants that can
/// land in music-scoped queries (tracks, albums, artists, playlists,
/// genres). Variants serialise in PascalCase so the enum is drop-in for
/// `IncludeItemTypes` / `ExcludeItemTypes` query params.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "PascalCase")]
pub enum ItemKind {
    /// An audio track — Jellyfin's `Audio` item kind.
    Audio,
    /// A music album grouping several `Audio` children — `MusicAlbum`.
    MusicAlbum,
    /// A music artist — `MusicArtist`. Jellyfin distinguishes AlbumArtist
    /// vs. Artist at the field level; this kind covers both for query purposes.
    MusicArtist,
    /// A user or public playlist — `Playlist`.
    Playlist,
    /// A music genre bucket — `MusicGenre`.
    MusicGenre,
    /// A music video — rare in Jellify Desktop but accepted by the server
    /// and included so `ItemKind` round-trips without loss for generic
    /// queries.
    MusicVideo,
    /// A manual-playlists folder (the playlists library view itself).
    ManualPlaylistsFolder,
    /// A standard library collection folder — returned by `/UserViews` for
    /// Music / Movies / TV Shows / etc. Rarely set by our own queries but
    /// needed for `ExcludeItemTypes` filters that target the library folder
    /// vs. its children.
    CollectionFolder,
}

impl ItemKind {
    /// The exact server-facing token (e.g. `"MusicAlbum"`). Useful when
    /// building URL query strings by hand rather than via `serde_json`.
    pub fn as_str(&self) -> &'static str {
        match self {
            ItemKind::Audio => "Audio",
            ItemKind::MusicAlbum => "MusicAlbum",
            ItemKind::MusicArtist => "MusicArtist",
            ItemKind::Playlist => "Playlist",
            ItemKind::MusicGenre => "MusicGenre",
            ItemKind::MusicVideo => "MusicVideo",
            ItemKind::ManualPlaylistsFolder => "ManualPlaylistsFolder",
            ItemKind::CollectionFolder => "CollectionFolder",
        }
    }
}

/// Jellyfin image variants served from `GET /Items/{id}/Images/{type}`.
/// Mirrors the `ImageType` routes defined by the Jellyfin `ImageController`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "PascalCase")]
pub enum ImageType {
    Primary,
    Backdrop,
    Thumb,
    Logo,
    Art,
    Banner,
    Disc,
    Box,
    Screenshot,
    Menu,
    Chapter,
    BoxRear,
    Profile,
}

impl ImageType {
    /// Path segment as Jellyfin expects it in the URL
    /// (`/Items/{id}/Images/{segment}`). Distinct from [`Self::as_str`] only
    /// in spirit — they happen to coincide today.
    pub fn as_path(&self) -> &'static str {
        self.as_str()
    }

    /// The exact server-facing token (e.g. `"Primary"`).
    pub fn as_str(&self) -> &'static str {
        match self {
            ImageType::Primary => "Primary",
            ImageType::Backdrop => "Backdrop",
            ImageType::Thumb => "Thumb",
            ImageType::Logo => "Logo",
            ImageType::Art => "Art",
            ImageType::Banner => "Banner",
            ImageType::Disc => "Disc",
            ImageType::Box => "Box",
            ImageType::Screenshot => "Screenshot",
            ImageType::Menu => "Menu",
            ImageType::Chapter => "Chapter",
            ImageType::BoxRear => "BoxRear",
            ImageType::Profile => "Profile",
        }
    }
}

/// The `SortBy` values accepted by `/Items`-family endpoints. Mirrors
/// Jellyfin's `ItemSortBy` — only the fields meaningful to a music library
/// are represented.
///
/// Callers pass a `Vec<ItemSortBy>` to [`crate::query::ItemsQuery::sort_by`];
/// the builder joins them into the CSV the server expects (e.g.
/// `PlayCount,SortName`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "PascalCase")]
pub enum ItemSortBy {
    Name,
    SortName,
    DateCreated,
    DatePlayed,
    PlayCount,
    PremiereDate,
    ProductionYear,
    Album,
    AlbumArtist,
    Artist,
    Runtime,
    IsFavoriteOrLiked,
    CommunityRating,
    CriticRating,
    Random,
}

impl ItemSortBy {
    /// The exact server-facing token (e.g. `"PlayCount"`).
    pub fn as_str(&self) -> &'static str {
        match self {
            ItemSortBy::Name => "Name",
            ItemSortBy::SortName => "SortName",
            ItemSortBy::DateCreated => "DateCreated",
            ItemSortBy::DatePlayed => "DatePlayed",
            ItemSortBy::PlayCount => "PlayCount",
            ItemSortBy::PremiereDate => "PremiereDate",
            ItemSortBy::ProductionYear => "ProductionYear",
            ItemSortBy::Album => "Album",
            ItemSortBy::AlbumArtist => "AlbumArtist",
            ItemSortBy::Artist => "Artist",
            ItemSortBy::Runtime => "Runtime",
            ItemSortBy::IsFavoriteOrLiked => "IsFavoriteOrLiked",
            ItemSortBy::CommunityRating => "CommunityRating",
            ItemSortBy::CriticRating => "CriticRating",
            ItemSortBy::Random => "Random",
        }
    }
}

/// Sort direction for [`ItemSortBy`]. Two variants with `Asc` / `Desc`
/// aliases for consumers that prefer the short form.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "PascalCase")]
pub enum SortOrder {
    Ascending,
    Descending,
}

impl SortOrder {
    /// Short alias for `Ascending` so callers can write
    /// `SortOrder::Asc` where the full word reads clunky.
    #[allow(non_upper_case_globals)]
    pub const Asc: SortOrder = SortOrder::Ascending;
    /// Short alias for `Descending`.
    #[allow(non_upper_case_globals)]
    pub const Desc: SortOrder = SortOrder::Descending;

    /// The exact server-facing token (`"Ascending"` / `"Descending"`).
    pub fn as_str(&self) -> &'static str {
        match self {
            SortOrder::Ascending => "Ascending",
            SortOrder::Descending => "Descending",
        }
    }
}

/// The `Fields` projection values accepted by `/Items`-family endpoints.
/// Mirrors Jellyfin's `ItemFields` — only the fields the music UI pulls are
/// represented.
///
/// Callers pass a `Vec<ItemField>` to
/// [`crate::query::ItemsQuery::fields`]; the builder joins them into the CSV
/// the server expects (e.g. `Genres,ProductionYear,ChildCount`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "PascalCase")]
pub enum ItemField {
    Overview,
    Genres,
    ChildCount,
    People,
    MediaStreams,
    MediaSources,
    DateCreated,
    Studios,
    PrimaryImageAspectRatio,
    ExternalUrls,
    Path,
    Tags,
    ProductionYear,
    ParentId,
    AlbumId,
    AlbumArtist,
    Artists,
    RunTimeTicks,
    UserData,
    SortName,
    ItemCounts,
    BackdropImageTags,
    ProviderIds,
    PlaylistItemId,
}

impl ItemField {
    /// The exact server-facing token (e.g. `"Overview"`).
    pub fn as_str(&self) -> &'static str {
        match self {
            ItemField::Overview => "Overview",
            ItemField::Genres => "Genres",
            ItemField::ChildCount => "ChildCount",
            ItemField::People => "People",
            ItemField::MediaStreams => "MediaStreams",
            ItemField::MediaSources => "MediaSources",
            ItemField::DateCreated => "DateCreated",
            ItemField::Studios => "Studios",
            ItemField::PrimaryImageAspectRatio => "PrimaryImageAspectRatio",
            ItemField::ExternalUrls => "ExternalUrls",
            ItemField::Path => "Path",
            ItemField::Tags => "Tags",
            ItemField::ProductionYear => "ProductionYear",
            ItemField::ParentId => "ParentId",
            ItemField::AlbumId => "AlbumId",
            ItemField::AlbumArtist => "AlbumArtist",
            ItemField::Artists => "Artists",
            ItemField::RunTimeTicks => "RunTimeTicks",
            ItemField::UserData => "UserData",
            ItemField::SortName => "SortName",
            ItemField::ItemCounts => "ItemCounts",
            ItemField::BackdropImageTags => "BackdropImageTags",
            ItemField::ProviderIds => "ProviderIds",
            ItemField::PlaylistItemId => "PlaylistItemId",
        }
    }
}

/// Join a slice of enum tokens into the CSV Jellyfin accepts on its `/Items`
/// endpoints (e.g. `"MusicAlbum,MusicArtist"`).
pub(crate) fn csv<T, F>(values: &[T], render: F) -> String
where
    F: Fn(&T) -> &'static str,
{
    let mut out = String::new();
    let mut first = true;
    for value in values {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(render(value));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn item_kind_serialises_pascal_case() {
        assert_eq!(ItemKind::MusicAlbum.as_str(), "MusicAlbum");
        assert_eq!(
            serde_json::to_value(ItemKind::MusicArtist).unwrap(),
            serde_json::json!("MusicArtist")
        );
    }

    #[test]
    fn sort_order_aliases_match_canonical() {
        assert_eq!(SortOrder::Asc, SortOrder::Ascending);
        assert_eq!(SortOrder::Desc, SortOrder::Descending);
    }

    #[test]
    fn csv_joins_tokens_with_commas() {
        let kinds = [ItemKind::MusicAlbum, ItemKind::MusicArtist, ItemKind::Audio];
        assert_eq!(
            csv(&kinds, ItemKind::as_str),
            "MusicAlbum,MusicArtist,Audio"
        );
    }

    #[test]
    fn image_type_round_trips() {
        for it in [
            ImageType::Primary,
            ImageType::Backdrop,
            ImageType::Thumb,
            ImageType::Logo,
            ImageType::Art,
            ImageType::Banner,
            ImageType::Disc,
            ImageType::Box,
            ImageType::Screenshot,
            ImageType::Menu,
            ImageType::Chapter,
            ImageType::BoxRear,
            ImageType::Profile,
        ] {
            let s = it.as_str();
            let back: ImageType = serde_json::from_value(serde_json::json!(s)).unwrap();
            assert_eq!(back, it, "round trip {s}");
        }
    }
}
