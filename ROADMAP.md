# Jellify Desktop — Roadmap

> Living document. Status as of initial-scoping sprint; revise with every milestone close.

## Goal

Ship a **native desktop Jellyfin client** — no Electron, no webview — that feels indistinguishable from a first-party app on each target OS. Target polish bar: Apple Music, Spotify, and Doppler. Not a music-collection-mapping tool; a daily-driver music player.

## Status

- **M1 — Rust core foundation** ✅ Completed. Jellyfin REST client, SQLite cache, keyring credential store, queue state, UniFFI bindings. `cargo test --workspace` passes.
- **M2 — macOS app MVP** ✅ Completed. SwiftUI shell (Login, Library grid, Album detail, Search, PlayerBar), AVPlayer-backed streaming, headless `SmokeTest` integration verifier. End-to-end playback validated against a real Jellyfin server.
- **M3 — macOS polish** 🔵 In progress. Driven by the research sprint captured in [/tmp/jellify-research](../..//tmp/jellify-research) and the issues filed under the `M3 — macOS polish` milestone.
- **M4 — macOS distribution** 🟢 Operational. v0.2.0 shipped 2026-04-25 (Apple Silicon DMG, Sparkle appcast live). Apple Silicon only — Intel is out of scope; the install base no longer justifies the multi-arch build complexity.
- **M5 — Windows port** ⚪ Scoped. WinUI 3 + UniFFI .NET bindings + SMTC + MSIX.
- **M6 — Linux port** ⚪ Scoped. GTK4 + libadwaita + GStreamer + MPRIS2 + Flathub.

### Active release: v0.3.0 — "Feature-gap closure" 🔵 In progress

Wires the visible "not yet wired" stubs in `AppModel.swift` as real FFI calls
(downloads, add-to-playlist, mark-as-played, artist play/shuffle, genre browse,
similar artists, Instant Mix everywhere).

Out of scope for 0.3 (deferred to 0.4): lyrics, mini-player, crossfade/EQ
wiring, perf refactors, Swift 6 / Sendable migration, the P1/P2 sweep from
audit issue #610.

## Milestones

### M3 — macOS polish

Deliverable: the macOS app is *objectively* within design tolerance of the prototype, with Apple Music-equivalent interactions. Every screen works end-to-end with loading/error/empty states. Menu bar populated, media keys routed, keyboard shortcut map complete. `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` surface Now Playing to Control Center and the lock screen.

Key work — see issues under `milestone:M3 — macOS polish`:
- Adopt `NavigationSplitView` as the shell; full `.toolbar {}` and `.commands {}` blocks.
- Full screen set: Home, Library (tabs + grid/list toggle), Album, **Artist**, **Playlist**, Search (instant + categorized), **Discover**, **Radio**, **Settings**, **Full-screen player**, **Mini player**.
- Right panel: Now Playing / Queue (drag-reorder) / Lyrics (LRC sync).
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, AVQueuePlayer-based gapless.
- Playlist CRUD + Favorites + Play-state reporting + Instant Mix via Jellyfin API additions.
- Accessibility: VoiceOver, focus rings, Dynamic Type, Reduce Motion.
- Image caching, virtualized lists, library pagination.

### M4 — macOS distribution

Deliverable: `gh release create vX.Y.Z` produces a signed, notarized, stapled `Jellify.dmg` that launches without Gatekeeper prompts on a clean Mac. Sparkle appcast serves updates.

Key work:
- Developer ID signing + hardened runtime entitlements.
- `notarytool` CI pipeline with Keychain-stored credentials.
- `create-dmg` packaging, Apple Silicon only (Intel out of scope).
- Sparkle 2 via SPM, EdDSA-signed appcast hosted on GitHub Pages.
- Crash reporting (opt-in Sentry-Cocoa).

### M5 — Windows port

Deliverable: WinUI 3 app matches macOS MVP scope (login → library → album → play) with SMTC integration. MSIX package.

### M6 — Linux port

Deliverable: GTK4 + libadwaita app matches macOS MVP. MPRIS2 integration. Flatpak published to Flathub.

## Cross-cutting tracks

These tracks span multiple milestones:

- **Accessibility** — baseline ships in M3; ongoing per-screen audits after.
- **Internationalization** — English only through M3; first translation wave after M4.
- **Performance + reliability** — image caching and virtualization land in M3; crash reporting in M4; observability stack in Backlog.
- **Documentation** — user docs, contributor docs, screenshots; milestone by milestone.

## Labels + milestones

- **Areas**: `area:core`, `area:macos`, `area:windows`, `area:linux`, `area:audio`, `area:api`, `area:ux`, `area:design`, `area:a11y`, `area:i18n`, `area:perf`, `area:reliability`, `area:observability`, `area:dist`, `area:ci`, `area:docs`
- **Kind**: `kind:feat`, `kind:bug`, `kind:polish`, `kind:chore`, `kind:security`, `kind:question`
- **Priority**: `priority:p0` (blocking) → `p3` (someday)
- **Effort**: `S` (≤ half day) · `M` (1-3 days) · `L` (1 week) · `XL` (multi-week)
- **Milestones**: M3, M4, M5, M6, Backlog

## Research source

The issue set was generated from a coordinated research sprint — see [Scripts/create-issues.py](Scripts/create-issues.py) for the batching tool and `<sub>Source: NN-*.md</sub>` footers on each issue for traceability.
