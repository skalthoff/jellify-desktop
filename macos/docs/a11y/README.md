# macOS Accessibility Audits

We run Accessibility Inspector against every top-level screen so that
regressions show up as diffs against a known baseline instead of user reports.
This directory holds the baseline and every periodic re-run; each fix PR
should reference the audit row it closes out.

## Running an audit

1. Launch the app in a debug build. The easiest path is the helper script
   [`../../Scripts/a11y-audit.sh`](../../Scripts/a11y-audit.sh), which builds
   `Jellify.app` and launches it in the background.
2. Open **Xcode → Open Developer Tool → Accessibility Inspector**.
3. In the Inspector window, use the **target chooser** at the top-left to
   select the running `Jellify` process.
4. Switch to the **Audit** panel and click **Run Audit**.
5. Walk the app through each screen listed below. Run the audit once per
   screen — Accessibility Inspector only inspects what is currently visible,
   so state matters.

### Screens to cover

Run the Audit panel against each of these states and save the report to
`audits/<YYYY-MM-DD>/<screen>.txt`:

- `login.txt` — Login screen, before any server is configured.
- `library.txt` — Library tab, populated.
- `search.txt` — Search tab with a non-empty query.
- `album-detail.txt` — Album detail view with a track list rendered.
- `home-empty.txt` — Home tab in its empty state (fresh library, no recents).
- `playerbar-playing.txt` — PlayerBar docked, track actively playing.
- `playerbar-idle.txt` — PlayerBar docked, no track loaded.

### Saving the report

In Accessibility Inspector, use **File → Save** (or the share/export button
in the Audit panel) and choose **Plain Text**. Save into the dated folder
for this run so the git history reflects when the audit was taken.

## Known issues at baseline

The items below are the expected findings on the current build. They are
tracked as follow-up issues — fixing them should flip the corresponding
audit row green on the next run.

| Finding                                                    | Source                                               | Tracking |
| ---------------------------------------------------------- | ---------------------------------------------------- | -------- |
| Icon-only buttons have no VoiceOver label (shuffle, repeat) | `Sources/Jellify/Components/PlayerBar.swift` `iconBtn("shuffle")`, `iconBtn("repeat")` | [#331](https://github.com/skalthoff/jellify-desktop/issues/331) |
| Logout button in Sidebar has no VoiceOver label             | `Sources/Jellify/Components/Sidebar.swift`           | [#331](https://github.com/skalthoff/jellify-desktop/issues/331) |
| Progress bar is not an accessible slider                    | PlayerBar scrubber                                   | [#332](https://github.com/skalthoff/jellify-desktop/issues/332) |
| Track row sub-labels announce separately                    | TrackRow                                             | [#333](https://github.com/skalthoff/jellify-desktop/issues/333) |
| No logical tab order / Shift-Tab traversal                  | Focus system                                         | [#334](https://github.com/skalthoff/jellify-desktop/issues/334) |
| No visible themed focus ring                                | Focus system                                         | [#335](https://github.com/skalthoff/jellify-desktop/issues/335) |
| `@FocusState` not wired for search autofocus / modal focus  | Search, modals                                       | [#336](https://github.com/skalthoff/jellify-desktop/issues/336) |
| No Dynamic Type / scaledFont support on Figtree             | Theme                                                | [#337](https://github.com/skalthoff/jellify-desktop/issues/337) |
| PlayerBar and Sidebar do not reflow at large text sizes     | Layout                                               | [#338](https://github.com/skalthoff/jellify-desktop/issues/338) |

Anything else the Audit panel reports — and which is not in the table above
— counts as **unexpected** and should open a new issue labelled
`area:a11y` + `area:macos` before landing any unrelated change.

## Follow-up fix issues

All open a11y follow-ups can be listed with:

```sh
gh issue list --label area:a11y --label area:macos
```

Fix PRs should:

- Cite the audit row they resolve (screen + finding).
- Attach a new audit run under `audits/<today>/` showing the row cleared.
- Link the tracking issue from the "Known issues at baseline" table above
  (and strike the row once it is no longer reproducible on `main`).

## Repeat audits

Use [`../../Scripts/a11y-audit.sh`](../../Scripts/a11y-audit.sh) to spin up
a fresh `Jellify.app` in a known state. The script prints its PID and waits
on `Ctrl-C` so you can keep Accessibility Inspector attached for the entire
sweep and kill the app cleanly when done.
