//! Contract-test harness — insta snapshots + wiremock fixtures.
//!
//! Each test:
//! 1. Loads a golden JSON fixture from `tests/contract/fixtures/<name>.json`.
//! 2. Mounts it behind a `wiremock::MockServer` route.
//! 3. Calls the corresponding `JellyfinClient` method.
//! 4. Snapshots the parsed Rust type with `insta::assert_yaml_snapshot!`.
//!
//! On the first run (or after a fixture change) run with `INSTA_UPDATE=always`
//! to accept new snapshot files into `tests/contract/snapshots/`:
//!
//!   INSTA_UPDATE=always cargo test --test contract
//!
//! Subsequent CI runs without that env var will fail when the snapshot differs,
//! catching silent server-side schema drift.
//!
//! See `tests/contract/README.md` for the full workflow.

use jellify_core::client::JellyfinClient;
use jellify_core::models::Paging;
use std::path::Path;
use wiremock::matchers::{method, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read a fixture file from `core/tests/contract/fixtures/<name>.json` and
/// return its contents as a `serde_json::Value`. The path is resolved relative
/// to the Cargo manifest directory so the test works regardless of the working
/// directory `cargo test` chooses.
fn load_fixture(name: &str) -> serde_json::Value {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let fixture_path = Path::new(manifest)
        .join("tests")
        .join("contract")
        .join("fixtures")
        .join(format!("{name}.json"));
    let text = std::fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("Could not read fixture {fixture_path:?}: {e}"));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("Invalid JSON in fixture {fixture_path:?}: {e}"))
}

/// Build an unauthenticated `JellyfinClient` pointing at the given mock server.
fn unauthenticated_client(server: &MockServer) -> JellyfinClient {
    JellyfinClient::new(
        &server.uri(),
        "contract-device".into(),
        "Contract Test".into(),
    )
    .expect("client creation should not fail with a valid URL")
}

/// Build an authenticated `JellyfinClient` with a fake token and user-id.
/// No round-trip to the server is needed — we inject the session directly.
fn authenticated_client(server: &MockServer) -> JellyfinClient {
    let mut client = unauthenticated_client(server);
    client.set_session("fake-token".into(), "user-id-contract".into());
    client
}

// ---------------------------------------------------------------------------
// Contract tests
// ---------------------------------------------------------------------------

/// `GET /Users/{userId}/Items?ParentId=…&IncludeItemTypes=Audio` →
/// `Vec<Track>`.
///
/// Fixture: `album_tracks.json` — a minimal Items envelope with two Audio
/// items. The snapshot pins the parsed `Track` structs so any field-mapping
/// regression in `RawItem → Track` is immediately visible as a snapshot diff.
#[tokio::test]
async fn contract_album_tracks() {
    let server = MockServer::start().await;
    let fixture = load_fixture("album_tracks");

    Mock::given(method("GET"))
        .and(path_regex(r"/Users/[^/]+/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(fixture))
        .mount(&server)
        .await;

    let client = authenticated_client(&server);
    let tracks = client
        .album_tracks("album-abc")
        .await
        .expect("album_tracks should succeed");

    insta::assert_yaml_snapshot!("album_tracks", tracks);
}

/// `GET /Items/{itemId}/Similar` → `Vec<ItemRef>`.
///
/// Fixture: `similar_items.json` — two items of different types (`MusicAlbum`,
/// `MusicArtist`). Pins the `ItemRef` shape including the `kind` field that
/// drives UI dispatch.
#[tokio::test]
async fn contract_similar_items() {
    let server = MockServer::start().await;
    let fixture = load_fixture("similar_items");

    Mock::given(method("GET"))
        .and(path_regex(r"/Items/[^/]+/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(fixture))
        .mount(&server)
        .await;

    let client = authenticated_client(&server);
    let refs = client
        .similar_items("album-abc", 10)
        .await
        .expect("similar_items should succeed");

    insta::assert_yaml_snapshot!("similar_items", refs);
}

/// `GET /Users/{userId}/Items?SearchTerm=…` → `SearchResults`.
///
/// Fixture: `search.json` — one artist, one album, one track. Pins the
/// tri-bucket `SearchResults` shape so type-dispatch regressions are caught.
#[tokio::test]
async fn contract_search() {
    let server = MockServer::start().await;
    let fixture = load_fixture("search");

    Mock::given(method("GET"))
        .and(path_regex(r"/Users/[^/]+/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(fixture))
        .mount(&server)
        .await;

    let client = authenticated_client(&server);
    let results = client
        .search("Searchable", Paging::new(0, 50))
        .await
        .expect("search should succeed");

    insta::assert_yaml_snapshot!("search", results);
}
