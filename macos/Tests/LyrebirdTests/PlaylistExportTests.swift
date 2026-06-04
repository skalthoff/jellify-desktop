import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the pure playlist export serializers behind the Share / Export
/// affordances (#237): the extended-M3U writer, the JSON manifest writer, and
/// the secret-stripping deep-link builder. These are deliberately `AppModel`-,
/// `NSSavePanel`-, and FFI-free — `PlaylistExport` takes only an already-loaded
/// `[Track]` plus the playlist name / server URL, so the byte-level output can
/// be locked down deterministically.
final class PlaylistExportTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTrack(
        id: String,
        name: String,
        artistName: String = "Artist",
        albumName: String? = "Album",
        albumId: String? = "alb-1",
        runtimeTicks: UInt64 = 2_000_000_000  // 200s
    ) -> Track {
        Track(
            id: id,
            name: name,
            albumId: albumId,
            albumName: albumName,
            artistName: artistName,
            artistId: "art-1",
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: runtimeTicks,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - M3U

    func testM3UHeaderAndPlaylistName() {
        let out = PlaylistExport.m3u8(
            playlistName: "My Mix",
            tracks: [makeTrack(id: "1", name: "Song")],
            serverURL: "https://music.example.com"
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertEqual(lines[1], "#PLAYLIST:My Mix")
    }

    func testM3UEmitsExtinfAndAuthFreeStreamURLPerTrack() {
        let tracks = [
            makeTrack(id: "abc", name: "First", artistName: "A", runtimeTicks: 1_800_000_000),  // 180s
            makeTrack(id: "def", name: "Second", artistName: "B", runtimeTicks: 2_400_000_000),  // 240s
        ]
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: tracks,
            serverURL: "https://music.example.com"
        )
        XCTAssertTrue(out.contains("#EXTINF:180,A - First"))
        XCTAssertTrue(out.contains("https://music.example.com/Audio/abc/universal"))
        XCTAssertTrue(out.contains("#EXTINF:240,B - Second"))
        XCTAssertTrue(out.contains("https://music.example.com/Audio/def/universal"))
        // No auth material in the stream URLs.
        XCTAssertFalse(out.lowercased().contains("api_key"))
        XCTAssertFalse(out.contains("?"))
    }

    func testM3UTrimsTrailingSlashOnServerURL() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "x", name: "T")],
            serverURL: "https://music.example.com/"
        )
        XCTAssertTrue(out.contains("https://music.example.com/Audio/x/universal"))
        XCTAssertFalse(out.contains("//Audio"))
    }

    func testM3UUnknownDurationEmitsNegativeOne() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "x", name: "T", artistName: "A", runtimeTicks: 0)],
            serverURL: "https://m.example.com"
        )
        XCTAssertTrue(out.contains("#EXTINF:-1,A - T"))
    }

    func testM3UDropsArtistDashWhenArtistBlank() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "x", name: "Solo", artistName: "   ")],
            serverURL: "https://m.example.com"
        )
        // "Artist - Title" collapses to just the title when artist is blank.
        XCTAssertTrue(out.contains("#EXTINF:200,Solo\n"))
        XCTAssertFalse(out.contains(" - Solo"))
    }

    func testM3USanitizesNewlinesInTitle() {
        // A track name with an embedded newline must not be able to inject a
        // fake directive line into the document.
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "x", name: "Evil\n#EXTM3U", artistName: "A")],
            serverURL: "https://m.example.com"
        )
        let directiveLines = out.split(separator: "\n").filter { $0 == "#EXTM3U" }
        XCTAssertEqual(directiveLines.count, 1, "only the header line should be #EXTM3U")
    }

    func testM3UEndsWithTrailingNewline() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "x", name: "T")],
            serverURL: "https://m.example.com"
        )
        XCTAssertTrue(out.hasSuffix("\n"))
    }

    func testM3UEmptyTracksStillEmitsHeader() {
        let out = PlaylistExport.m3u8(
            playlistName: "Empty",
            tracks: [],
            serverURL: "https://m.example.com"
        )
        XCTAssertEqual(out, "#EXTM3U\n#PLAYLIST:Empty\n")
    }

    // MARK: - M3U: playable (authenticated) stream URLs

    /// With an `apiKey`, entries must use the static-download `/stream` form
    /// with the key embedded so an external player can fetch them from the URL
    /// alone. A bare `/universal` path requires the Authorization header and
    /// 401s for a generic M3U player, which is the bug this fixes (#237).
    func testM3UWithApiKeyEmitsPlayableStreamURL() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "abc", name: "Song")],
            serverURL: "https://music.example.com",
            apiKey: "TOKEN123"
        )
        XCTAssertTrue(out.contains("https://music.example.com/Audio/abc/stream.mp3?api_key=TOKEN123&Static=true"))
        // The non-playable bare universal path must NOT be emitted when a key
        // is available.
        XCTAssertFalse(out.contains("/Audio/abc/universal"))
    }

    /// The stream URL extension follows the track's source container so the
    /// receiving player gets a correct content-type hint.
    func testM3UStreamExtensionFollowsTrackContainer() {
        let track = Track(
            id: "x", name: "T", albumId: nil, albumName: nil,
            artistName: "A", artistId: nil, indexNumber: nil, discNumber: nil,
            year: nil, runtimeTicks: 0, isFavorite: false, playCount: 0,
            container: "FLAC", bitrate: nil, imageTag: nil,
            playlistItemId: nil, userData: nil
        )
        let out = PlaylistExport.m3u8(
            playlistName: "Mix", tracks: [track],
            serverURL: "https://m.example.com", apiKey: "K"
        )
        // Container is lower-cased into the extension hint.
        XCTAssertTrue(out.contains("/Audio/x/stream.flac?api_key=K&Static=true"))
    }

    /// An unknown container falls back to a `.mp3` extension hint.
    func testM3UStreamExtensionDefaultsToMP3WhenContainerUnknown() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "y", name: "T")],  // fixture has container: nil
            serverURL: "https://m.example.com",
            apiKey: "K"
        )
        XCTAssertTrue(out.contains("/Audio/y/stream.mp3?api_key=K&Static=true"))
    }

    /// A token with URL-significant characters is percent-encoded so the query
    /// string stays well-formed.
    func testM3UApiKeyIsPercentEncoded() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "z", name: "T")],
            serverURL: "https://m.example.com",
            apiKey: "a b&c"
        )
        XCTAssertTrue(out.contains("api_key=a%20b%26c"))
        XCTAssertFalse(out.contains("api_key=a b&c"))
    }

    /// Backward-compatible: with no `apiKey` (the default), entries stay on the
    /// auth-free bare universal path — a well-formed file that prompts for auth
    /// in the player rather than embedding a credential.
    func testM3UWithoutApiKeyKeepsAuthFreeUniversalPath() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "abc", name: "Song")],
            serverURL: "https://music.example.com"
        )
        XCTAssertTrue(out.contains("https://music.example.com/Audio/abc/universal"))
        XCTAssertFalse(out.lowercased().contains("api_key"))
    }

    /// An empty `apiKey` is treated as "no key" — the bare path, not a
    /// dangling `?api_key=&Static=true`.
    func testM3UEmptyApiKeyFallsBackToUniversalPath() {
        let out = PlaylistExport.m3u8(
            playlistName: "Mix",
            tracks: [makeTrack(id: "abc", name: "Song")],
            serverURL: "https://music.example.com",
            apiKey: ""
        )
        XCTAssertTrue(out.contains("/Audio/abc/universal"))
        XCTAssertFalse(out.contains("api_key="))
    }

    // MARK: - JSON

    func testJSONRoundTripsThroughManifest() throws {
        let tracks = [
            makeTrack(id: "1", name: "First", artistName: "A", albumName: "Alb", albumId: "al-1", runtimeTicks: 1_800_000_000),
            makeTrack(id: "2", name: "Second", artistName: "B", albumName: nil, albumId: nil, runtimeTicks: 0),
        ]
        let jsonString = try PlaylistExport.json(playlistId: "pl-7", playlistName: "Mix", tracks: tracks)
        let data = Data(jsonString.utf8)
        let decoded = try JSONDecoder().decode(PlaylistManifest.self, from: data)

        XCTAssertEqual(decoded.schema, "lyrebird.playlist/v1")
        XCTAssertEqual(decoded.id, "pl-7")
        XCTAssertEqual(decoded.name, "Mix")
        XCTAssertEqual(decoded.trackCount, 2)
        XCTAssertEqual(decoded.tracks.count, 2)

        XCTAssertEqual(decoded.tracks[0].id, "1")
        XCTAssertEqual(decoded.tracks[0].name, "First")
        XCTAssertEqual(decoded.tracks[0].artist, "A")
        XCTAssertEqual(decoded.tracks[0].album, "Alb")
        XCTAssertEqual(decoded.tracks[0].albumId, "al-1")
        XCTAssertEqual(decoded.tracks[0].durationSeconds, 180)

        // Second track: nil album fields, unknown duration.
        XCTAssertEqual(decoded.tracks[1].album, nil)
        XCTAssertEqual(decoded.tracks[1].albumId, nil)
        XCTAssertEqual(decoded.tracks[1].durationSeconds, 0)
    }

    func testJSONPreservesTrackOrder() throws {
        let tracks = (1...5).map { makeTrack(id: "\($0)", name: "T\($0)") }
        let jsonString = try PlaylistExport.json(playlistId: "p", playlistName: "Ordered", tracks: tracks)
        let decoded = try JSONDecoder().decode(PlaylistManifest.self, from: Data(jsonString.utf8))
        XCTAssertEqual(decoded.tracks.map(\.id), ["1", "2", "3", "4", "5"])
    }

    func testJSONIsDeterministicAndPrettyPrinted() throws {
        let tracks = [makeTrack(id: "1", name: "Song")]
        let first = try PlaylistExport.json(playlistId: "p", playlistName: "Mix", tracks: tracks)
        let second = try PlaylistExport.json(playlistId: "p", playlistName: "Mix", tracks: tracks)
        // Sorted keys → byte-identical across runs.
        XCTAssertEqual(first, second)
        // Pretty-printed → contains a newline + indentation.
        XCTAssertTrue(first.contains("\n  "))
        XCTAssertTrue(first.hasSuffix("\n"))
    }

    func testJSONBlankArtistOmittedFromOutput() throws {
        let jsonString = try PlaylistExport.json(
            playlistId: "p",
            playlistName: "Mix",
            tracks: [makeTrack(id: "1", name: "Solo", artistName: "  ")]
        )
        let decoded = try JSONDecoder().decode(PlaylistManifest.self, from: Data(jsonString.utf8))
        XCTAssertNil(decoded.tracks[0].artist)
    }

    func testJSONDoesNotEscapeSlashes() throws {
        // withoutEscapingSlashes keeps album names with slashes readable.
        let jsonString = try PlaylistExport.json(
            playlistId: "p",
            playlistName: "AC/DC Hits",
            tracks: [makeTrack(id: "1", name: "T")]
        )
        XCTAssertTrue(jsonString.contains("AC/DC Hits"))
        XCTAssertFalse(jsonString.contains("AC\\/DC"))
    }

    // MARK: - Deep link / secret stripping

    func testWebURLBuildsDetailsRoute() {
        let url = PlaylistExport.webURL(serverURL: "https://music.example.com", itemId: "pl-42")
        XCTAssertEqual(url?.absoluteString, "https://music.example.com/web/#/details?id=pl-42")
    }

    func testWebURLTrimsTrailingSlash() {
        let url = PlaylistExport.webURL(serverURL: "https://music.example.com/", itemId: "pl-42")
        XCTAssertEqual(url?.absoluteString, "https://music.example.com/web/#/details?id=pl-42")
    }

    func testWebURLStripsEmbeddedCredentials() {
        // The stored server URL can carry basic-auth userinfo; the shared link
        // must never leak it.
        let url = PlaylistExport.webURL(
            serverURL: "https://admin:hunter2@music.example.com",
            itemId: "pl-42"
        )
        let str = url?.absoluteString ?? ""
        XCTAssertFalse(str.contains("admin"))
        XCTAssertFalse(str.contains("hunter2"))
        XCTAssertEqual(str, "https://music.example.com/web/#/details?id=pl-42")
    }

    func testWebURLStripsQueryAndFragmentSecrets() {
        let url = PlaylistExport.webURL(
            serverURL: "https://music.example.com/?api_key=SECRET#frag",
            itemId: "pl-42"
        )
        let str = url?.absoluteString ?? ""
        XCTAssertFalse(str.contains("SECRET"))
        XCTAssertFalse(str.contains("api_key"))
        XCTAssertEqual(str, "https://music.example.com/web/#/details?id=pl-42")
    }

    func testWebURLPreservesPortAndSubpath() {
        let url = PlaylistExport.webURL(
            serverURL: "http://192.168.1.10:8096/jellyfin/",
            itemId: "pl-9"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "http://192.168.1.10:8096/jellyfin/web/#/details?id=pl-9"
        )
    }

    func testWebURLNilForEmptyServer() {
        XCTAssertNil(PlaylistExport.webURL(serverURL: "", itemId: "pl-1"))
        XCTAssertNil(PlaylistExport.webURL(serverURL: "   ", itemId: "pl-1"))
    }

    func testWebURLNilForSchemelessOrHostlessString() {
        XCTAssertNil(PlaylistExport.webURL(serverURL: "not a url", itemId: "pl-1"))
    }
}
