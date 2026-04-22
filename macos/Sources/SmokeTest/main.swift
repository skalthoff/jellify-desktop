import Foundation
import AppKit
import AVFoundation
@preconcurrency import JellifyCore
import JellifyAudio

// Headless smoke test: logs into a Jellyfin server, plays the first track of
// the first album via AudioEngine, and reports transport state for 12 seconds.
// Uses env vars JELLYFIN_URL / JELLYFIN_USER / JELLYFIN_PASS.

@main
@MainActor
struct SmokeTest {
    static func main() async {
        // AVPlayer needs an active NSApplication to dispatch events properly.
        _ = NSApplication.shared

        let urlStr = ProcessInfo.processInfo.environment["JELLYFIN_URL"] ?? ""
        let user = ProcessInfo.processInfo.environment["JELLYFIN_USER"] ?? ""
        let pass = ProcessInfo.processInfo.environment["JELLYFIN_PASS"] ?? ""
        guard !urlStr.isEmpty else {
            fputs("set JELLYFIN_URL=...\n", stderr)
            exit(2)
        }

        let tmpDir = NSTemporaryDirectory() + "jellify-smoke-\(UUID().uuidString)"
        let core: JellifyCore
        do {
            core = try JellifyCore(
                config: CoreConfig(dataDir: tmpDir, deviceName: "Jellify SmokeTest")
            )
        } catch {
            fputs("core init: \(error)\n", stderr); exit(1)
        }

        do {
            let server = try core.probeServer(url: urlStr)
            print("connected to \(server.name) v\(server.version ?? "?")")
        } catch { fputs("probe: \(error)\n", stderr); exit(1) }

        let session: Session
        do {
            session = try core.login(url: urlStr, username: user, password: pass)
            print("logged in as \(session.user.name)")
        } catch { fputs("login: \(error)\n", stderr); exit(1) }

        let albums: [Album]
        do {
            albums = try core.listAlbums(offset: 0, limit: 5)
        } catch { fputs("list albums: \(error)\n", stderr); exit(1) }
        guard let album = albums.first else {
            fputs("no albums on server\n", stderr); exit(1)
        }
        print("first album: \(album.name) — \(album.artistName)")

        let tracks: [Track]
        do {
            tracks = try core.albumTracks(albumId: album.id)
        } catch { fputs("album tracks: \(error)\n", stderr); exit(1) }
        guard let first = tracks.first else {
            fputs("album has no tracks\n", stderr); exit(1)
        }
        print("playing: \(first.name) (\(Int(first.durationSeconds))s)")

        let engine = AudioEngine(core: core)
        engine.onTrackEnded = { print("track ended") }

        do {
            _ = try core.setQueue(tracks: tracks, startIndex: 0)
            try engine.play(track: first)
        } catch {
            fputs("play: \(error)\n", stderr); exit(1)
        }

        // Observe transport for ~12 seconds.
        var lastState: PlaybackState = .idle
        for i in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let s = core.status()
            if s.state != lastState {
                print("[\(i)s] state=\(s.state) pos=\(String(format: "%.1f", s.positionSeconds))s")
                lastState = s.state
            } else {
                print("[\(i)s] state=\(s.state) pos=\(String(format: "%.1f", s.positionSeconds))s")
            }
        }
        engine.stop()
        print("done")
        exit(0)
    }
}

extension Track {
    var durationSeconds: Double { Double(runtimeTicks) / 10_000_000.0 }
}
