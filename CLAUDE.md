# CLAUDE.md — jellify-desktop

Contributor notes for this repo. Complements the workspace-level
CLAUDE.md one directory up.

## Repo shape

- `core/` — Rust library (UniFFI-exposed). All network + state lives here.
  Synchronous API, `parking_lot::Mutex` guards `Inner`. Every FFI call
  serializes through that mutex.
- `macos/` — SwiftUI app. Consumes `JellifyCore` via the committed
  `macos/Jellify.xcframework` + generated `macos/Sources/JellifyCore/Generated/jellify_core.swift`.
  AudioEngine wraps AVQueuePlayer; Nuke handles artwork.
- `core/src/client.rs` (92KB) — Jellyfin REST client. Heavy rebase-conflict
  hotspot; see "Merge hygiene".
- `core/src/tests.rs` (4000+ lines) — tests always append at EOF, so every
  concurrent PR collides on rebase. See "Merge hygiene".
- `macos/Sources/Jellify/AppModel.swift` (~4000 lines) — the single
  `@MainActor` view model. Every screen reads from it. **Conflict
  hotspot #1; don't work on it from two concurrent branches.**
- `macos/Sources/Jellify/JellifyApp.swift` — app scaffold. **Conflict
  hotspot #2.**

## Build gates

`swift build` alone is not a full gate — it happily skips recompilation of
files whose sources didn't change. Before merging FFI-adjacent work:

```bash
rm -rf macos/.build && swift build --package-path macos
```

If a PR modifies `core/src/lib.rs` or anything in `core/src/models.rs` that
carries `uniffi::Record` / `uniffi::Enum`, the xcframework and
`jellify_core.swift` bindings need regeneration:

```bash
./macos/Scripts/build-core.sh --arm64-only         # dev
./macos/Scripts/build-core.sh --release            # ship
```

Stale bindings compile fine against a stale xcframework — you only notice
when the app runs against an up-to-date one, or when someone pulls and
rebuilds the core fresh. Always commit regenerated bindings + xcframework
together in the same commit as the Rust change.

## Real-server smoke test

User `test` / pass `test` against `https://music.skalthoff.com` is the
fastest way to tell whether a "page is broken" is server-side or
client-side. Library endpoint returns 20060 albums / 3839 artists / 78
playlists / 254 genres. Use this before diving into code:

```bash
TOKEN=$(curl -sS -X POST "https://music.skalthoff.com/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'Authorization: MediaBrowser Client="probe", Device="probe", DeviceId="probe-001", Version="0.0.0"' \
  -d '{"Username":"test","Pw":"test"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["AccessToken"])')
```

Then curl whatever endpoint the Swift side is hitting.

## Parallel-work playbook

Lessons from the April 2026 audit sweep (46 issues, 27 concurrent
branches, 8 merge waves) and the gap-fix iteration that followed. The
patterns here apply to any workflow that runs multiple branches against
this repo in parallel.

### Branch hygiene

Before branching off:

```bash
git branch --show-current          # confirm where you are
git worktree list                  # confirm which worktree is on which branch
```

Multiple worktrees in this repo can be on different branches at once.
`/Users/skalthoff/Code/active/openSourceWork/workspaces/jellify-desktop`
and `.claude/worktrees/cool-fermat-316d1d/` have pointed to different
branches inside the same working session. If you `cd` between them and
forget, you'll spend real time chasing phantom "main is broken"
reports.

Always create `fix/<descriptive-name>` off `origin/main` before making
changes, not off whatever the current working branch happens to be.

### Hotspot files — don't parallelize

- `macos/Sources/Jellify/AppModel.swift`
- `macos/Sources/Jellify/JellifyApp.swift`
- `core/src/client.rs`
- `core/src/tests.rs` (see merge hygiene)

If two concurrent branches both need to touch one of these, run them
sequentially and merge the first before starting the second.

### Tight scoping

Target per branch: 1 new file + ≤2 issues per PR. Longer scopes collide
on rebase because of the hotspots above. Every wave of the audit sweep
that broke the tight-scope rule regretted it at rebase time.

### Merge hygiene — tests.rs collision pattern

Every PR appending tests at EOF of `core/src/tests.rs` collides on
rebase. Resolution script:

```bash
# Pick the main-side tests, then manually append the incoming PR's tests.
git checkout --ours core/src/tests.rs
# Find the line where the incoming PR's tests start in the commit
# (usually after the pre-rebase EOF), then:
git show <incoming-commit>:core/src/tests.rs | sed -n '<start>,$p' >> core/src/tests.rs
# Verify no stray '<<<<<<< HEAD' markers remain:
grep -n '<<<<<<< HEAD' core/src/tests.rs   # should be empty
```

If a leftover conflict marker slips through, clippy will fail —
`sed -i '' '/<<<<<<< HEAD/d; />>>>>>> /d' core/src/tests.rs` is the
emergency cleanup.

### Signed commits + hook failures

`commit.gpgsign=true` is set globally. Scripted / CI-like environments
without access to the signing key will fail the commit hook. Don't
bypass with `--no-gpg-sign`. Don't `--amend` after a hook failure
either — the commit didn't happen, so amend would modify the previous
one. Fix the underlying issue, re-stage, and create a fresh commit.

### Auto-merge is cheap

`gh pr merge <n> --squash --auto --delete-branch` queues the merge
when CI goes green; it returns immediately, so you can queue several
PRs and keep working. Check completion with
`gh pr view <n> --json state,mergedAt`. Don't poll in a sleep loop —
the merge either happens instantly (if CI is clean + branch protection
allows) or waits for CI.

## Runtime gaps — common patterns

Catalogued during the April 2026 audit sweep. Recurring shapes to
check for when PRs land:

1. **`try?` + `print` stubs rot silently.** Any function whose body is
   `print("[AppModel] X not yet wired — see #Y")` should be treated as
   a live bug, not a TODO. Grep pattern: `print.*not yet wired` +
   `TODO\(core-#`. Several of these had shipped for weeks before being
   rewired.

2. **Sync FFI on the MainActor.** Every `try core.X(...)` on a
   `@MainActor`-attributed function takes the Rust `Inner` mutex on
   the main thread. Per-scroll / per-cell call sites beach-ball the UI
   under contention. Patterns:
   - Memoize idempotent ones (e.g. `imageURL`).
   - Wrap the call in `Task.detached` and marshal the result back to
     main.
   - Move polling loops off main (the 500ms `core.status()` poll
     remains on main in the polling timer — pending fix).

3. **Paged-cache-only resolution.** Any screen that resolves its
   subject via `model.<things>.first { $0.id == targetId }` breaks for
   libraries larger than one page. Resolvers should always fall back
   to a core FFI on cache miss. `AppModel.resolveArtist` /
   `resolveAlbum` are the reference pattern.

4. **Tuple-destructure awaits.** `try await (a, b, c)` cancels
   assignment for all three on any single error. Prefer independent
   do/catch blocks so one flaky endpoint doesn't sink a whole page.

5. **Optimistic UI without server echo.** Any mutation that updates
   local state + prints "TODO not yet wired" — grep for them before
   treating as done. Server state drifts silently.

## Deferred / known-open work

- `/Sessions/Playing*` reporting (report_playback_started / progress /
  stopped) FFIs exist, zero Swift callers. No PlayCount, no Now
  Playing on other clients, no resume points.
- Queue `playNext` / `addToQueue` semantics: fall through to `play()`
  and clobber queue. Needs core `insert_next` / `append_to_queue`
  primitives (#282).
- PRs still open needing rebase: #555 (typed enums + ItemsQuery), #560
  (i18n String Catalog), #639 (heartbeat scheduler).
