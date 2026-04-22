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

The generated `linux/flatpak/cargo-sources.json` is checked in so CI and
packagers don't need network access to rebuild. Commit the regenerated file
alongside the `Cargo.lock` change that invalidated it.

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
