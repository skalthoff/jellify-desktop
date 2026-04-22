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
