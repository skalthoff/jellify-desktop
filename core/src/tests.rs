use crate::client::JellyfinClient;
use crate::error::JellifyError;
use crate::models::{ImageType, Paging};
use crate::storage::{CredentialStore, Database};
use crate::{CoreConfig, JellifyCore};
use serde_json::json;
use std::sync::Once;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn mock_client(base: &str) -> JellyfinClient {
    JellyfinClient::new(base, "test-device".into(), "Test Device".into()).unwrap()
}

/// Placeholder credentials for wiremock-backed tests. These are not real
/// secrets — the mock server accepts any value and returns a canned
/// `AccessToken` regardless.
fn test_credentials() -> (&'static str, &'static str) {
    ("mock-user", "mock-secret-for-wiremock")
}

/// Register a process-wide in-memory credential store as `keyring`'s default
/// the first time a test touches the credential layer. Without this, on macOS
/// the crate's `apple-native` feature would route every test into the real
/// user keychain — which both pollutes the login keychain across runs and
/// would flake in a headless CI environment.
///
/// `keyring`'s built-in `mock` builder hands out a brand-new `MockCredential`
/// on every `Entry::new`, so it can't round-trip `save → load` across two
/// `Entry` instances (which is exactly what `CredentialStore::save_token`
/// followed by `CredentialStore::load_token` does). Our shim keeps one
/// `HashMap` keyed on `(service, user)` so saves are visible to subsequent
/// loads, which is the behaviour we need to exercise `resume_session`.
///
/// Tests still need to pick distinct `(server_id, username)` pairs — the
/// harness intentionally does NOT clear the map between tests because tearing
/// it down is racy under `cargo test`'s default parallelism.
fn install_mock_keyring() {
    use keyring::credential::{
        Credential, CredentialApi, CredentialBuilder, CredentialBuilderApi, CredentialPersistence,
    };
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};

    type Store = Arc<Mutex<HashMap<(String, String), Vec<u8>>>>;

    fn store() -> Store {
        static STORE: OnceLock<Store> = OnceLock::new();
        STORE
            .get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
            .clone()
    }

    struct SharedMockCredential {
        service: String,
        user: String,
        store: Store,
    }

    impl CredentialApi for SharedMockCredential {
        fn set_secret(&self, password: &[u8]) -> keyring::Result<()> {
            self.store
                .lock()
                .unwrap()
                .insert((self.service.clone(), self.user.clone()), password.to_vec());
            Ok(())
        }

        fn get_secret(&self) -> keyring::Result<Vec<u8>> {
            self.store
                .lock()
                .unwrap()
                .get(&(self.service.clone(), self.user.clone()))
                .cloned()
                .ok_or(keyring::Error::NoEntry)
        }

        fn delete_credential(&self) -> keyring::Result<()> {
            self.store
                .lock()
                .unwrap()
                .remove(&(self.service.clone(), self.user.clone()))
                .map(|_| ())
                .ok_or(keyring::Error::NoEntry)
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }
    }

    struct SharedMockBuilder;

    impl CredentialBuilderApi for SharedMockBuilder {
        fn build(
            &self,
            _target: Option<&str>,
            service: &str,
            user: &str,
        ) -> keyring::Result<Box<Credential>> {
            Ok(Box::new(SharedMockCredential {
                service: service.to_string(),
                user: user.to_string(),
                store: store(),
            }))
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }

        fn persistence(&self) -> CredentialPersistence {
            CredentialPersistence::ProcessOnly
        }
    }

    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let builder: Box<CredentialBuilder> = Box::new(SharedMockBuilder);
        keyring::set_default_credential_builder(builder);
    });
}

#[tokio::test]
async fn public_info_parses() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "ServerName": "Home Jellyfin",
            "Version": "10.10.0",
            "Id": "abc123"
        })))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let info = client.public_info().await.unwrap();
    assert_eq!(info.server_name.as_deref(), Some("Home Jellyfin"));
    assert_eq!(info.version.as_deref(), Some("10.10.0"));
}

#[tokio::test]
async fn authenticate_by_name_captures_session() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "xyz-token",
            "ServerId": "server-id-1",
            "ServerName": "My Jellyfin",
            "User": {
                "Id": "user-id-1",
                "Name": "soren",
                "ServerId": "server-id-1",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    let session = client.authenticate_by_name("soren", "pw").await.unwrap();
    assert_eq!(session.access_token, "xyz-token");
    assert_eq!(session.user.id, "user-id-1");
    assert_eq!(session.server.name, "My Jellyfin");
}

#[tokio::test]
async fn album_tracks_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t",
            "ServerId": "s",
            "ServerName": "S",
            "User": { "Id": "u1", "Name": "user", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Yona", "Type": "Audio",
                    "AlbumId": "a1", "Album": "The Deep End",
                    "AlbumArtist": "Saloli", "Artists": ["Saloli"],
                    "IndexNumber": 3, "ParentIndexNumber": 1,
                    "ProductionYear": 2020,
                    "RunTimeTicks": 2220000000u64,
                    "UserData": { "IsFavorite": true, "PlayCount": 7 },
                    "ImageTags": { "Primary": "abcd" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("user", "pw").await.unwrap();
    let tracks = client.album_tracks("a1").await.unwrap();
    assert_eq!(tracks.len(), 1);
    let t = &tracks[0];
    assert_eq!(t.name, "Yona");
    assert_eq!(t.artist_name, "Saloli");
    assert!(t.is_favorite);
    assert_eq!(t.play_count, 7);
    assert!((t.duration_seconds() - 222.0).abs() < 0.001);
}

/// Asserts the query parameters sent by `album_tracks` (#570, #571):
/// - `Recursive=true` so multi-disc child items are returned
/// - `SortBy` and `SortOrder` are parallel comma-separated arrays (3 fields
///   each) so track ordering is well-defined on Jellyfin
#[tokio::test]
async fn album_tracks_query_params() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "user", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("user", "pw").await.unwrap();
    let _ = client.album_tracks("album-42").await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");

    // #570 — must traverse child items for multi-disc albums
    assert!(
        q.contains("Recursive=true"),
        "missing Recursive=true, got: {q}"
    );

    // #571 — SortBy and SortOrder must be parallel arrays of equal length.
    // URL encoding: ',' → '%2C'.
    assert!(
        q.contains("SortBy=ParentIndexNumber%2CIndexNumber%2CSortName"),
        "unexpected SortBy, got: {q}"
    );
    assert!(
        q.contains("SortOrder=Ascending%2CAscending%2CAscending"),
        "SortOrder must have one entry per SortBy field, got: {q}"
    );

    assert!(
        q.contains("ParentId=album-42"),
        "missing ParentId, got: {q}"
    );
}

/// Covers the Artist "Top Tracks" endpoint wired for #229. Asserts the
/// query shape (ArtistIds, IncludeItemTypes=Audio, SortBy=PlayCount,
/// SortOrder=Descending, Limit) and that the parsed tracks carry the
/// `play_count` the UI rank sort depends on.
#[tokio::test]
async fn artist_top_tracks_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Hit Song", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Greatest Hits",
                    "AlbumArtist": "Solo", "Artists": ["Solo"],
                    "RunTimeTicks": 1200000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 42 },
                    "ImageTags": { "Primary": "imgA" }
                },
                {
                    "Id": "t2", "Name": "Deeper Cut", "Type": "Audio",
                    "AlbumId": "a2", "Album": "B-Sides",
                    "AlbumArtist": "Solo", "Artists": ["Solo"],
                    "RunTimeTicks": 1500000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 5 },
                    "ImageTags": { "Primary": "imgB" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.artist_top_tracks("artist-xyz", 5).await.unwrap();

    assert_eq!(tracks.len(), 2);
    assert_eq!(tracks[0].name, "Hit Song");
    assert_eq!(tracks[0].play_count, 42);
    assert_eq!(tracks[1].play_count, 5);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("ArtistIds=artist-xyz"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=5"), "query: {q}");
    // `PlayCount,SortName` is URL-encoded as `PlayCount%2CSortName`.
    assert!(
        q.contains("SortBy=PlayCount%2CSortName"),
        "expected play-count sort, got: {q}"
    );
    assert!(
        q.contains("SortOrder=Descending%2CAscending"),
        "expected descending play-count sort, got: {q}"
    );
}

/// Zero `limit` should clamp to `1` (matching the pattern used for other
/// `Paging`/`Limit` endpoints) so the server never gets a no-op query.
#[tokio::test]
async fn artist_top_tracks_clamps_zero_limit_to_one() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.artist_top_tracks("artist-xyz", 0).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=1"), "expected clamp to Limit=1, got: {q}");
}

#[tokio::test]
async fn recently_played_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Echo", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Tides",
                    "AlbumArtist": "Ocean", "Artists": ["Ocean"],
                    "RunTimeTicks": 1800000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 3 },
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1234
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .recently_played(Some("lib-1"), Paging::new(0, 50))
        .await
        .unwrap();

    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 1234);
    let tracks = page.items;
    assert_eq!(tracks[0].name, "Echo");
    assert_eq!(tracks[0].play_count, 3);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("SortBy=DatePlayed"), "query: {q}");
    assert!(q.contains("SortOrder=Descending"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    assert!(q.contains("ParentId=lib-1"), "query: {q}");
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "ParentId"),
        "Fields should include ParentId, got: {fields}"
    );
}

#[tokio::test]
async fn recently_played_omits_parent_id_when_none() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client
        .recently_played(None, Paging::new(5, 25))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(!q.contains("ParentId="), "unexpected ParentId: {q}");
    assert!(q.contains("Limit=25"), "query: {q}");
    assert!(q.contains("StartIndex=5"), "query: {q}");
    assert!(q.contains("SortBy=DatePlayed"), "query: {q}");
    assert!(q.contains("SortOrder=Descending"), "query: {q}");
}

#[tokio::test]
async fn list_tracks_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Aria", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Sunrise",
                    "AlbumArtist": "Colleen", "Artists": ["Colleen"],
                    "ProductionYear": 2019,
                    "RunTimeTicks": 1800000000u64,
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 9876
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .list_tracks(Some("lib-1"), Paging::new(100, 50))
        .await
        .unwrap();

    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 9876);
    assert_eq!(page.items[0].name, "Aria");
    assert_eq!(page.items[0].artist_name, "Colleen");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("StartIndex=100"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
    assert!(q.contains("SortOrder=Ascending"), "query: {q}");
    assert!(q.contains("ParentId=lib-1"), "query: {q}");
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "ParentId"),
        "Fields should include ParentId, got: {fields}"
    );
}

#[tokio::test]
async fn list_tracks_omits_parent_id_when_none() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.list_tracks(None, Paging::new(0, 100)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(!q.contains("ParentId="), "unexpected ParentId: {q}");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Limit=100"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    assert!(q.contains("SortBy=SortName"), "query: {q}");
    assert!(q.contains("SortOrder=Ascending"), "query: {q}");
}

#[tokio::test]
async fn list_tracks_requires_authenticated_session() {
    // No MockServer routes registered: the guard must short-circuit before
    // any HTTP call. Pointing at a live MockServer means a regression would
    // surface as an unmatched-route error instead of silently hitting a real
    // host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .list_tracks(Some("lib-1"), Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Browse flag assertions — EnableUserData + EnableImages + ImageTypeLimit
// ---------------------------------------------------------------------------

#[tokio::test]
async fn artists_includes_user_data_and_image_flags() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.artists(Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn albums_includes_user_data_and_image_flags() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.albums(Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn latest_albums_includes_user_data_and_image_flags() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/Latest"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([])))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client
        .latest_albums("lib-1", Paging::new(0, 24))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn list_tracks_includes_user_data_and_image_flags() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.list_tracks(None, Paging::new(0, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

#[tokio::test]
async fn recently_played_includes_user_data_and_image_flags() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client
        .recently_played(None, Paging::new(0, 50))
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("EnableImages=true"), "query: {q}");
    assert!(q.contains("ImageTypeLimit=1"), "query: {q}");
}

// ---------------------------------------------------------------------------
// Discovery: instant_mix / suggestions / similar_* / frequently_played
// ---------------------------------------------------------------------------

#[tokio::test]
async fn instant_mix_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/seed-1/InstantMix"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "Radio One", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Starter",
                    "AlbumArtist": "DJ Seed", "Artists": ["DJ Seed"],
                    "RunTimeTicks": 2000000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 0 },
                    "ImageTags": { "Primary": "imgA" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.instant_mix("seed-1", 25).await.unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].name, "Radio One");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("UserId=u1"), "query: {q}");
    assert!(q.contains("Limit=25"), "query: {q}");
}

#[tokio::test]
async fn instant_mix_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.instant_mix("seed-1", 25).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn suggestions_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/Suggestions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "You Might Like", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Discover",
                    "AlbumArtist": "New Artist", "Artists": ["New Artist"],
                    "RunTimeTicks": 1800000000u64,
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.suggestions(12).await.unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].name, "You Might Like");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("UserId=u1"), "query: {q}");
    // Must filter by item type, not MediaType, so only music items are returned
    assert!(
        q.contains("IncludeItemTypes=Audio"),
        "expected IncludeItemTypes in query: {q}"
    );
    assert!(
        !q.contains("MediaType=Audio"),
        "must not send MediaType=Audio (returns movies+TV): {q}"
    );
    assert!(q.contains("EnableUserData=true"), "query: {q}");
    assert!(q.contains("Limit=12"), "query: {q}");
}

#[tokio::test]
async fn suggestions_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.suggestions(12).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn similar_artists_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Artists/artist-1/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a2", "Name": "Similar Artist", "Type": "MusicArtist",
                    "Genres": ["Indie"],
                    "ImageTags": { "Primary": "imgSim" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let artists = client.similar_artists("artist-1", 10).await.unwrap();
    assert_eq!(artists.len(), 1);
    assert_eq!(artists[0].name, "Similar Artist");
    assert_eq!(artists[0].genres, vec!["Indie".to_string()]);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("UserId=u1"), "query: {q}");
    assert!(q.contains("Limit=10"), "query: {q}");
}

#[tokio::test]
async fn similar_albums_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Albums/album-1/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a2", "Name": "Similar Album", "Type": "MusicAlbum",
                    "AlbumArtist": "Sibling",
                    "ProductionYear": 2022, "ChildCount": 9,
                    "ImageTags": { "Primary": "imgAlb" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let albums = client.similar_albums("album-1", 8).await.unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].name, "Similar Album");
    assert_eq!(albums[0].track_count, 9);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=8"), "query: {q}");
    assert!(q.contains("UserId=u1"), "query: {q}");
}

#[tokio::test]
async fn similar_items_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/seed-1/Similar"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a2", "Name": "Similar Album", "Type": "MusicAlbum",
                    "ImageTags": { "Primary": "img1" }
                },
                {
                    "Id": "t2", "Name": "Similar Track", "Type": "Audio",
                    "ImageTags": { "Primary": "img2" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let items = client.similar_items("seed-1", 20).await.unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].kind.as_deref(), Some("MusicAlbum"));
    assert_eq!(items[1].kind.as_deref(), Some("Audio"));
}

#[tokio::test]
async fn frequently_played_tracks_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "t1", "Name": "On Repeat", "Type": "Audio",
                    "AlbumId": "a1", "Album": "Stuck",
                    "AlbumArtist": "Loops", "Artists": ["Loops"],
                    "RunTimeTicks": 1800000000u64,
                    "UserData": { "IsFavorite": false, "PlayCount": 99 },
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client.frequently_played_tracks(50).await.unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].play_count, 99);

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("IncludeItemTypes=Audio"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=50"), "query: {q}");
    // `PlayCount,SortName` is URL-encoded as `PlayCount%2CSortName`.
    assert!(
        q.contains("SortBy=PlayCount%2CSortName"),
        "expected play-count sort, got: {q}"
    );
    assert!(
        q.contains("SortOrder=Descending%2CAscending"),
        "expected descending play-count sort, got: {q}"
    );
}

// ---------------------------------------------------------------------------
// Genres
// ---------------------------------------------------------------------------

#[tokio::test]
async fn genres_builds_query_and_parses_counts() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Genres"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "g-1", "Name": "Ambient",
                    "SongCount": 42, "AlbumCount": 6,
                    "ImageTags": { "Primary": "imgA" }
                },
                {
                    "Id": "g-2", "Name": "Jazz",
                    "SongCount": 110, "AlbumCount": 14,
                    "ImageTags": { "Primary": "imgJ" }
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.genres(Paging::new(0, 100)).await.unwrap();
    assert_eq!(page.total_count, 2);
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].name, "Ambient");
    assert_eq!(page.items[0].song_count, 42);
    assert_eq!(page.items[0].album_count, 6);
    assert_eq!(page.items[1].name, "Jazz");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    assert_eq!(
        get.url.path(),
        "/Genres",
        "should call /Genres, not /MusicGenres"
    );
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("userId=u1"), "query: {q}");
    assert!(q.contains("Limit=100"), "query: {q}");
    assert!(q.contains("StartIndex=0"), "query: {q}");
    let include_types = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "IncludeItemTypes")
        .map(|(_, v)| v.into_owned())
        .expect("expected IncludeItemTypes query param");
    assert!(
        include_types.split(',').any(|t| t == "Audio"),
        "IncludeItemTypes should include Audio, got: {include_types}"
    );
    assert!(
        include_types.split(',').any(|t| t == "MusicAlbum"),
        "IncludeItemTypes should include MusicAlbum, got: {include_types}"
    );
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "ItemCounts"),
        "Fields should include ItemCounts, got: {fields}"
    );
}

#[tokio::test]
async fn items_by_genre_builds_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a1", "Name": "Jazzy", "Type": "MusicAlbum",
                    "AlbumArtist": "Sax Man",
                    "ProductionYear": 2020, "ChildCount": 10,
                    "ImageTags": { "Primary": "imgJ" }
                }
            ],
            "TotalRecordCount": 55
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .items_by_genre("g-1", Paging::new(0, 30))
        .await
        .unwrap();
    assert_eq!(page.total_count, 55);
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].name, "Jazzy");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("GenreIds=g-1"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=MusicAlbum"), "query: {q}");
    assert!(q.contains("Recursive=true"), "query: {q}");
    assert!(q.contains("Limit=30"), "query: {q}");
}

// ---------------------------------------------------------------------------
// Artist detail
// ---------------------------------------------------------------------------

#[tokio::test]
async fn artist_detail_parses_overview_and_backdrops() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("Ids", "artist-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "artist-xyz",
                    "Name": "Ambient Pioneer",
                    "Genres": ["Ambient", "Electronic"],
                    "Overview": "A long biography.",
                    "BackdropImageTags": ["bd1", "bd2"],
                    "ExternalUrls": [
                        { "Name": "MusicBrainz", "Url": "https://mb.example/a" },
                        { "Name": "Last.fm", "Url": "https://last.fm/a" }
                    ],
                    "ImageTags": { "Primary": "imgArtist" }
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let detail = client.artist_detail("artist-xyz").await.unwrap();
    assert_eq!(detail.id, "artist-xyz");
    assert_eq!(detail.name, "Ambient Pioneer");
    assert_eq!(detail.overview.as_deref(), Some("A long biography."));
    assert_eq!(
        detail.backdrop_image_tags,
        vec!["bd1".to_string(), "bd2".to_string()]
    );
    assert_eq!(detail.external_urls.len(), 2);
    assert_eq!(detail.external_urls[0].name, "MusicBrainz");
    assert_eq!(detail.external_urls[0].url, "https://mb.example/a");
    assert_eq!(detail.image_tag.as_deref(), Some("imgArtist"));

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET" && r.url.path() == "/Items")
        .expect("expected a GET /Items");
    let fields = get
        .url
        .query_pairs()
        .find(|(k, _)| k == "Fields")
        .map(|(_, v)| v.into_owned())
        .expect("expected Fields query param");
    assert!(
        fields.split(',').any(|f| f == "Overview"),
        "Fields should include Overview, got: {fields}"
    );
    assert!(
        fields.split(',').any(|f| f == "ExternalUrls"),
        "Fields should include ExternalUrls, got: {fields}"
    );
    assert!(
        fields.split(',').any(|f| f == "BackdropImageTags"),
        "Fields should include BackdropImageTags, got: {fields}"
    );
}

#[tokio::test]
async fn artist_detail_returns_server_404_on_empty_items() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.artist_detail("missing").await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::Server { status: 404, .. }),
        "expected 404 Server error, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Lyrics
// ---------------------------------------------------------------------------

#[tokio::test]
async fn lyrics_parses_synced_payload() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // 10_000_000 ticks == 1.0 seconds; 50_000_000 == 5.0 seconds.
    Mock::given(method("GET"))
        .and(path("/Audio/track-1/Lyrics"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Metadata": { "IsSynced": true },
            "Lyrics": [
                { "Start": 10000000i64, "Text": "First line" },
                { "Start": 50000000i64, "Text": "Second line" }
            ]
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let lyrics = client
        .lyrics("track-1")
        .await
        .unwrap()
        .expect("expected Some(Lyrics) on 200");
    assert!(lyrics.is_synced);
    assert_eq!(lyrics.lines.len(), 2);
    assert!((lyrics.lines[0].time_seconds - 1.0).abs() < 0.0001);
    assert_eq!(lyrics.lines[0].text, "First line");
    assert!((lyrics.lines[1].time_seconds - 5.0).abs() < 0.0001);
}

#[tokio::test]
async fn lyrics_parses_plain_text() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Audio/track-2/Lyrics"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Metadata": { "IsSynced": false },
            "Lyrics": [
                { "Start": 0i64, "Text": "Just the words\nno timing" }
            ]
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let lyrics = client.lyrics("track-2").await.unwrap().unwrap();
    assert!(!lyrics.is_synced);
    assert_eq!(lyrics.lines.len(), 1);
    assert!((lyrics.lines[0].time_seconds - 0.0).abs() < 0.0001);
    assert!(lyrics.lines[0].text.contains("Just the words"));
}

#[tokio::test]
async fn lyrics_returns_none_on_404() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Audio/track-404/Lyrics"))
        .respond_with(ResponseTemplate::new(404).set_body_string("Not found"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let result = client.lyrics("track-404").await.unwrap();
    assert!(result.is_none(), "expected None on 404, got {result:?}");
}

#[tokio::test]
async fn lyrics_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.lyrics("any").await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn albums_uses_paging() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.albums(Paging::new(10, 50)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=50"), "query: {q}");
    assert!(q.contains("StartIndex=10"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=MusicAlbum"), "query: {q}");
}

#[tokio::test]
async fn albums_exposes_total_record_count() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "a1", "Name": "First", "Type": "MusicAlbum",
                    "AlbumArtist": "Artist",
                    "ProductionYear": 2020, "ChildCount": 8,
                    "ImageTags": { "Primary": "t1" }
                },
                {
                    "Id": "a2", "Name": "Second", "Type": "MusicAlbum",
                    "AlbumArtist": "Artist",
                    "ProductionYear": 2021, "ChildCount": 10,
                    "ImageTags": { "Primary": "t2" }
                }
            ],
            "TotalRecordCount": 4321
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.albums(Paging::new(0, 2)).await.unwrap();
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.total_count, 4321);
    assert_eq!(page.items[0].name, "First");
    assert_eq!(page.items[1].name, "Second");
}

#[tokio::test]
async fn artists_exposes_total_record_count_and_paging() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Artists/AlbumArtists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "ar1", "Name": "Colleen", "Type": "MusicArtist",
                    "ImageTags": { "Primary": "img" }
                }
            ],
            "TotalRecordCount": 999
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client.artists(Paging::new(25, 100)).await.unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 999);
    assert_eq!(page.items[0].name, "Colleen");

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(q.contains("Limit=100"), "query: {q}");
    assert!(q.contains("StartIndex=25"), "query: {q}");
    assert!(q.contains("IncludeItemTypes=MusicArtist"), "query: {q}");
}

#[tokio::test]
async fn latest_albums_builds_expected_query_and_parses_unwrapped_array() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // `/Items/Latest` returns a bare array, not `{ Items, TotalRecordCount }`.
    Mock::given(method("GET"))
        .and(path("/Items/Latest"))
        .and(query_param("UserId", "u1"))
        .and(query_param("ParentId", "lib-music"))
        .and(query_param("IncludeItemTypes", "MusicAlbum"))
        .and(query_param("Limit", "24"))
        .and(query_param("GroupItems", "true"))
        .respond_with(|req: &Request| {
            // Sanity-check that no unexpected extra params were added and that
            // the full expected set (including `Fields`) is present on the
            // actual request. Building a set from `query_pairs` and comparing
            // to the expected set catches both extra keys and missing ones.
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            assert_eq!(pairs.get("UserId").map(String::as_str), Some("u1"));
            assert_eq!(pairs.get("ParentId").map(String::as_str), Some("lib-music"));
            assert_eq!(
                pairs.get("IncludeItemTypes").map(String::as_str),
                Some("MusicAlbum")
            );
            assert_eq!(pairs.get("Limit").map(String::as_str), Some("24"));
            assert_eq!(pairs.get("GroupItems").map(String::as_str), Some("true"));
            assert_eq!(
                pairs.get("Fields").map(String::as_str),
                Some("Genres,ProductionYear,ChildCount,PrimaryImageAspectRatio")
            );
            assert_eq!(
                pairs.get("EnableUserData").map(String::as_str),
                Some("true")
            );
            assert_eq!(pairs.get("EnableImages").map(String::as_str), Some("true"));
            assert_eq!(pairs.get("ImageTypeLimit").map(String::as_str), Some("1"));
            let expected_keys: std::collections::HashSet<&str> = [
                "UserId",
                "ParentId",
                "IncludeItemTypes",
                "Limit",
                "GroupItems",
                "Fields",
                "EnableUserData",
                "EnableImages",
                "ImageTypeLimit",
            ]
            .into_iter()
            .collect();
            let actual_keys: std::collections::HashSet<&str> =
                pairs.keys().map(String::as_str).collect();
            assert_eq!(
                actual_keys, expected_keys,
                "unexpected or missing query params on /Items/Latest request"
            );
            ResponseTemplate::new(200).set_body_json(json!([
                {
                    "Id": "a1", "Name": "The Deep End", "Type": "MusicAlbum",
                    "AlbumArtist": "Saloli", "Artists": ["Saloli"],
                    "ProductionYear": 2020, "ChildCount": 8,
                    "RunTimeTicks": 18000000000u64,
                    "ImageTags": { "Primary": "abcd" }
                },
                {
                    "Id": "a2", "Name": "Spiral", "Type": "MusicAlbum",
                    "AlbumArtist": "Colleen", "Artists": ["Colleen"],
                    "ProductionYear": 2023, "ChildCount": 11,
                    "ImageTags": {}
                }
            ]))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .latest_albums("lib-music", Paging::new(0, 24))
        .await
        .unwrap();
    let albums = page.items;
    assert_eq!(albums.len(), 2);
    // `/Items/Latest` doesn't report TotalRecordCount, so `total_count` is
    // the raw number of items the server returned for this request.
    assert_eq!(page.total_count, 2);
    assert_eq!(albums[0].name, "The Deep End");
    assert_eq!(albums[0].artist_name, "Saloli");
    assert_eq!(albums[0].year, Some(2020));
    assert_eq!(albums[0].track_count, 8);
    assert_eq!(albums[0].image_tag.as_deref(), Some("abcd"));
    assert_eq!(albums[1].name, "Spiral");
    assert!(albums[1].image_tag.is_none());
}

#[tokio::test]
async fn latest_albums_applies_offset_client_side() {
    // `/Items/Latest` doesn't support `StartIndex`, so `latest_albums`
    // fetches `offset + limit` items and slices the tail client-side.
    // The server sees `Limit=offset+limit` on the outbound request.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items/Latest"))
        .respond_with(|req: &Request| {
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            // `Limit` is the requested offset+limit so the slice has what to
            // skip. `StartIndex` must NOT be sent — the endpoint rejects it.
            assert_eq!(pairs.get("Limit").map(String::as_str), Some("7"));
            assert!(
                !pairs.contains_key("StartIndex"),
                "latest_albums must not send StartIndex"
            );
            ResponseTemplate::new(200).set_body_json(json!([
                { "Id": "a1", "Name": "One", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a2", "Name": "Two", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a3", "Name": "Three", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a4", "Name": "Four", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a5", "Name": "Five", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a6", "Name": "Six", "Type": "MusicAlbum", "ImageTags": {} },
                { "Id": "a7", "Name": "Seven", "Type": "MusicAlbum", "ImageTags": {} }
            ]))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    // offset=4, limit=3 → request Limit=7, skip 4, take 3 → items 5..7
    let page = client
        .latest_albums("lib-music", Paging::new(4, 3))
        .await
        .unwrap();
    let names: Vec<&str> = page.items.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["Five", "Six", "Seven"]);
    assert_eq!(page.total_count, 7);
}

#[tokio::test]
async fn latest_albums_requires_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client
        .latest_albums("lib-music", Paging::new(0, 24))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn user_playlists_filters_to_data_path_and_builds_query() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "lib-pl"))
        .and(query_param("UserId", "u1"))
        .and(query_param("IncludeItemTypes", "Playlist"))
        .and(query_param("Limit", "20"))
        .and(query_param("StartIndex", "5"))
        .and(query_param("Fields", "ChildCount,Path"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "p1", "Name": "My Mix", "Type": "Playlist",
                    "ChildCount": 12,
                    "RunTimeTicks": 42_000_000_000u64,
                    "Path": "/config/data/users/u1/playlists/my-mix",
                    "ImageTags": { "Primary": "tag-1" }
                },
                {
                    "Id": "p2", "Name": "Community Top 40", "Type": "Playlist",
                    "ChildCount": 40,
                    "Path": "/media/playlists/community-top-40",
                    "ImageTags": {}
                }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .user_playlists("lib-pl", Paging::new(5, 20))
        .await
        .unwrap();
    let playlists = page.items;

    assert_eq!(playlists.len(), 1);
    // `total_count` surfaces the server's unfiltered TotalRecordCount —
    // the paging UI needs this to know when a follow-up page would yield
    // more results even if the client-side /data/ filter removed some.
    assert_eq!(page.total_count, 2);
    assert_eq!(playlists[0].id, "p1");
    assert_eq!(playlists[0].name, "My Mix");
    assert_eq!(playlists[0].track_count, 12);
    assert_eq!(playlists[0].image_tag.as_deref(), Some("tag-1"));
}

#[tokio::test]
async fn public_playlists_filters_out_data_path() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "p1", "Name": "My Mix", "Type": "Playlist",
                    "ChildCount": 12,
                    "Path": "/config/data/users/u1/playlists/my-mix"
                },
                {
                    "Id": "p2", "Name": "Community Top 40", "Type": "Playlist",
                    "ChildCount": 40,
                    "Path": "/media/playlists/community-top-40",
                    "ImageTags": { "Primary": "tag-2" }
                },
                {
                    "Id": "p3", "Name": "No Path Public", "Type": "Playlist",
                    "ChildCount": 5
                }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .public_playlists("lib-pl", Paging::new(0, 50))
        .await
        .unwrap();
    let playlists = page.items;

    // Both the community playlist (non-/data/ path) and the playlist with no
    // `Path` at all are treated as public — absence cannot prove ownership.
    assert_eq!(playlists.len(), 2);
    assert_eq!(page.total_count, 3);
    let ids: Vec<&str> = playlists.iter().map(|p| p.id.as_str()).collect();
    assert!(ids.contains(&"p2"), "public_playlists should include p2");
    assert!(ids.contains(&"p3"), "public_playlists should include p3");
    let community = playlists.iter().find(|p| p.id == "p2").unwrap();
    assert_eq!(community.track_count, 40);
    assert_eq!(community.image_tag.as_deref(), Some("tag-2"));
}

#[tokio::test]
async fn user_playlists_empty_when_server_returns_no_items() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [], "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let user = client
        .user_playlists("lib-pl", Paging::new(0, 50))
        .await
        .unwrap();
    let public = client
        .public_playlists("lib-pl", Paging::new(0, 50))
        .await
        .unwrap();
    assert!(user.items.is_empty());
    assert_eq!(user.total_count, 0);
    assert!(public.items.is_empty());
    assert_eq!(public.total_count, 0);
}

#[tokio::test]
async fn playlists_require_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client
        .user_playlists("lib-pl", Paging::new(0, 20))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
    let err = client
        .public_playlists("lib-pl", Paging::new(0, 20))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn playlist_tracks_preserves_order_and_builds_query() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-1"))
        .and(query_param("UserId", "u1"))
        .and(query_param("IncludeItemTypes", "Audio"))
        .and(query_param("Limit", "50"))
        .and(query_param("StartIndex", "0"))
        .and(query_param("Fields", "MediaSources,ParentId,Path,SortName"))
        .respond_with(|req: &Request| {
            // Playlist order is load-bearing: the client must NOT send
            // SortBy/SortOrder for this endpoint.
            let pairs: std::collections::HashMap<_, _> =
                req.url.query_pairs().into_owned().collect();
            assert!(
                !pairs.contains_key("SortBy"),
                "playlist_tracks must not set SortBy"
            );
            assert!(
                !pairs.contains_key("SortOrder"),
                "playlist_tracks must not set SortOrder"
            );
            // Auth header must be present.
            let auth = req
                .headers
                .get(reqwest::header::AUTHORIZATION)
                .expect("expected Authorization header")
                .to_str()
                .unwrap();
            assert!(auth.contains("Token=\"t\""), "auth header: {auth}");
            ResponseTemplate::new(200).set_body_json(json!({
                "Items": [
                    {
                        "Id": "t1", "Name": "First", "Type": "Audio",
                        "AlbumId": "a1", "Album": "Album One",
                        "AlbumArtist": "Artist A", "Artists": ["Artist A"],
                        "RunTimeTicks": 1800000000u64,
                        "ImageTags": { "Primary": "img-1" }
                    },
                    {
                        "Id": "t2", "Name": "Second", "Type": "Audio",
                        "AlbumId": "a2", "Album": "Album Two",
                        "AlbumArtist": "Artist B", "Artists": ["Artist B"],
                        "RunTimeTicks": 2220000000u64,
                        "ImageTags": { "Primary": "img-2" }
                    },
                    {
                        "Id": "t3", "Name": "Third", "Type": "Audio",
                        "AlbumId": "a3", "Album": "Album Three",
                        "AlbumArtist": "Artist C", "Artists": ["Artist C"],
                        "RunTimeTicks": 2000000000u64,
                        "ImageTags": { "Primary": "img-3" }
                    }
                ],
                "TotalRecordCount": 3
            }))
        })
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("pl-1", Paging::new(0, 50))
        .await
        .unwrap();
    let tracks = page.items;

    // Server order must be preserved exactly.
    assert_eq!(tracks.len(), 3);
    assert_eq!(page.total_count, 3);
    assert_eq!(tracks[0].id, "t1");
    assert_eq!(tracks[0].name, "First");
    assert_eq!(tracks[1].id, "t2");
    assert_eq!(tracks[1].name, "Second");
    assert_eq!(tracks[2].id, "t3");
    assert_eq!(tracks[2].name, "Third");
}

#[tokio::test]
async fn playlist_tracks_uses_paging() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("ParentId", "pl-1"))
        .and(query_param("Limit", "25"))
        .and(query_param("StartIndex", "10"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 1200
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let page = client
        .playlist_tracks("pl-1", Paging::new(10, 25))
        .await
        .unwrap();
    assert!(page.items.is_empty());
    // Even when this page is empty, callers can still see there's more to
    // fetch — important for the "page until total_count" loop in AppModel.
    assert_eq!(page.total_count, 1200);
}

#[tokio::test]
async fn playlist_tracks_requires_authenticated_session() {
    // No MockServer routes registered: the guard must short-circuit before
    // any HTTP call. Pointing at a live MockServer means a regression would
    // surface as an unmatched-route error instead of silently hitting a real
    // host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .playlist_tracks("pl-1", Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn fetch_item_builds_expected_query_and_extracts_first() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(wiremock::matchers::query_param("Ids", "item-xyz"))
        .and(wiremock::matchers::query_param(
            "Fields",
            "Overview,Genres,Tags,ProductionYear",
        ))
        .and(wiremock::matchers::query_param("userId", "u1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "item-xyz",
                    "Name": "Mystery",
                    "Type": "MusicAlbum",
                    "Overview": "A very fine record.",
                    "Genres": ["Ambient", "Electronic"],
                    "Tags": ["Downtempo"],
                    "ProductionYear": 2024
                }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let value = client
        .fetch_item(
            "item-xyz",
            &["Overview", "Genres", "Tags", "ProductionYear"],
        )
        .await
        .unwrap();
    assert_eq!(value.get("Id").and_then(|v| v.as_str()), Some("item-xyz"));
    assert_eq!(
        value.get("Overview").and_then(|v| v.as_str()),
        Some("A very fine record.")
    );
    assert_eq!(
        value.get("ProductionYear").and_then(|v| v.as_i64()),
        Some(2024)
    );
}

#[tokio::test]
async fn fetch_item_empty_items_returns_not_found() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.fetch_item("missing-id", &[]).await.unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 404),
        other => panic!("expected Server 404, got {other:?}"),
    }
}

#[tokio::test]
async fn fetch_item_without_session_returns_not_authenticated() {
    // No MockServer endpoints registered for /Items: the guard must short-circuit
    // before any network call. We still point at a live MockServer so that if
    // the guard regresses, the request would surface as an unmatched-route error
    // rather than silently hitting an unrelated host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.fetch_item("anything", &[]).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn search_hints_builds_expected_query_and_parses() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Search/Hints"))
        .and(query_param("userId", "u1"))
        .and(query_param("searchTerm", "colleen"))
        .and(query_param(
            "includeItemTypes",
            "Audio,MusicAlbum,MusicArtist,Playlist",
        ))
        .and(query_param("limit", "24"))
        .and(query_param("startIndex", "0"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [
                {
                    "Id": "artist-1",
                    "Name": "Colleen",
                    "Type": "MusicArtist",
                    "MediaType": "Unknown",
                    "MatchedTerm": "colleen",
                    "PrimaryImageTag": "img-artist",
                    "Artists": []
                },
                {
                    "Id": "album-1",
                    "Name": "The Weighing of the Heart",
                    "Type": "MusicAlbum",
                    "MediaType": "Unknown",
                    "AlbumArtist": "Colleen",
                    "Artists": ["Colleen"],
                    "MatchedTerm": "colleen",
                    "PrimaryImageTag": "img-album",
                    "ProductionYear": 2013,
                    "RunTimeTicks": 18000000000u64
                },
                {
                    "Id": "track-1",
                    "Name": "Push the Boat Onto the Sand",
                    "Type": "Audio",
                    "MediaType": "Audio",
                    "Album": "The Weighing of the Heart",
                    "AlbumId": "album-1",
                    "AlbumArtist": "Colleen",
                    "Artists": ["Colleen"],
                    "MatchedTerm": "colleen",
                    "IndexNumber": 3,
                    "ParentIndexNumber": 1,
                    "RunTimeTicks": 2220000000u64,
                    "PrimaryImageTag": "img-track"
                }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client
        .search_hints("colleen", Paging::new(0, 24))
        .await
        .unwrap();

    assert_eq!(results.total_record_count, 3);
    assert_eq!(results.search_hints.len(), 3);

    let artist = &results.search_hints[0];
    assert_eq!(artist.id, "artist-1");
    assert_eq!(artist.name, "Colleen");
    assert_eq!(artist.kind.as_deref(), Some("MusicArtist"));
    assert_eq!(artist.matched_term.as_deref(), Some("colleen"));
    assert_eq!(artist.primary_image_tag.as_deref(), Some("img-artist"));

    let album = &results.search_hints[1];
    assert_eq!(album.kind.as_deref(), Some("MusicAlbum"));
    assert_eq!(album.album_artist.as_deref(), Some("Colleen"));
    assert_eq!(album.production_year, Some(2013));
    assert_eq!(album.runtime_ticks, Some(18_000_000_000));

    let track = &results.search_hints[2];
    assert_eq!(track.kind.as_deref(), Some("Audio"));
    assert_eq!(track.media_type.as_deref(), Some("Audio"));
    assert_eq!(track.album.as_deref(), Some("The Weighing of the Heart"));
    assert_eq!(track.album_id.as_deref(), Some("album-1"));
    assert_eq!(track.index_number, Some(3));
    assert_eq!(track.parent_index_number, Some(1));
}

#[tokio::test]
async fn search_hints_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .search_hints("anything", Paging::new(0, 24))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn search_hints_clamps_zero_limit_to_one() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Search/Hints"))
        .and(query_param("limit", "1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client.search_hints("x", Paging::new(0, 0)).await.unwrap();
    assert_eq!(results.total_record_count, 0);
    assert!(results.search_hints.is_empty());
}

#[tokio::test]
async fn search_paginates_and_exposes_total_record_count() {
    // The combined-type search endpoint must forward offset/limit as
    // StartIndex/Limit and surface TotalRecordCount so the UI can offer
    // "Show all N results" affordances. Items are bucketed by `Type` into
    // the SearchResults struct's three arrays.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .and(query_param("SearchTerm", "mountain"))
        .and(query_param(
            "IncludeItemTypes",
            "MusicArtist,MusicAlbum,Audio",
        ))
        .and(query_param("Limit", "25"))
        .and(query_param("StartIndex", "10"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                {
                    "Id": "artist-1", "Name": "Mountain Goats", "Type": "MusicArtist",
                    "ImageTags": { "Primary": "a1" }
                },
                {
                    "Id": "album-1", "Name": "All Hail West Texas", "Type": "MusicAlbum",
                    "AlbumArtist": "The Mountain Goats", "Artists": ["The Mountain Goats"],
                    "ProductionYear": 2002, "ChildCount": 14,
                    "ImageTags": { "Primary": "b1" }
                },
                {
                    "Id": "track-1", "Name": "The Best Ever Death Metal Band Out Of Denton", "Type": "Audio",
                    "AlbumId": "album-1", "Album": "All Hail West Texas",
                    "AlbumArtist": "The Mountain Goats", "Artists": ["The Mountain Goats"],
                    "RunTimeTicks": 1680000000u64,
                    "ImageTags": { "Primary": "c1" }
                }
            ],
            "TotalRecordCount": 147
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client
        .search("mountain", Paging::new(10, 25))
        .await
        .unwrap();

    assert_eq!(results.total_record_count, 147);
    assert_eq!(results.artists.len(), 1);
    assert_eq!(results.albums.len(), 1);
    assert_eq!(results.tracks.len(), 1);
    assert_eq!(results.artists[0].name, "Mountain Goats");
    assert_eq!(results.albums[0].name, "All Hail West Texas");
    assert_eq!(
        results.tracks[0].name,
        "The Best Ever Death Metal Band Out Of Denton"
    );
}

#[tokio::test]
async fn search_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .search("anything", Paging::new(0, 50))
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn search_sends_enable_user_data_and_expanded_fields() {
    // Regression for #574: search must include EnableUserData=true and
    // Fields containing UserData + AlbumId so that favorites state and
    // track-to-album links are populated in the response.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .and(query_param("SearchTerm", "radio"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [],
            "TotalRecordCount": 0
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    let (user, secret) = test_credentials();
    client.authenticate_by_name(user, secret).await.unwrap();
    client.search("radio", Paging::new(0, 10)).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let get = requests
        .iter()
        .find(|r| r.method.as_str() == "GET")
        .expect("expected a GET request");
    let q = get.url.query().expect("expected a query string");
    assert!(
        q.contains("EnableUserData=true"),
        "missing EnableUserData=true in query: {q}"
    );
    assert!(
        q.contains("UserData"),
        "Fields must include UserData in query: {q}"
    );
    assert!(
        q.contains("AlbumId"),
        "Fields must include AlbumId in query: {q}"
    );
}

#[tokio::test]
async fn search_hints_forwards_offset_as_start_index() {
    // Regression check for pagination on the typeahead: `paging.offset`
    // must appear as `startIndex` on the outbound request so "Show more"
    // can fetch the next page.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Search/Hints"))
        .and(query_param("limit", "20"))
        .and(query_param("startIndex", "40"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "SearchHints": [],
            "TotalRecordCount": 100
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let results = client.search_hints("q", Paging::new(40, 20)).await.unwrap();
    assert_eq!(results.total_record_count, 100);
}

#[tokio::test]
async fn set_favorite_uses_preferred_endpoint_and_returns_state() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Preferred route: user inferred from token, body returns UserItemData.
    Mock::given(method("POST"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": true,
            "PlayCount": 0,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.set_favorite("item-xyz").await.unwrap();
    assert!(state.is_favorite);
    assert_eq!(state.play_count, Some(0));
    assert!(state.last_played.is_none());

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz")
        .expect("expected POST to preferred favorite endpoint");
    // No body is sent for this endpoint.
    assert!(
        post.body.is_empty(),
        "expected empty body, got {:?}",
        post.body
    );
    // Client must not hit the legacy route when the preferred one succeeds.
    assert!(
        !requests
            .iter()
            .any(|r| r.url.path().starts_with("/Users/u1/FavoriteItems/")),
        "unexpected fallback to legacy route"
    );
}

#[tokio::test]
async fn unset_favorite_uses_preferred_endpoint_and_returns_state() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "PlayCount": 2,
            "LastPlayedDate": "2025-01-02T03:04:05Z"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.unset_favorite("item-xyz").await.unwrap();
    assert!(!state.is_favorite);
    assert_eq!(state.play_count, Some(2));
    assert_eq!(state.last_played.as_deref(), Some("2025-01-02T03:04:05Z"));

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE"
                && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected DELETE to /UserFavoriteItems/item-xyz"
    );
    assert!(
        !requests
            .iter()
            .any(|r| r.url.path().starts_with("/Users/u1/FavoriteItems/")),
        "unexpected fallback to legacy route"
    );
}

#[tokio::test]
async fn set_favorite_falls_back_to_legacy_route_on_404() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Older servers respond 404 to /UserFavoriteItems/...
    Mock::given(method("POST"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;
    // ...so the client must retry the legacy route.
    Mock::given(method("POST"))
        .and(path("/Users/u1/FavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": true,
            "PlayCount": 5,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.set_favorite("item-xyz").await.unwrap();
    assert!(state.is_favorite);
    assert_eq!(state.play_count, Some(5));

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected preferred route to be tried first"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST"
                && r.url.path() == "/Users/u1/FavoriteItems/item-xyz"),
        "expected fallback to legacy route after 404"
    );
}

#[tokio::test]
async fn unset_favorite_falls_back_to_legacy_route_on_405() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(405))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/Users/u1/FavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "PlayCount": 1,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.unset_favorite("item-xyz").await.unwrap();
    assert!(!state.is_favorite);
    assert_eq!(state.play_count, Some(1));

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests.iter().any(|r| r.method.as_str() == "DELETE"
            && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected preferred route to be tried first"
    );
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE"
                && r.url.path() == "/Users/u1/FavoriteItems/item-xyz"),
        "expected fallback to legacy route after 405"
    );
}

#[tokio::test]
async fn set_favorite_without_session_returns_not_authenticated() {
    // No MockServer routes registered: the guard must short-circuit before any
    // HTTP call. Pointing at a live MockServer means a regression would surface
    // as an unmatched-route error instead of silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.set_favorite("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn unset_favorite_without_session_returns_not_authenticated() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.unset_favorite("anything").await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn toggle_favorite_dispatches_to_set_when_true() {
    // `toggle_favorite(_, true)` must use POST (matching set_favorite), not
    // DELETE — otherwise a macOS `likeCommand` tap would unfavorite on a
    // track whose state is already "not favorited" (the target state).
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": true,
            "PlayCount": 0,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.toggle_favorite("item-xyz", true).await.unwrap();
    assert!(state.is_favorite);

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected POST to /UserFavoriteItems on toggle_favorite(true)"
    );
    assert!(
        !requests.iter().any(|r| r.method.as_str() == "DELETE"),
        "toggle_favorite(true) must not issue a DELETE"
    );
}

#[tokio::test]
async fn toggle_favorite_dispatches_to_unset_when_false() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/UserFavoriteItems/item-xyz"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "IsFavorite": false,
            "PlayCount": 3,
            "LastPlayedDate": null
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let state = client.toggle_favorite("item-xyz", false).await.unwrap();
    assert!(!state.is_favorite);
    assert_eq!(state.play_count, Some(3));

    let requests = server.received_requests().await.unwrap();
    assert!(
        requests.iter().any(|r| r.method.as_str() == "DELETE"
            && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "expected DELETE to /UserFavoriteItems on toggle_favorite(false)"
    );
    // Auth is also a POST — we only care that we don't hit the favorite
    // endpoint with POST.
    assert!(
        !requests
            .iter()
            .any(|r| r.method.as_str() == "POST" && r.url.path() == "/UserFavoriteItems/item-xyz"),
        "toggle_favorite(false) must not issue a POST to the favorite endpoint"
    );
}

#[tokio::test]
async fn report_playback_progress_posts_pascal_case_body() {
    use crate::models::PlaybackProgressInfo;

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Jellyfin typically returns 204 No Content for progress reports.
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .report_playback_progress(PlaybackProgressInfo {
            item_id: "track-xyz".into(),
            position_ticks: 1_234_567_890,
            is_paused: true,
            is_muted: false,
            failed: false,
            media_source_id: Some("src-1".into()),
            play_session_id: Some("session-abc".into()),
            play_method: Some("DirectPlay".into()),
            playback_rate: Some(1.0),
            ..Default::default()
        })
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Playing/Progress")
        .expect("expected POST to /Sessions/Playing/Progress");

    // Content-Type should be JSON (set by reqwest when using `.json()`).
    let content_type = post
        .headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    assert!(
        content_type.contains("application/json"),
        "unexpected content-type: {content_type}"
    );

    // Body must use Jellyfin's PascalCase keys and include all required fields.
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    assert_eq!(
        body.get("ItemId").and_then(|v| v.as_str()),
        Some("track-xyz"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PositionTicks").and_then(|v| v.as_i64()),
        Some(1_234_567_890),
        "body: {body}"
    );
    assert_eq!(
        body.get("IsPaused").and_then(|v| v.as_bool()),
        Some(true),
        "body: {body}"
    );
    assert_eq!(
        body.get("IsMuted").and_then(|v| v.as_bool()),
        Some(false),
        "body: {body}"
    );
    // Failed is required by Jellyfin — must always be present.
    assert_eq!(
        body.get("Failed").and_then(|v| v.as_bool()),
        Some(false),
        "Failed must be present in progress body: {body}"
    );
    assert_eq!(
        body.get("MediaSourceId").and_then(|v| v.as_str()),
        Some("src-1"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlaySessionId").and_then(|v| v.as_str()),
        Some("session-abc"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlayMethod").and_then(|v| v.as_str()),
        Some("DirectPlay"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlaybackRate").and_then(|v| v.as_f64()),
        Some(1.0),
        "body: {body}"
    );

    // Ensure keys are PascalCase only — no snake_case leakage.
    let obj = body.as_object().expect("body should be an object");
    assert!(
        obj.keys().all(|k| !k.contains('_')),
        "expected PascalCase keys only, got: {:?}",
        obj.keys().collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn report_playback_progress_propagates_server_errors() {
    use crate::models::PlaybackProgressInfo;

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Progress"))
        .respond_with(ResponseTemplate::new(500).set_body_string("boom"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client
        .report_playback_progress(PlaybackProgressInfo {
            item_id: "track-xyz".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server 500, got {other:?}"),
    }
}

#[tokio::test]
async fn report_playback_progress_without_session_returns_not_authenticated() {
    use crate::models::PlaybackProgressInfo;

    // No MockServer routes registered: the guard must short-circuit before
    // any network call. Pointing at a live MockServer means a regression
    // would surface as an unmatched-route error rather than silently hitting
    // a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_progress(PlaybackProgressInfo {
            item_id: "track-xyz".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn report_playback_stopped_posts_expected_body() {
    use crate::models::PlaybackStopInfo;

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing/Stopped"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .report_playback_stopped(PlaybackStopInfo {
            item_id: "track-xyz".into(),
            position_ticks: 2_220_000_000,
            failed: false,
            media_source_id: Some("src-1".into()),
            play_session_id: Some("session-abc".into()),
            session_id: None,
        })
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Playing/Stopped")
        .expect("expected POST to /Sessions/Playing/Stopped");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");
    assert_eq!(
        body.get("ItemId").and_then(|v| v.as_str()),
        Some("track-xyz")
    );
    assert_eq!(
        body.get("PositionTicks").and_then(|v| v.as_i64()),
        Some(2_220_000_000)
    );
    // Failed is required by Jellyfin — must always be present.
    assert_eq!(
        body.get("Failed").and_then(|v| v.as_bool()),
        Some(false),
        "Failed must be present in stop body: {body}"
    );
    // MediaSourceId lets the server clean up the transcode job.
    assert_eq!(
        body.get("MediaSourceId").and_then(|v| v.as_str()),
        Some("src-1"),
        "body: {body}"
    );
    assert_eq!(
        body.get("PlaySessionId").and_then(|v| v.as_str()),
        Some("session-abc"),
        "body: {body}"
    );
    // Unset optional SessionId should be absent.
    assert!(
        !body.as_object().unwrap().contains_key("SessionId"),
        "unset optional should not appear: {body}"
    );
}

#[tokio::test]
async fn report_playback_stopped_requires_authenticated_session() {
    use crate::models::PlaybackStopInfo;

    // No MockServer endpoints registered for /Sessions/Playing/Stopped:
    // the auth guard must short-circuit before any HTTP call. We still
    // point at a live MockServer so that a regression would surface as
    // an unmatched-route error rather than silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_stopped(PlaybackStopInfo {
            item_id: "anything".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn create_playlist_posts_pascal_case_body_and_returns_id() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Id": "new-playlist-id"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client
        .create_playlist("Road Trip", &["t1", "t2", "t3"])
        .await
        .unwrap();
    assert_eq!(id, "new-playlist-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");

    // Content-Type should be JSON (set by reqwest when using `.json()`).
    let content_type = post
        .headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    assert!(
        content_type.contains("application/json"),
        "unexpected content-type: {content_type}"
    );

    // Auth header must be present with token.
    let auth = post
        .headers
        .get(reqwest::header::AUTHORIZATION)
        .expect("expected Authorization header")
        .to_str()
        .unwrap();
    assert!(auth.contains("Token=\"t\""), "auth header: {auth}");

    // Body must use Jellyfin's PascalCase keys, with MediaType = "Audio".
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    assert_eq!(
        body.get("Name").and_then(|v| v.as_str()),
        Some("Road Trip"),
        "body: {body}"
    );
    assert_eq!(
        body.get("UserId").and_then(|v| v.as_str()),
        Some("u1"),
        "body: {body}"
    );
    assert_eq!(
        body.get("MediaType").and_then(|v| v.as_str()),
        Some("Audio"),
        "body: {body}"
    );
    let ids = body
        .get("Ids")
        .and_then(|v| v.as_array())
        .expect("Ids should be an array");
    let id_strs: Vec<&str> = ids.iter().filter_map(|v| v.as_str()).collect();
    assert_eq!(id_strs, vec!["t1", "t2", "t3"], "body: {body}");

    // Keys must be PascalCase only — no snake_case leakage.
    let obj = body.as_object().expect("body should be an object");
    assert!(
        obj.keys().all(|k| !k.contains('_')),
        "expected PascalCase keys only, got: {:?}",
        obj.keys().collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn create_playlist_with_empty_ids_sends_empty_array() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Id": "empty-playlist-id"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client.create_playlist("Empty List", &[]).await.unwrap();
    assert_eq!(id, "empty-playlist-id");

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists")
        .expect("expected POST to /Playlists");
    let body: serde_json::Value =
        serde_json::from_slice(&post.body).expect("body should be valid JSON");
    let ids = body
        .get("Ids")
        .and_then(|v| v.as_array())
        .expect("Ids should be an array");
    assert!(ids.is_empty(), "expected empty Ids array, got: {body}");
}

#[tokio::test]
async fn create_playlist_propagates_server_errors() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Playlists"))
        .respond_with(ResponseTemplate::new(500).set_body_string("boom"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.create_playlist("x", &[]).await.unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server 500, got {other:?}"),
    }
}

#[tokio::test]
async fn create_playlist_requires_authenticated_session() {
    // No MockServer routes registered: the auth guard must short-circuit
    // before any HTTP call. Pointing at a live MockServer means a regression
    // would surface as an unmatched-route error rather than silently hitting
    // a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.create_playlist("x", &[]).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn add_to_playlist_posts_ids_csv_and_user_id() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // Jellyfin returns 204 No Content on success.
    Mock::given(method("POST"))
        .and(path("/Playlists/pl-123/Items"))
        .and(query_param("UserId", "u1"))
        .and(query_param("Ids", "t1,t2,t3"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .add_to_playlist("pl-123", &["t1", "t2", "t3"])
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Playlists/pl-123/Items")
        .expect("expected POST to /Playlists/pl-123/Items");

    // Query carries Ids as a comma-separated list and UserId is set.
    let q = post.url.query().expect("expected a query string");
    assert!(q.contains("Ids=t1%2Ct2%2Ct3"), "query: {q}");
    assert!(q.contains("UserId=u1"), "query: {q}");

    // Body must be empty — the endpoint accepts query-only input.
    assert!(
        post.body.is_empty(),
        "expected empty body, got {:?}",
        post.body
    );
}

#[tokio::test]
async fn add_to_playlist_requires_authenticated_session() {
    // No MockServer route registered for /Playlists/*/Items: the auth guard
    // must short-circuit before any HTTP call. Pointing at a live MockServer
    // means a regression would surface as an unmatched-route error rather
    // than silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.add_to_playlist("pl-123", &["t1"]).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// report_playback_started — POST /Sessions/Playing
// ---------------------------------------------------------------------------

#[tokio::test]
async fn report_playback_started_posts_pascal_case_body() {
    use crate::models::PlaybackStartInfo;

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Playing"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .report_playback_started(PlaybackStartInfo {
            item_id: "track-xyz".into(),
            media_source_id: Some("src-1".into()),
            play_session_id: Some("play-session-abc".into()),
            play_method: Some("DirectPlay".into()),
            position_ticks: Some(0),
            can_seek: true,
            is_paused: false,
            is_muted: false,
            ..Default::default()
        })
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Playing")
        .expect("expected POST to /Sessions/Playing");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");

    // Required fields must be PascalCase.
    assert_eq!(
        body.get("ItemId").and_then(|v| v.as_str()),
        Some("track-xyz"),
        "body: {body}"
    );
    assert_eq!(
        body.get("MediaSourceId").and_then(|v| v.as_str()),
        Some("src-1")
    );
    assert_eq!(
        body.get("PlaySessionId").and_then(|v| v.as_str()),
        Some("play-session-abc")
    );
    assert_eq!(
        body.get("PlayMethod").and_then(|v| v.as_str()),
        Some("DirectPlay")
    );
    assert_eq!(body.get("CanSeek").and_then(|v| v.as_bool()), Some(true));
    assert_eq!(body.get("IsPaused").and_then(|v| v.as_bool()), Some(false));
    assert_eq!(body.get("IsMuted").and_then(|v| v.as_bool()), Some(false));
    assert_eq!(body.get("PositionTicks").and_then(|v| v.as_i64()), Some(0));

    // None-valued optional fields must be elided from the payload.
    assert!(
        !body.as_object().unwrap().contains_key("SessionId"),
        "unset optional should not appear: {body}"
    );
    assert!(
        !body.as_object().unwrap().contains_key("VolumeLevel"),
        "unset optional should not appear: {body}"
    );

    // No snake_case leakage from serde.
    assert!(
        body.as_object().unwrap().keys().all(|k| !k.contains('_')),
        "expected PascalCase keys only: {:?}",
        body.as_object().unwrap().keys().collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn report_playback_started_requires_authenticated_session() {
    use crate::models::PlaybackStartInfo;

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_started(PlaybackStartInfo {
            item_id: "anything".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// post_capabilities — POST /Sessions/Capabilities/Full
// ---------------------------------------------------------------------------

#[tokio::test]
async fn post_capabilities_posts_full_client_capabilities_dto() {
    use crate::models::{ClientCapabilities, DeviceProfile};

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Sessions/Capabilities/Full"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let caps = ClientCapabilities {
        playable_media_types: vec!["Audio".into()],
        supported_commands: vec!["VolumeUp".into(), "Pause".into()],
        supports_media_control: true,
        supports_persistent_identifier: true,
        device_profile: DeviceProfile::default_macos_profile(),
        app_store_url: None,
        icon_url: Some("https://example.com/icon.png".into()),
    };
    client.post_capabilities(caps).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Sessions/Capabilities/Full")
        .expect("expected POST to /Sessions/Capabilities/Full");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");

    assert_eq!(
        body.get("PlayableMediaTypes").and_then(|v| v.as_array()),
        Some(&vec![serde_json::Value::String("Audio".into())])
    );
    assert_eq!(
        body.get("SupportsMediaControl").and_then(|v| v.as_bool()),
        Some(true)
    );
    assert_eq!(
        body.get("IconUrl").and_then(|v| v.as_str()),
        Some("https://example.com/icon.png")
    );
    // Device profile round-trips with PascalCase nested fields.
    let profile = body
        .get("DeviceProfile")
        .and_then(|v| v.as_object())
        .expect("DeviceProfile object");
    assert!(profile.contains_key("MaxStreamingBitrate"));
    assert!(profile.contains_key("DirectPlayProfiles"));
    assert!(profile.contains_key("TranscodingProfiles"));
    // None-valued optional AppStoreUrl should be elided.
    assert!(
        !body.as_object().unwrap().contains_key("AppStoreUrl"),
        "unset optional should not appear: {body}"
    );
}

#[tokio::test]
async fn post_capabilities_requires_authenticated_session() {
    use crate::models::{ClientCapabilities, DeviceProfile};

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .post_capabilities(ClientCapabilities {
            playable_media_types: vec![],
            supported_commands: vec![],
            supports_media_control: false,
            supports_persistent_identifier: false,
            device_profile: DeviceProfile::default_macos_profile(),
            app_store_url: None,
            icon_url: None,
        })
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// playback_info — POST /Items/{id}/PlaybackInfo
// ---------------------------------------------------------------------------

#[tokio::test]
async fn playback_info_posts_device_profile_and_parses_response() {
    use crate::models::{DeviceProfile, PlaybackInfoOpts};

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/Items/track-xyz/PlaybackInfo"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "MediaSources": [
                {
                    "Id": "src-1",
                    "Path": "/music/song.flac",
                    "Container": "flac",
                    "Bitrate": 900000,
                    "Size": 42_000_000i64,
                    "RunTimeTicks": 1800000000i64,
                    "SupportsDirectPlay": true,
                    "SupportsDirectStream": true,
                    "SupportsTranscoding": true,
                    "TranscodingUrl": "/Audio/track-xyz/stream.mp3?PlaySessionId=abc",
                    "TranscodingSubProtocol": "http",
                    "TranscodingContainer": "mp3"
                }
            ],
            "PlaySessionId": "play-session-abc"
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let opts = PlaybackInfoOpts {
        device_profile: Some(DeviceProfile::default_macos_profile()),
        max_streaming_bitrate: Some(320_000),
        ..Default::default()
    };
    let resp = client.playback_info("track-xyz", opts).await.unwrap();

    assert_eq!(resp.play_session_id.as_deref(), Some("play-session-abc"));
    assert_eq!(resp.media_sources.len(), 1);
    let src = &resp.media_sources[0];
    assert_eq!(src.id, "src-1");
    assert_eq!(src.container.as_deref(), Some("flac"));
    assert_eq!(src.bitrate, Some(900_000));
    assert!(src.supports_direct_play);
    assert_eq!(
        src.transcoding_url.as_deref(),
        Some("/Audio/track-xyz/stream.mp3?PlaySessionId=abc")
    );

    // Body fills in the live session's user id even when the caller
    // leaves `user_id` unset.
    let requests = server.received_requests().await.unwrap();
    let post = requests
        .iter()
        .find(|r| r.method.as_str() == "POST" && r.url.path() == "/Items/track-xyz/PlaybackInfo")
        .expect("expected POST to /Items/track-xyz/PlaybackInfo");
    let body: serde_json::Value = serde_json::from_slice(&post.body).expect("json body");
    assert_eq!(body.get("UserId").and_then(|v| v.as_str()), Some("u1"));
    assert_eq!(
        body.get("MaxStreamingBitrate").and_then(|v| v.as_u64()),
        Some(320_000)
    );
    assert!(body.get("DeviceProfile").is_some());
}

#[tokio::test]
async fn playback_info_requires_authenticated_session() {
    use crate::models::PlaybackInfoOpts;

    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .playback_info("anything", PlaybackInfoOpts::default())
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Library resolution — /UserViews + ManualPlaylistsFolder
// ---------------------------------------------------------------------------

#[tokio::test]
async fn user_views_parses_and_returns_all_libraries() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/UserViews"))
        .and(query_param("userId", "u1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music" },
                { "Id": "lib-movies", "Name": "Movies", "CollectionType": "movies" },
                { "Id": "lib-pl", "Name": "Playlists", "CollectionType": "playlists" }
            ],
            "TotalRecordCount": 3
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let views = client.user_views().await.unwrap();
    assert_eq!(views.len(), 3);
    assert_eq!(views[0].id, "lib-music");
    assert_eq!(views[0].collection_type.as_deref(), Some("music"));
    assert_eq!(views[2].collection_type.as_deref(), Some("playlists"));
}

#[tokio::test]
async fn music_library_id_filters_and_caches() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/UserViews"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-movies", "Name": "Movies", "CollectionType": "movies" },
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music" }
            ],
            "TotalRecordCount": 2
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let first = client.music_library_id().await.unwrap();
    assert_eq!(first, "lib-music");

    // Second call must come from the cache, not a fresh HTTP hit — if the
    // cache regresses this count would be 2.
    let second = client.music_library_id().await.unwrap();
    assert_eq!(second, "lib-music");
    let get_count = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/UserViews")
        .count();
    assert_eq!(
        get_count, 1,
        "music_library_id must cache /UserViews response"
    );
}

#[tokio::test]
async fn music_library_id_returns_404_when_no_music_view() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/UserViews"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-movies", "Name": "Movies", "CollectionType": "movies" }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client.music_library_id().await.unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 404),
        other => panic!("expected Server 404, got {other:?}"),
    }
}

#[tokio::test]
async fn playlist_library_id_finds_manual_playlists_folder() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Items"))
        .and(query_param("userId", "u1"))
        .and(query_param("includeItemTypes", "ManualPlaylistsFolder"))
        .and(query_param("excludeItemTypes", "CollectionFolder"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-pl", "Name": "Playlists", "CollectionType": "playlists" }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let id = client.playlist_library_id().await.unwrap();
    assert_eq!(id, "lib-pl");

    // Second call is served from the cache.
    let again = client.playlist_library_id().await.unwrap();
    assert_eq!(again, "lib-pl");
    let get_count = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/Items")
        .count();
    assert_eq!(
        get_count, 1,
        "playlist_library_id must cache its resolution"
    );
}

#[tokio::test]
async fn library_resolution_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client.user_views().await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated on user_views, got {err:?}"
    );
    let err = client.music_library_id().await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated on music_library_id, got {err:?}"
    );
    let err = client.playlist_library_id().await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated on playlist_library_id, got {err:?}"
    );
}

#[tokio::test]
async fn set_session_invalidates_library_cache() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/UserViews"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [
                { "Id": "lib-music", "Name": "Music", "CollectionType": "music" }
            ],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let _ = client.music_library_id().await.unwrap();
    // Re-auth against the same mock: cache must be dropped so the new
    // session triggers a fresh /UserViews lookup.
    client.set_session("t2".into(), "u2".into());
    let _ = client.music_library_id().await.unwrap();

    let get_count = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/UserViews")
        .count();
    assert_eq!(
        get_count, 2,
        "set_session must invalidate cached library ids"
    );
}

// ---------------------------------------------------------------------------
// remove_from_playlist — DELETE /Playlists/{id}/Items?entryIds=...
// ---------------------------------------------------------------------------

#[tokio::test]
async fn remove_from_playlist_sends_entry_ids_query_and_expects_204() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/Playlists/pl-1/Items"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client
        .remove_from_playlist("pl-1", &["entry-1".into(), "entry-2".into()])
        .await
        .unwrap();

    let requests = server.received_requests().await.unwrap();
    let del = requests
        .iter()
        .find(|r| r.method.as_str() == "DELETE" && r.url.path() == "/Playlists/pl-1/Items")
        .expect("expected DELETE to /Playlists/pl-1/Items");
    let entry_ids = del
        .url
        .query_pairs()
        .find(|(k, _)| k == "entryIds")
        .map(|(_, v)| v.into_owned())
        .expect("expected entryIds query param");
    assert_eq!(entry_ids, "entry-1,entry-2");
}

#[tokio::test]
async fn remove_from_playlist_is_noop_on_empty_entry_ids() {
    // No DELETE mock is registered — an accidental network hit would
    // surface as an unmatched-route error rather than silently succeed.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.remove_from_playlist("pl-1", &[]).await.unwrap();

    let requests = server.received_requests().await.unwrap();
    assert!(
        !requests
            .iter()
            .any(|r| r.method.as_str() == "DELETE" && r.url.path().starts_with("/Playlists/")),
        "empty entry_ids must short-circuit before any HTTP request"
    );
}

#[tokio::test]
async fn remove_from_playlist_propagates_server_errors() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/Playlists/pl-1/Items"))
        .respond_with(ResponseTemplate::new(403).set_body_string("forbidden"))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client
        .remove_from_playlist("pl-1", &["entry-1".into()])
        .await
        .unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 403),
        other => panic!("expected Server 403, got {other:?}"),
    }
}

#[tokio::test]
async fn remove_from_playlist_requires_authenticated_session() {
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .remove_from_playlist("pl-1", &["entry-1".into()])
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

// ---------------------------------------------------------------------------
// DeviceProfile serde
// ---------------------------------------------------------------------------

#[test]
fn default_macos_profile_serializes_to_pascal_case() {
    use crate::models::DeviceProfile;

    let profile = DeviceProfile::default_macos_profile();
    let v = serde_json::to_value(&profile).unwrap();
    let obj = v.as_object().expect("object profile");

    // Top-level PascalCase keys Jellyfin expects.
    for key in [
        "Name",
        "MaxStreamingBitrate",
        "MaxStaticBitrate",
        "MusicStreamingTranscodingBitrate",
        "DirectPlayProfiles",
        "TranscodingProfiles",
    ] {
        assert!(obj.contains_key(key), "missing top-level key {key}: {v}");
    }
    assert!(
        obj.keys().all(|k| !k.contains('_')),
        "expected PascalCase only, got {:?}",
        obj.keys().collect::<Vec<_>>()
    );

    // Direct-play entries cover the AVFoundation set: flac/alac/mp3/aac/opus/ogg/wav.
    let direct = obj
        .get("DirectPlayProfiles")
        .and_then(|v| v.as_array())
        .unwrap();
    let containers: std::collections::HashSet<&str> = direct
        .iter()
        .filter_map(|e| e.get("Container").and_then(|v| v.as_str()))
        .collect();
    for c in ["flac", "alac", "mp3", "aac", "opus", "ogg", "wav"] {
        assert!(
            containers.contains(c),
            "direct-play must include {c}: {containers:?}"
        );
    }
    // Entries opt into AudioCodec only when the container is ambiguous
    // (e.g. m4a that can hold either ALAC or AAC). Entries without a codec
    // should simply elide the key, not emit `"AudioCodec": null`.
    for entry in direct {
        let entry_obj = entry.as_object().unwrap();
        assert_eq!(
            entry_obj.get("Type").and_then(|v| v.as_str()),
            Some("Audio")
        );
        if let Some(codec) = entry_obj.get("AudioCodec") {
            assert!(codec.is_string(), "AudioCodec must be a string: {entry}");
        }
    }

    // Transcoding fallback is MP3 @ 320 over HTTP.
    let transcodes = obj
        .get("TranscodingProfiles")
        .and_then(|v| v.as_array())
        .unwrap();
    assert_eq!(transcodes.len(), 1, "expected one transcoding fallback");
    let t = transcodes[0].as_object().unwrap();
    assert_eq!(t.get("Container").and_then(|v| v.as_str()), Some("mp3"));
    assert_eq!(t.get("AudioCodec").and_then(|v| v.as_str()), Some("mp3"));
    assert_eq!(t.get("Protocol").and_then(|v| v.as_str()), Some("http"));

    // Bitrate caps — the 320 transcode ceiling and ~100 Mbps direct-play
    // cap the default profile advertises.
    assert_eq!(
        obj.get("MaxStreamingBitrate").and_then(|v| v.as_u64()),
        Some(320_000)
    );
    assert_eq!(
        obj.get("MusicStreamingTranscodingBitrate")
            .and_then(|v| v.as_u64()),
        Some(320_000)
    );
    assert_eq!(
        obj.get("MaxStaticBitrate").and_then(|v| v.as_u64()),
        Some(100_000_000)
    );
}

#[test]
fn default_macos_profile_round_trips_through_serde() {
    use crate::models::DeviceProfile;

    let profile = DeviceProfile::default_macos_profile();
    let json = serde_json::to_string(&profile).expect("serialize");
    let back: DeviceProfile = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(back.name, profile.name);
    assert_eq!(back.max_streaming_bitrate, profile.max_streaming_bitrate);
    assert_eq!(
        back.direct_play_profiles.len(),
        profile.direct_play_profiles.len()
    );
    assert_eq!(
        back.transcoding_profiles.len(),
        profile.transcoding_profiles.len()
    );
}

#[test]
fn stream_url_contains_api_key() {
    let mut client =
        JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    client.set_session("mytoken".into(), "u1".into());
    let url = client.stream_url("track-id").unwrap();
    let s = url.as_str();
    assert!(s.contains("api_key=mytoken"), "url: {s}");
    assert!(s.contains("DeviceId=dev"), "url: {s}");
    assert!(s.contains("/Audio/track-id/universal"), "url: {s}");
}

#[test]
fn image_url_primary_is_backwards_compatible() {
    let client = mock_client("https://example.com");
    let url = client.image_url("item-1", Some("tag-1"), 400).unwrap();
    let s = url.as_str();
    assert!(
        s.contains("/Items/item-1/Images/Primary"),
        "url missing Primary path: {s}"
    );
    assert!(s.contains("maxWidth=400"), "url missing maxWidth: {s}");
    assert!(s.contains("quality=90"), "url missing quality: {s}");
    assert!(s.contains("tag=tag-1"), "url missing tag: {s}");
    // No index segment when index is omitted.
    assert!(
        !s.contains("/Images/Primary/"),
        "unexpected index segment: {s}"
    );
}

#[test]
fn image_url_of_type_primary_matches_legacy_shape() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type(
            "item-1",
            ImageType::Primary,
            None,
            Some("tag-1"),
            Some(400),
            None,
        )
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("/Items/item-1/Images/Primary"), "url: {s}");
    assert!(s.contains("maxWidth=400"), "url: {s}");
    assert!(s.contains("tag=tag-1"), "url: {s}");
    // Neither index nor maxHeight should leak in when not provided.
    assert!(!s.contains("maxHeight="), "url: {s}");
}

#[test]
fn image_url_of_type_backdrop_includes_index_segment() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type(
            "item-2",
            ImageType::Backdrop,
            Some(1),
            Some("bd-tag"),
            Some(1600),
            Some(900),
        )
        .unwrap();
    let s = url.as_str();
    assert!(
        s.contains("/Items/item-2/Images/Backdrop/1"),
        "url missing Backdrop/1: {s}"
    );
    assert!(s.contains("maxWidth=1600"), "url: {s}");
    assert!(s.contains("maxHeight=900"), "url: {s}");
    assert!(s.contains("tag=bd-tag"), "url: {s}");
}

#[test]
fn image_url_of_type_thumb_without_index_or_sizes() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type("item-3", ImageType::Thumb, None, None, None, None)
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("/Items/item-3/Images/Thumb"), "url: {s}");
    assert!(!s.contains("/Thumb/"), "url should not have index: {s}");
    assert!(!s.contains("maxWidth="), "url: {s}");
    assert!(!s.contains("maxHeight="), "url: {s}");
    assert!(!s.contains("tag="), "url: {s}");
    assert!(s.contains("quality=90"), "url: {s}");
}

#[test]
fn database_roundtrips_settings() {
    let db = Database::in_memory().unwrap();
    db.set_setting("foo", "bar").unwrap();
    assert_eq!(db.get_setting("foo").unwrap().as_deref(), Some("bar"));
    db.set_setting("foo", "baz").unwrap();
    assert_eq!(db.get_setting("foo").unwrap().as_deref(), Some("baz"));
    assert_eq!(db.get_setting("missing").unwrap(), None);
}

#[test]
fn play_history_counts() {
    let db = Database::in_memory().unwrap();
    db.record_play("track-1", 100).unwrap();
    db.record_play("track-1", 200).unwrap();
    db.record_play("track-2", 150).unwrap();
    assert_eq!(db.play_count("track-1").unwrap(), 2);
    assert_eq!(db.play_count("track-2").unwrap(), 1);
    assert_eq!(db.play_count("unknown").unwrap(), 0);
}

// ---------------------------------------------------------------------------
// Session auto-restore (resume_session / login persistence)
// ---------------------------------------------------------------------------

/// Build a temp-backed `JellifyCore` so each test gets its own `jellify.db`
/// without colliding with other tests or leaking into the user's real data
/// directory.
fn resume_test_core(tmp: &tempfile::TempDir) -> std::sync::Arc<JellifyCore> {
    install_mock_keyring();
    JellifyCore::new(CoreConfig {
        data_dir: tmp.path().to_string_lossy().into_owned(),
        device_name: "Test".into(),
    })
    .expect("core init")
}

#[test]
fn resume_session_returns_none_when_no_settings() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    let resumed = core.resume_session().expect("resume_session");
    assert!(resumed.is_none(), "expected None on a fresh core");
}

#[test]
fn resume_session_returns_none_when_token_missing() {
    // Seed every `last_*` setting but leave the keyring empty — auto-restore
    // should bail cleanly rather than hand back a session with no token.
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    {
        let inner = core.inner.lock();
        inner
            .db
            .set_setting("last_server_url", "https://jellyfin.example/")
            .unwrap();
        inner
            .db
            .set_setting("last_username", "token-missing-user")
            .unwrap();
        inner
            .db
            .set_setting("last_server_id", "srv-token-missing")
            .unwrap();
        inner
            .db
            .set_setting("last_user_id", "usr-token-missing")
            .unwrap();
    }
    // Belt-and-braces: explicitly clear any stale token for this pair.
    CredentialStore::delete_token("srv-token-missing", "token-missing-user").unwrap();

    let resumed = core.resume_session().expect("resume_session");
    assert!(
        resumed.is_none(),
        "expected None when keyring entry is absent"
    );
}

#[test]
fn resume_session_returns_session_when_all_settings_present() {
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    // Pick IDs unique to this test so parallel runs don't read each other's
    // mock keyring entries.
    let server_id = "srv-resume-full";
    let username = "resume-full-user";
    let user_id = "usr-resume-full";
    let server_url = "https://resume.example/";
    let token = "token-resume-full";
    {
        let inner = core.inner.lock();
        inner.db.set_setting("last_server_url", server_url).unwrap();
        inner.db.set_setting("last_username", username).unwrap();
        inner.db.set_setting("last_server_id", server_id).unwrap();
        inner.db.set_setting("last_user_id", user_id).unwrap();
    }
    CredentialStore::save_token(server_id, username, token).unwrap();

    let resumed = core
        .resume_session()
        .expect("resume_session")
        .expect("expected Some(session)");
    assert_eq!(resumed.access_token, token);
    assert_eq!(resumed.user.id, user_id);
    assert_eq!(resumed.user.name, username);
    assert_eq!(resumed.user.server_id.as_deref(), Some(server_id));
    assert_eq!(resumed.server.id.as_deref(), Some(server_id));
    // `Url::parse` round-trips the trailing slash; exact equality keeps the
    // assertion tight so a future change to how we resolve the URL surfaces
    // immediately.
    assert_eq!(resumed.server.url, server_url);

    // And the core should now have a live client wired to the restored
    // credentials — any library call that follows can skip the login screen.
    assert!(
        core.inner.lock().client.is_some(),
        "resume_session must rehydrate the JellyfinClient"
    );
}

#[test]
fn resume_session_noop_when_only_partial_settings() {
    // Missing `last_user_id` on its own should still short-circuit to None.
    let tmp = tempfile::tempdir().unwrap();
    let core = resume_test_core(&tmp);
    {
        let inner = core.inner.lock();
        inner
            .db
            .set_setting("last_server_url", "https://partial.example/")
            .unwrap();
        inner
            .db
            .set_setting("last_username", "partial-user")
            .unwrap();
        inner
            .db
            .set_setting("last_server_id", "srv-partial")
            .unwrap();
        // Intentionally omit `last_user_id`.
    }
    CredentialStore::save_token("srv-partial", "partial-user", "partial-token").unwrap();

    let resumed = core.resume_session().expect("resume_session");
    assert!(
        resumed.is_none(),
        "partial settings must not rehydrate a half-built session"
    );
    assert!(
        core.inner.lock().client.is_none(),
        "client must not be reconstructed when settings are incomplete"
    );

    // Cleanup so a rerun of this test (or its neighbours) starts clean.
    CredentialStore::delete_token("srv-partial", "partial-user").unwrap();
}

#[tokio::test]
async fn login_persists_user_id_and_supports_resume() {
    // End-to-end: log in against a mock Jellyfin, then stand up a fresh core
    // pointed at the same data dir and assert `resume_session` hands back the
    // same session without a network round-trip.
    //
    // `JellifyCore::login` is a sync FFI wrapper that `block_on`s its own
    // tokio runtime, so we route it through `spawn_blocking` to keep it off
    // the test harness's current-thread runtime (otherwise tokio refuses
    // with "Cannot start a runtime from within a runtime").
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "persisted-token",
            "ServerId": "srv-persisted",
            "ServerName": "My Jellyfin",
            "User": {
                "Id": "usr-persisted",
                "Name": "persisted-user",
                "ServerId": "srv-persisted",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let server_url = server.uri();

    // --- first process: login ---
    let tmp_path = tmp.path().to_string_lossy().into_owned();
    let tmp_path_for_login = tmp_path.clone();
    let server_url_for_login = server_url.clone();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = JellifyCore::new(CoreConfig {
            data_dir: tmp_path_for_login,
            device_name: "Test".into(),
        })
        .expect("core init");
        let session = core
            .login(server_url_for_login, "persisted-user".into(), "pw".into())
            .expect("login");
        assert_eq!(session.user.id, "usr-persisted");

        // `login` must write `last_user_id` alongside the other identifiers so
        // the next launch can look up the keychain entry.
        let inner = core.inner.lock();
        assert_eq!(
            inner.db.get_setting("last_user_id").unwrap().as_deref(),
            Some("usr-persisted")
        );
        assert_eq!(
            inner.db.get_setting("last_server_id").unwrap().as_deref(),
            Some("srv-persisted")
        );
        assert_eq!(
            inner.db.get_setting("last_username").unwrap().as_deref(),
            Some("persisted-user")
        );
    })
    .await
    .expect("join login task");

    // --- second process: resume without re-authenticating ---
    let tmp_path_for_resume = tmp_path.clone();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core2 = JellifyCore::new(CoreConfig {
            data_dir: tmp_path_for_resume,
            device_name: "Test".into(),
        })
        .expect("core init");
        let resumed = core2
            .resume_session()
            .expect("resume_session")
            .expect("expected Some(session) after login persisted");
        assert_eq!(resumed.access_token, "persisted-token");
        assert_eq!(resumed.user.id, "usr-persisted");
        assert_eq!(resumed.user.name, "persisted-user");
        assert_eq!(resumed.server.id.as_deref(), Some("srv-persisted"));
        assert!(
            core2.inner.lock().client.is_some(),
            "resume_session must produce a live JellyfinClient"
        );
    })
    .await
    .expect("join resume task");
}

#[tokio::test]
async fn logout_clears_persisted_settings() {
    // After an explicit logout the next launch should start fresh — no
    // half-baked auto-restore attempt against a dead session.
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "logout-token",
            "ServerId": "srv-logout",
            "ServerName": "S",
            "User": {
                "Id": "usr-logout",
                "Name": "logout-user",
                "ServerId": "srv-logout",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let tmp_path = tmp.path().to_string_lossy().into_owned();
    let server_url = server.uri();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = JellifyCore::new(CoreConfig {
            data_dir: tmp_path.clone(),
            device_name: "Test".into(),
        })
        .expect("core init");
        let _ = core
            .login(server_url, "logout-user".into(), "pw".into())
            .expect("login");
        core.logout().expect("logout");

        {
            let inner = core.inner.lock();
            assert_eq!(inner.db.get_setting("last_server_url").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_username").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
        }
        assert!(
            CredentialStore::load_token("srv-logout", "logout-user")
                .unwrap()
                .is_none(),
            "logout must also remove the keychain token"
        );

        // Resume on a brand-new core over the same data dir should now bail.
        let core2 = JellifyCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core init");
        assert!(core2.resume_session().expect("resume_session").is_none());
    })
    .await
    .expect("join logout task");
}

#[tokio::test]
async fn forget_token_preserves_server_url_and_username() {
    // The auth-expired flow wipes the token so the user has to sign back in,
    // but should keep the pre-fill fields so they don't have to retype the
    // server URL / username.
    let tmp = tempfile::tempdir().unwrap();
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "forget-token",
            "ServerId": "srv-forget",
            "ServerName": "S",
            "User": {
                "Id": "usr-forget",
                "Name": "forget-user",
                "ServerId": "srv-forget",
                "PrimaryImageTag": null
            }
        })))
        .mount(&server)
        .await;

    let tmp_path = tmp.path().to_string_lossy().into_owned();
    let server_url = server.uri();
    tokio::task::spawn_blocking(move || {
        install_mock_keyring();
        let core = JellifyCore::new(CoreConfig {
            data_dir: tmp_path,
            device_name: "Test".into(),
        })
        .expect("core init");
        let _ = core
            .login(server_url, "forget-user".into(), "pw".into())
            .expect("login");
        core.forget_token().expect("forget_token");

        {
            let inner = core.inner.lock();
            // server URL + username stick around so the login form pre-fills.
            assert!(inner.db.get_setting("last_server_url").unwrap().is_some());
            assert_eq!(
                inner.db.get_setting("last_username").unwrap().as_deref(),
                Some("forget-user")
            );
            // The ids that key into the keychain entry are wiped so a stale
            // resume_session lookup can't accidentally grab a dangling token.
            assert_eq!(inner.db.get_setting("last_server_id").unwrap(), None);
            assert_eq!(inner.db.get_setting("last_user_id").unwrap(), None);
        }
        assert!(
            CredentialStore::load_token("srv-forget", "forget-user")
                .unwrap()
                .is_none(),
            "forget_token must remove the keychain token"
        );

        // resume_session needs all four settings; with ids cleared it must say no.
        assert!(core.resume_session().expect("resume_session").is_none());
    })
    .await
    .expect("join forget task");
}

// ============================================================================
// Retry + backoff + silent re-auth (issues #438, #440)
// ============================================================================
//
// These tests exercise the transport layer directly via `JellyfinClient` rather
// than the UniFFI wrapper, because the harness needs to inject 5xx / 401 /
// transient failures from wiremock. `MockServer::up_to_n_times` lets us chain
// multiple `Mock`s against the same path — it consumes them in insertion
// order, so the first two `respond_with` bodies land on the first two
// attempts and the last one services the eventual success.

/// `503` on the first two attempts, then `200`. The retry layer should
/// swallow the early failures and return the eventual success payload —
/// callers never see a `JellifyError::Server { 503, .. }`.
#[tokio::test]
async fn retry_recovers_from_transient_5xx() {
    let server = MockServer::start().await;
    // Mount three responses against `/System/Info/Public`: 503, 503, 200.
    // `wiremock` consumes them in insertion order.
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "ServerName": "After Retry",
            "Version": "10.10.0",
            "Id": "abc"
        })))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let info = client.public_info().await.expect("retry must recover");
    assert_eq!(info.server_name.as_deref(), Some("After Retry"));

    // The server saw 3 attempts total — 2 failures + the final success.
    let requests = server.received_requests().await.unwrap();
    let hits = requests
        .iter()
        .filter(|r| r.url.path() == "/System/Info/Public")
        .count();
    assert_eq!(hits, 3, "expected 3 attempts (2 retries); got {hits}");
}

/// `501 Not Implemented` is NOT retriable — it's a semantic rejection the
/// server will keep returning. One attempt, one error.
#[tokio::test]
async fn retry_does_not_loop_on_501_not_implemented() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(501))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let err = client.public_info().await.unwrap_err();
    match err {
        JellifyError::Server { status, .. } => assert_eq!(status, 501),
        other => panic!("expected Server {{ 501 }}, got {other:?}"),
    }
    let hits = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/System/Info/Public")
        .count();
    assert_eq!(hits, 1, "501 must not be retried");
}

/// Exhausting the retry budget (three 5xx in a row) surfaces the last
/// server error as `JellifyError::Server`, not as `Network(_)`.
#[tokio::test]
async fn retry_surfaces_last_server_error_when_budget_exhausted() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/System/Info/Public"))
        .respond_with(ResponseTemplate::new(502))
        .mount(&server)
        .await;

    let client = mock_client(&server.uri());
    let err = client.public_info().await.unwrap_err();
    match err {
        JellifyError::Server { status, .. } => assert_eq!(status, 502),
        other => panic!("expected Server {{ 502 }}, got {other:?}"),
    }
    let hits = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/System/Info/Public")
        .count();
    // MAX_ATTEMPTS = 3 (initial + 2 retries).
    assert_eq!(hits, 3, "expected 3 attempts total, got {hits}");
}

/// `401` with no refresh callback wired surfaces `AuthExpired` so the UI
/// can drive the re-auth sheet. No retry beyond the single 401.
#[tokio::test]
async fn auth_401_without_callback_returns_auth_expired() {
    let server = MockServer::start().await;
    // Have to authenticate first so the library call runs with a token.
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let err = client
        .albums(Paging::new(0, 10))
        .await
        .expect_err("401 without refresh must fail");
    assert!(
        matches!(err, JellifyError::AuthExpired),
        "expected AuthExpired, got {err:?}"
    );
}

/// `401` with a wired callback that hands back a *new* token triggers a
/// silent retry with the fresh token. Verifies both that the retry fires
/// and that the subsequent request carries the refreshed bearer.
#[tokio::test]
async fn auth_401_with_callback_retries_with_new_token() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "old-token", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    // First library hit: 401 (stale token).
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    // Second hit: 200 with a single album so the caller gets a real result.
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "Items": [{ "Id": "a1", "Name": "Album", "Type": "MusicAlbum" }],
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();

    // Hand back a *different* token on refresh — if the callback returned
    // the same string the retry layer would bail with AuthExpired rather
    // than loop.
    client.set_refresh_callback(std::sync::Arc::new(|| Ok(Some("fresh-token".to_string()))));

    let page = client
        .albums(Paging::new(0, 10))
        .await
        .expect("refresh + retry should succeed");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, "a1");

    // Inspect the retry: second `GET /Users/u1/Items` must have carried the
    // fresh token in its Authorization header.
    let requests = server.received_requests().await.unwrap();
    let gets: Vec<_> = requests
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/Users/u1/Items")
        .collect();
    assert_eq!(gets.len(), 2, "expected 2 GETs (initial + retry)");
    let retry_auth = gets[1]
        .headers
        .get("authorization")
        .expect("retry must carry Authorization");
    let retry_auth_str = retry_auth.to_str().unwrap();
    assert!(
        retry_auth_str.contains("fresh-token"),
        "retry should use new token, saw: {retry_auth_str}"
    );
}

/// A refresh callback that returns `Ok(None)` (e.g. keyring wiped) surfaces
/// `AuthExpired` — no retry, caller drives the re-auth sheet.
#[tokio::test]
async fn auth_401_with_callback_returning_none_surfaces_expired() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "t", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.set_refresh_callback(std::sync::Arc::new(|| Ok(None)));

    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    assert!(matches!(err, JellifyError::AuthExpired));
}

/// When the callback hands back the *same* token the client already has,
/// the retry layer treats it as a dead token — no pointless loop, just
/// `AuthExpired`.
#[tokio::test]
async fn auth_401_with_same_token_does_not_loop() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/Users/AuthenticateByName"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "AccessToken": "same-token", "ServerId": "s", "ServerName": "S",
            "User": { "Id": "u1", "Name": "n", "ServerId": "s", "PrimaryImageTag": null }
        })))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/Users/u1/Items"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    client.set_refresh_callback(std::sync::Arc::new(|| Ok(Some("same-token".to_string()))));

    let err = client.albums(Paging::new(0, 10)).await.unwrap_err();
    assert!(matches!(err, JellifyError::AuthExpired));

    // Crucial: only the initial 401 hit, no loop.
    let hits = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.method.as_str() == "GET" && r.url.path() == "/Users/u1/Items")
        .count();
    assert_eq!(hits, 1, "expected exactly one GET — no retry loop");
}

/// `storage::refresh_token_from_keyring` is the bridge between the HTTP
/// client's 401 interceptor and the OS credential store. Smoke-test the
/// three scenarios the wrapping callback relies on: missing persisted
/// ids (Ok(None)), ids-but-no-keychain-entry (Ok(None)), and a present
/// keychain entry (Ok(Some)).
#[test]
fn refresh_token_from_keyring_returns_token_when_present() {
    install_mock_keyring();
    let db = Database::in_memory().expect("in-memory db");

    // Missing ids → None.
    let missing = crate::storage::refresh_token_from_keyring(&db).unwrap();
    assert!(missing.is_none(), "no settings → None");

    // Ids present but no keychain entry → None.
    db.set_setting("last_server_id", "srv-refresh-test")
        .unwrap();
    db.set_setting("last_username", "refresh-user").unwrap();
    // Make sure there's no stale entry from another test run.
    CredentialStore::delete_token("srv-refresh-test", "refresh-user").unwrap();
    let absent = crate::storage::refresh_token_from_keyring(&db).unwrap();
    assert!(absent.is_none(), "no keychain entry → None");

    // Save a token — now refresh should hand it back.
    CredentialStore::save_token("srv-refresh-test", "refresh-user", "refreshed-token").unwrap();
    let got = crate::storage::refresh_token_from_keyring(&db)
        .unwrap()
        .expect("token should be present");
    assert_eq!(got, "refreshed-token");
}

// ---------------------------------------------------------------------------
// Shuffle + repeat persistence — round-trip tests (#583)
// ---------------------------------------------------------------------------

use crate::player::RepeatMode;

/// Fresh database returns the safe defaults (shuffle off, repeat off) so a
/// first launch does not accidentally start in an unexpected mode.
#[test]
fn shuffle_repeat_defaults_on_empty_db() {
    let db = Database::in_memory().expect("in-memory db");
    let (shuffle, repeat) = db.load_shuffle_repeat().unwrap();
    assert!(!shuffle, "default shuffle should be off");
    assert_eq!(repeat, RepeatMode::Off, "default repeat should be Off");
}

/// Every `(shuffle, RepeatMode)` combination round-trips correctly through the
/// key-value store. We create a second `Database` instance open on the same
/// file to verify the values are actually persisted rather than just cached in
/// memory.
#[test]
fn shuffle_repeat_round_trips_all_variants() {
    // Use a uniquely-named file in the OS temp directory so parallel test
    // runs do not collide. Best-effort removal at the end — it is fine if
    // the process exits before the remove; the OS will clean up temp files.
    let tmp = std::env::temp_dir().join(format!(
        "jellify_test_sr_{}.db",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));

    let cases: &[(bool, RepeatMode)] = &[
        (true, RepeatMode::Off),
        (false, RepeatMode::One),
        (true, RepeatMode::All),
        (false, RepeatMode::Off),
        (true, RepeatMode::One),
        (false, RepeatMode::All),
    ];

    for &(shuffle, repeat) in cases {
        // Write via one Database handle.
        {
            let db = Database::open(&tmp).expect("open db for write");
            db.save_shuffle_repeat(shuffle, repeat)
                .expect("save_shuffle_repeat");
        }
        // Read back via a fresh Database handle — exercises the actual SQLite
        // persistence path rather than any in-process cache.
        {
            let db = Database::open(&tmp).expect("open db for read");
            let (got_shuffle, got_repeat) = db.load_shuffle_repeat().expect("load_shuffle_repeat");
            assert_eq!(
                got_shuffle, shuffle,
                "shuffle mismatch for case ({shuffle}, {repeat:?})"
            );
            assert_eq!(
                got_repeat, repeat,
                "repeat mismatch for case ({shuffle}, {repeat:?})"
            );
        }
    }

    let _ = std::fs::remove_file(&tmp);
}
