# Contract Tests

This directory contains the contract-test infrastructure for `jellify_core`.
Each test replays a golden JSON fixture through a `wiremock` mock server,
calls a `JellyfinClient` method, and snapshots the parsed Rust type with
`insta`. Any schema drift between the Jellyfin server responses and the Rust
models produces a snapshot diff that CI catches before it ships.

## Directory layout

```
core/tests/
  contract.rs                  # Integration test file (one test per endpoint)
  contract/
    fixtures/                  # Golden JSON responses (one file per endpoint)
      album_tracks.json
      similar_items.json
      search.json
    snapshots/                 # insta-managed snapshot files (committed to git)
    README.md                  # This file
```

## Running the tests

```bash
# Run all contract tests (offline, no real server needed):
cargo test --test contract

# Run a single test by name:
cargo test --test contract contract_album_tracks
```

## Accepting / updating snapshots

When you add a new test or change a fixture, run with `INSTA_UPDATE=always`
to write (or overwrite) the snapshot files:

```bash
INSTA_UPDATE=always cargo test --test contract
```

Review the diff with `git diff core/tests/contract/snapshots/` before
committing. The snapshot files live under version control so future runs can
detect regressions without a live server.

You can also use the `cargo-insta` CLI for an interactive review workflow:

```bash
cargo install cargo-insta
cargo insta review
```

## Adding a new contract test

1. **Add a fixture** — create `core/tests/contract/fixtures/<endpoint>.json`
   with a minimal but realistic Jellyfin response body (aim for ≤50 lines).
   Mirror the exact field names Jellyfin uses (`PascalCase` keys, etc.).

2. **Write the test** — add a `#[tokio::test]` function in
   `core/tests/contract.rs` following the pattern of the existing tests:
   - Call `load_fixture("<endpoint>")` to load the JSON.
   - Mount it on a `wiremock::MockServer` route matching the real URL path.
   - Construct an `authenticated_client(&server)`.
   - Call the client method under test.
   - Snapshot with `insta::assert_yaml_snapshot!("<endpoint>", result)`.

3. **Accept the initial snapshot** — run
   `INSTA_UPDATE=always cargo test --test contract contract_<your_test>`.

4. **Commit both files** — the fixture JSON and the generated snapshot.

## Reviewing snapshot diffs in CI

When CI fails with a snapshot mismatch, the diff output shows the exact field
that changed. Download the failing artifact (or fetch the updated
`*.snap.new` file) and run `cargo insta review` locally to accept or reject
the change.
