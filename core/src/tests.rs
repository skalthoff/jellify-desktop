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
async fn report_playback_progress_posts_pascal_case_body() {
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
        .report_playback_progress("track-xyz", 1_234_567_890, true)
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

    // Body must use Jellyfin's PascalCase keys.
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
        .report_playback_progress("track-xyz", 0, false)
        .await
        .unwrap_err();
    match err {
        crate::error::JellifyError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected Server 500, got {other:?}"),
    }
}

#[tokio::test]
async fn report_playback_progress_without_session_returns_not_authenticated() {
    // No MockServer routes registered: the guard must short-circuit before
    // any network call. Pointing at a live MockServer means a regression
    // would surface as an unmatched-route error rather than silently hitting
    // a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_progress("track-xyz", 0, false)
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::error::JellifyError::NotAuthenticated),
        "expected NotAuthenticated, got {err:?}"
    );
}

#[tokio::test]
async fn report_playback_stopped_posts_expected_body() {
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
        .report_playback_stopped("track-xyz", 2_220_000_000)
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
    // Only the minimum set of fields we send.
    let keys: std::collections::HashSet<&str> = body
        .as_object()
        .expect("object body")
        .keys()
        .map(String::as_str)
        .collect();
    let expected: std::collections::HashSet<&str> =
        ["ItemId", "PositionTicks"].into_iter().collect();
    assert_eq!(keys, expected, "unexpected body keys: {keys:?}");
}

#[tokio::test]
async fn report_playback_stopped_requires_authenticated_session() {
    // No MockServer endpoints registered for /Sessions/Playing/Stopped:
    // the auth guard must short-circuit before any HTTP call. We still
    // point at a live MockServer so that a regression would surface as
    // an unmatched-route error rather than silently hitting a real host.
    let server = MockServer::start().await;
    let client = mock_client(&server.uri());
    let err = client
        .report_playback_stopped("anything", 0)
        .await
        .unwrap_err();
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
