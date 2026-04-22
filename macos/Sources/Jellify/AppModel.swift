import AppKit
import Foundation
import Observation
@preconcurrency import JellifyCore
import JellifyAudio

/// Top-level app state. Owns the Rust core and publishes a reactive surface
/// that SwiftUI views observe. All core calls go through here so views never
/// touch the FFI directly.
@Observable
@MainActor
final class AppModel {
    // MARK: - Core
    let core: JellifyCore
    let audio: AudioEngine

    // MARK: - Session
    var session: Session?
    var serverURL: String = ""
    var username: String = ""

    // MARK: - Navigation
    enum Screen: Hashable { case home, library, search, settings, album(String), artist(String), playlist(String) }
    var screen: Screen = .library

    // MARK: - Library
    var albums: [Album] = []
    var artists: [Artist] = []
    var albumTracks: [String: [Track]] = [:]          // albumID → tracks
    var searchResults: SearchResults?
    var searchQuery: String = ""

    // MARK: - Player
    var status: PlayerStatus
    var pollTimer: Timer?

    // MARK: - Loading / errors
    var isLoggingIn = false
    var isLoadingLibrary = false
    var errorMessage: String?

    init() throws {
        let core = try JellifyCore(
            config: CoreConfig(dataDir: "", deviceName: "Jellify macOS")
        )
        self.core = core
        self.audio = AudioEngine(core: core)
        self.status = core.status()
        self.audio.onTrackEnded = { [weak self] in
            self?.handleTrackEnded()
        }
    }

    // MARK: - Session

    func login(url: String, username: String, password: String) async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let session = try await Task.detached(priority: .userInitiated) { [core] in
                try core.login(url: url, username: username, password: password)
            }.value
            self.session = session
            self.serverURL = url
            self.username = username
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
        } catch {
            self.errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    func logout() {
        audio.stop()
        try? core.logout()
        session = nil
        albums = []
        artists = []
        albumTracks = [:]
        stopPolling()
    }

    // MARK: - Library

    func refreshLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            let albums = try await Task.detached(priority: .userInitiated) { [core] in
                try core.listAlbums(offset: 0, limit: 200)
            }.value
            let artists = try await Task.detached(priority: .userInitiated) { [core] in
                try core.listArtists(offset: 0, limit: 200)
            }.value
            self.albums = albums
            self.artists = artists
        } catch {
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
    }

    func loadTracks(forAlbum albumID: String) async -> [Track] {
        if let cached = albumTracks[albumID] { return cached }
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.albumTracks(albumId: albumID)
            }.value
            albumTracks[albumID] = tracks
            return tracks
        } catch {
            errorMessage = "Album tracks failed: \(error.localizedDescription)"
            return []
        }
    }

    func search(_ query: String) async {
        searchQuery = query
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        do {
            let results = try await Task.detached(priority: .userInitiated) { [core] in
                try core.search(query: query)
            }.value
            self.searchResults = results
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    func imageURL(for itemID: String, tag: String?, maxWidth: UInt32 = 400) -> URL? {
        guard let s = try? core.imageUrl(itemId: itemID, tag: tag, maxWidth: maxWidth) else { return nil }
        return URL(string: s)
    }

    // MARK: - Playback

    func play(tracks: [Track], startIndex: Int = 0) {
        do {
            _ = try core.setQueue(tracks: tracks, startIndex: UInt32(startIndex))
            guard let first = tracks[safe: startIndex] else { return }
            try audio.play(track: first)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start playback: \(error.localizedDescription)"
        }
    }

    func play(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle an album — loads tracks, randomises order, then plays from top.
    func shuffle(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert an album's tracks immediately after the currently-playing track.
    /// TODO: #282 — proper Up Next vs Auto Queue separation. For now, the core
    /// queue is replaced on every `setQueue`, so until we grow an `insertNext`
    /// primitive this falls back to appending behaviour.
    func playNext(album: Album) {
        // TODO: #282 — queue "Up Next" insertion; for now, surface a log.
        print("[AppModel] playNext(album:) not yet wired — see #282")
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Append an album's tracks to the end of the queue.
    /// TODO: #282 — the core lacks an `appendToQueue` primitive, so this is a
    /// stub that plays the album outright for now.
    func addToQueue(album: Album) {
        // TODO: #282 — queue append. Currently behaves like `play`.
        print("[AppModel] addToQueue(album:) not yet wired — see #282")
        play(album: album)
    }

    /// Toggle the favorite flag for an album on the Jellyfin server.
    /// TODO: #133, #222 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(album: Album) {
        // TODO: #133 / #222 — set_favorite FFI not yet wired.
        print("[AppModel] toggleFavorite(album:) not yet wired — see #133 / #222")
    }

    /// Enqueue a download of every track on the album.
    /// TODO: #70, #222 — there is no download engine yet; this is a logging
    /// stub so the UI action has a landing pad.
    func enqueueDownload(album: Album) {
        // TODO: #70 / #222 — download engine not yet wired.
        print("[AppModel] enqueueDownload(album:) not yet wired — see #70 / #222")
    }

    /// Present an "Add all to playlist" destination picker.
    /// TODO: #72, #126, #222 — playlist picker sheet + create-playlist API.
    func requestAddToPlaylist(album: Album) {
        // TODO: #72 / #126 / #222 — playlist picker sheet not yet implemented.
        print("[AppModel] requestAddToPlaylist(album:) not yet wired — see #72 / #126 / #222")
    }

    /// Navigate to the artist detail screen for this album's artist, if known.
    func goToArtist(album: Album) {
        guard let artistID = album.artistId else { return }
        screen = .artist(artistID)
    }

    /// Kick off an Instant Mix ("album radio") seeded by this album.
    /// TODO: #144, #327 — Instant Mix endpoint + modal not yet wired.
    func startAlbumRadio(album: Album) {
        // TODO: #144 / #327 — Instant Mix FFI not yet wired.
        print("[AppModel] startAlbumRadio(album:) not yet wired — see #144 / #327")
    }

    // MARK: - Sharing

    /// Jellyfin web URL for an album, e.g.
    /// `https://server.example.com/web/#/details?id=<albumId>`.
    func webURL(for album: Album) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(album.id)")
    }

    /// Copy the album's web URL to the system pasteboard.
    func copyShareLink(album: Album) {
        guard let url = webURL(for: album) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the album in the Jellyfin web UI.
    func openInJellyfin(album: Album) {
        guard let url = webURL(for: album) else { return }
        NSWorkspace.shared.open(url)
    }

    func pause() { audio.pause() }
    func resume() { audio.resume() }
    func stop() { audio.stop() }

    func skipNext() {
        if let next = core.skipNext() {
            playCurrent(next)
        } else {
            stop()
        }
    }

    func skipPrevious() {
        if let prev = core.skipPrevious() {
            playCurrent(prev)
        }
    }

    func setVolume(_ v: Float) { audio.setVolume(v) }

    func togglePlayPause() {
        switch status.state {
        case .playing: pause()
        case .paused: resume()
        default: break
        }
    }

    private func playCurrent(_ track: Track) {
        do {
            try audio.play(track: track)
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    private func handleTrackEnded() {
        // Advance to the next track in the queue if there is one.
        if let next = core.skipNext() {
            playCurrent(next)
        }
    }

    // MARK: - Status polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.status = self.core.status()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Convenience

extension Track {
    var durationSeconds: Double {
        Double(runtimeTicks) / 10_000_000.0
    }
    var durationFormatted: String {
        let total = Int(durationSeconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
