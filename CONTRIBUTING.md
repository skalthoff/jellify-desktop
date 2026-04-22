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
