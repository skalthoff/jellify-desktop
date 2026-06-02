# Agentic pipeline — operations playbook

How the multi-agent dev pipeline for lyrebird-desktop is run, what the knobs
mean, and the failure modes learned the hard way. The narrative campaign logs
live in `CLAUDE.md` ("… campaign — findings" sections); this file is the
durable **how-to-run** reference. The orchestration scripts themselves are
tracked under `.claude/workflows/`.

## The two workflows

- **`.claude/workflows/drive-lyrebird-desktop.js`** — the workhorse. Each wave:
  resolve open agent PRs → (optionally) audit for regressions → triage → select
  real open backlog (bugs p0→p2, then M3 features) → build → adversarial review
  (≤2 refix rounds) → auto-merge. Use this to actually move the backlog.
- **`.claude/workflows/finalize-lyrebird-desktop.js`** — audit-driven; only fixes
  freshly-audited bugs + a feature track. Narrower; prefer `drive`.

Run with `Workflow({scriptPath: ".../.claude/workflows/drive-lyrebird-desktop.js", args: {...}})`.

## Config knobs (drive)

| arg | meaning | good default |
| --- | --- | --- |
| `maxWaves` | hard wave cap | 40 (token budget stops it first) |
| `buildCeiling` | max PRs opened per wave | **≈ review throughput (6–8)**, NOT higher |
| `backlogBatch` | candidate issues pulled per wave | 16–18 |
| `builderModel` | model for builders + refixers | `opus` for features/core; `sonnet` fine for UI bulk |
| `reviewModel` | first-pass reviewer | `sonnet` (+ opus on dispute) |
| `auditEvery` | audit every Nth wave; `0` = never | `0` for a pure feature push; `4–5` otherwise |
| `ciGated` | builders skip local compile, rely on GH Actions | **`false`** (see CI-gated finding) |
| `includeDist` | pull M4 dist work | `false` unless intentionally on dist |

### Recommended recipes

- **Feature push:** `{auditEvery:0, ciGated:false, buildCeiling:7, backlogBatch:18, builderModel:'opus', includeDist:false}`
- **Bug/regression drain:** `{auditEvery:4, buildCeiling:8, builderModel:'sonnet'}`

## The hard-won rules

1. **Concurrency cap = `min(16, cores−2)`** (8 on the 10-core box). `cargo`/`swift`
   compiles are CPU-bound; more builders than cores thrash. Never run two
   workflows against this repo at once. Set `buildCeiling` ≤ the cap.

2. **Review is the bottleneck, and reviewer calibration is load-bearing.** The
   single serial reviewer caps throughput — raising `buildCeiling` above it just
   grows an unreviewed queue. Worse: the stock `adversarial-reviewer.md` framing
   ("approving is the exception", "one finding per category") makes the reviewer
   **manufacture rejections on correct PRs** (it once rejected a 2-line dict fix,
   7/7 PRs `request-changes`, ~0 merges/wave). The `drive` review prompt now
   **overrides** that with a calibration block: approve when the diff does what
   the issue asks + scope-locked + CI green + no concrete file:line defect; the
   8 categories are a *lens, not a quota*. After calibration the same agent
   approved 7/7 correct PRs **and** still caught real defects (falsified test
   claims, wrong paths). The shared agent-def keeps the strict default for the
   single-issue bug pipeline / `/desktop-review`.

3. **CI gates auto-merge, so `main` stays green.** `--squash --auto` only lands on
   green CI. Lean on this rather than reasoning about each merge.

4. **"Commits not landing" is usually a MERGE-gap, not a build-gap.** Builders
   commit + open mergeable green PRs reliably; stalls happen at review→merge.
   Diagnose by reading review *outcomes* in the run journal
   (`subagents/workflows/wf_*/journal.jsonl`), not by whether PRs exist.

5. **`ciGated:true` underperforms.** Skipping the local build just moves the cost
   to a red-PR pileup (most PRs fail the `macOS app` CI job and sit there unless a
   builder re-drives them). Local-build mode lands a higher fraction of what it
   opens. FFI-adjacent PRs *cannot* skip local build anyway — they must regen +
   commit the xcframework/bindings or CI goes red on stale bindings.

6. **Tar-pit PRs stall every relaunch.** Conflicting/`DIRTY` or repeatedly-rejected
   PRs make the resolve-open-PRs phase burn whole waves, then stop `idle` with the
   backlog untouched. Before relaunch, **close** them (the issue stays open → rebuilt
   clean); keep only mergeable+green+unreviewed. Enforced in the babysitter prompt.

7. **Self-approval is blocked** when the PR author == the merging user. A reviewer
   agent's `gh pr review --approve` fails on self-authored PRs; merge directly with
   `gh pr merge <n> --squash [--auto] --delete-branch`.

8. **Trust git/gh, not the workflow self-tally.** Runs over-count merges (count
   `--auto`-queued PRs that never landed). Reconcile against `git log origin/main`
   + `gh pr list --state merged`.

9. **`gh issue list --label X` intermittently returns `[]` with no error** on this
   box. Count the backlog by pulling the full open list and aggregating client-side:
   `gh issue list --state open --limit 250 --json labels,milestone --jq '[.[]|{f:([.labels[].name]|any(.=="kind:feat")),m3:(.milestone.title=="M3 — macOS polish")}]|"M3feat=\([.[]|select(.f and .m3)]|length)"'`

10. **Red SourceKit diagnostics are usually environmental.** "No such module
    'LyrebirdCore'/'Nuke'", "Cannot find Theme/AppModel" come from unbuilt builder
    worktrees, not `main`. Confirm against `main` CI before treating as breakage.

## Overnight (babysitter) pattern

A `ScheduleWakeup` every ~45 min: check the run is alive + `main` green, relaunch
if dead (each relaunch = fresh token budget; wave-1 resolve-open-PRs recovers
in-flight work losslessly), close tar-pit PRs first, and **stop** on backlog drain
/ human-gated-only / red-`main`-for-a-non-cache-reason. It does **not** self-limit
on cost — confirm you want continuous overnight spend before arming.

## Known infra gotchas

- **Poisoned SwiftPM cache breaks `main` CI reproducibly** (not a flake). Symptom:
  `macOS app` job fails `error: XCFramework Info.plist not found at
  .build/artifacts/sparkle/Sparkle/Sparkle.xcframework` while `test (macos-15)`
  passes. Cause: ci.yml caches `macos/.build` keyed on `hashFiles(Package.swift,
  Package.resolved)`; unchanged files restore a `.build` with a dangling Sparkle
  ref. Fix: `gh cache list --json key --jq '.[]|select(.key|test("spm";"i")).key'`
  → `gh cache delete <key>` each → re-run. Permanent fix (TODO): add Sparkle's
  resolved revision to the cache key.

- **Stale `wf_*-N` worktrees pile up** (one per builder; hit 99). `git worktree
  prune` + remove abandoned ones periodically — never those backing an open PR.

- **`@`-in-prose makes GitHub @mentions.** Swift property wrappers (`@State`,
  `@MainActor`) in PR/issue/commit text get linkified. Backtick them in bodies;
  drop the `@` in titles. Now in the builder + auditor prompts.

## Release builds

Push a `v*` tag → `.github/workflows/macos-release.yml` signs + notarizes + publishes
a DMG (all Apple secrets are configured in the repo). Pre-release tags
(`-rc`/`-beta`) are marked pre-release by the workflow (fixed; previously grabbed
"Latest"). See `docs/GITHUB-SECRETS.md`.
