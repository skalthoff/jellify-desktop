use crate::client::JellyfinClient;
use crate::models::{ImageType, Paging};
use crate::storage::Database;
use serde_json::json;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn mock_client(base: &str) -> JellyfinClient {
    JellyfinClient::new(base, "test-device".into(), "Test Device".into()).unwrap()
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
            "TotalRecordCount": 1
        })))
        .mount(&server)
        .await;

    let mut client = mock_client(&server.uri());
    client.authenticate_by_name("n", "pw").await.unwrap();
    let tracks = client
        .recently_played(Some("lib-1"), Paging::new(0, 50))
        .await
        .unwrap();

    assert_eq!(tracks.len(), 1);
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
            let expected_keys: std::collections::HashSet<&str> = [
                "UserId",
                "ParentId",
                "IncludeItemTypes",
                "Limit",
                "GroupItems",
                "Fields",
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
    let albums = client.latest_albums("lib-music", 24).await.unwrap();
    assert_eq!(albums.len(), 2);
    assert_eq!(albums[0].name, "The Deep End");
    assert_eq!(albums[0].artist_name, "Saloli");
    assert_eq!(albums[0].year, Some(2020));
    assert_eq!(albums[0].track_count, 8);
    assert_eq!(albums[0].image_tag.as_deref(), Some("abcd"));
    assert_eq!(albums[1].name, "Spiral");
    assert!(albums[1].image_tag.is_none());
}

#[tokio::test]
async fn latest_albums_requires_authenticated_session() {
    let client = JellyfinClient::new("https://example.com", "dev".into(), "Dev".into()).unwrap();
    let err = client.latest_albums("lib-music", 24).await.unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
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
