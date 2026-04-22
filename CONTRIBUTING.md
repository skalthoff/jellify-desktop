# Contributing

Thanks for your interest. This project is early — shapes and conventions are still settling.

## Development loop

### macOS

```sh
cd macos
./Scripts/build-core.sh   # Re-run whenever core/ changes
swift build
./.build/arm64-apple-macosx/debug/Jellify       # unbundled (dev)
# or
./Scripts/make-bundle.sh && open build/Jellify.app  # bundled
```

### Core

```sh
cargo test --workspace
cargo clippy --workspace -- -D warnings
cargo fmt --all
```

Regenerate Swift bindings when the Rust API changes:

```sh
cd macos && ./Scripts/build-core.sh
```

## Flatpak packaging

Offline Flatpak builds need a `cargo-sources.json` describing every crate the
build will fetch. Regenerate it after any change to `Cargo.lock`:

```sh
./linux/flatpak/gen-sources.sh
```

The script wraps `flatpak-cargo-generator.py` from
[`flatpak-builder-tools`](https://github.com/flatpak/flatpak-builder-tools);
it will download a copy into `linux/flatpak/.cache/` on first run if the
generator isn't already on `PATH` or pointed at by `$FLATPAK_CARGO_GENERATOR`.
Requires `python3` with `aiohttp` and `toml` installed.

The generator is pinned to a specific upstream commit (see the `GENERATOR_PIN`
variable in `linux/flatpak/gen-sources.sh`) for reproducibility and
supply-chain safety. Bump the pin manually during dependency updates.

The generated `linux/flatpak/cargo-sources.json` should be regenerated and
committed alongside dependency changes so CI and packagers don't need network
access to rebuild. Run the script whenever `Cargo.lock` changes and commit the
regenerated file in the same PR.

## Commit style

- Short, imperative subject line ("add X", "fix Y"). No prefixes.
- Body explains *why*, not *what* — the diff already shows the what.
- Don't mention AI tools, pair programming, or co-authors.

## Branch + PR

1. Branch off `main`.
2. Keep PRs small and focused. One concern per PR.
3. Link to the issue the PR resolves in the description.
4. Run `cargo test`, `swift build`, and the SmokeTest if your change touches audio or API flows.

## Issues

- Use the templates in `.github/ISSUE_TEMPLATE/` (if present) for bugs, features, and polish.
- Label thoroughly — `area:` labels (macos, core, windows, linux, design) and `kind:` labels (bug, feat, polish, chore).
- Put the reproduction steps in the body, not the title.

## Scope boundaries

- `core/` stays platform-neutral. Anything audio-output, UI, or OS-integration belongs in a platform folder.
- Design tokens and visual rules are platform-neutral; add them to `design/`.
- Don't vendor binary artifacts. Generated code (UniFFI output, xcframework) is built by scripts; don't commit it.

## Media keys (macOS)

macOS 10.12.2+ routes F7/F8/F9 and Touch Bar transport button presses through `MPRemoteCommandCenter`. The OS delivers each press to the "most recently active" media app — the app that most recently wrote to `MPNowPlayingInfoCenter.default().nowPlayingInfo`. There is no foreground-app requirement and no accessibility permission to grant; whichever media app last announced itself is the target.

Jellify wins that race by populating `MPNowPlayingInfoCenter` from its `MediaSession` on every track change and transport action. After any play/pause/skip in Jellify, the OS considers Jellify the most-recent media app until another player (Music.app, Spotify, a browser playing media, etc.) overwrites `nowPlayingInfo`. No separate `HIDManager` / private `MediaRemote` keylogger route is needed — that was the pre-Sierra workaround and is obsolete.

A common user-facing symptom: "F8 stopped working in Jellify." Nine times out of ten this is because the user opened Music.app or another media app afterward and that app stole the most-recent slot. Playing anything in Jellify again reclaims it.

To verify media keys work locally:

1. Quit Music.app, Spotify, and any browser tab playing audio.
2. Play a track in Jellify. This makes Jellify the most-recent media app.
3. Press F7 / F8 / F9 (or `fn` + the equivalent if the function-key row is remapped to brightness/volume in System Settings). F8 toggles play/pause; F7 skips previous; F9 skips next.
4. Touch Bar transport controls on supported hardware follow the same path.

Bluetooth / AirPods multifunction-button presses arrive through the same `MPRemoteCommandCenter` surface, so they're covered by the same handlers.

Reference: [iina/iina#1110](https://github.com/iina/iina/issues/1110) discusses the history of the private `MediaRemote` framework era and why it's no longer necessary on macOS 10.12.2+.
