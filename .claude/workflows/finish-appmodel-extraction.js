export const meta = {
  name: 'finish-appmodel-extraction',
  description: 'Finish the AppModel.swift god-object split: sequentially extract the remaining method domains into AppModel+X.swift files on the current branch (shared tree, no worktree isolation), clean-build + test, then adversarially review the diff.',
  phases: [
    { title: 'Extract', detail: 'one builder per domain, bottom-of-file to top, sequential' },
    { title: 'Verify', detail: 'clean rebuild + full test suite' },
    { title: 'Review', detail: 'parallel calibrated reviewers, one lens each' },
  ],
}

// ---- Shared rules every builder must obey -------------------------------
const BASE_RULES = [
  'CONTEXT: macos/Sources/Lyrebird/AppModel.swift is a single `@Observable @MainActor final class AppModel` god-object being shrunk by moving cohesive METHOD domains into `extension AppModel` files. This is pure-Swift relocation — no FFI, no behavior change.',
  '',
  'ENVIRONMENT: You are ALREADY on branch `refactor/appmodel-finish-extraction` in a SHARED working tree. Prior builders in this run have already moved their domains (their edits are present, uncommitted). Do NOT create/switch/checkout branches. Do NOT commit. Do NOT push. Do NOT run git reset/stash/clean. Only Read/Edit/Write the files named below and run `swift build`.',
  '',
  'HARD RULE 1 — stored properties NEVER move. A stored property is a `var`/`let` holding plain state (NO computed `{ ... }` body). They are `@Observable`-tracked and MUST stay in AppModel.swift. Only methods (`func`) and COMPUTED properties (`var x: T { ... }`) may move. If a stored prop sits textually between two methods you are moving, leave it exactly where it is and move the methods around it (a multi-range edit).',
  '',
  'HARD RULE 2 — promote the MINIMUM. A `private`/`fileprivate` member only needs promotion to `internal` if (a) it STAYS in AppModel.swift AND (b) a method you MOVED calls it (cross-file invisibility). A `private` helper whose every caller also moves can stay `private` in the new file. Over-promotion is the #1 review rejection — promote nothing speculatively. When you promote, drop only the `private`/`fileprivate` keyword (default access = internal); do not add an explicit `internal` keyword unless the surrounding file style does.',
  '',
  'VERBATIM: move each method body exactly as written — no logic edits, no renames, no signature changes, no statement reordering, no reformatting. Indentation is 4 SPACES (this Swift app does NOT use tabs).',
  '',
  'LOCATE BY SYMBOL, NOT LINE NUMBER: line numbers drift as methods are removed. For every function, `grep -n` its name in AppModel.swift to get its CURRENT location, read that exact region, then act. Never trust an absolute line number from this prompt — they are hints only.',
  '',
  'NEW-FILE TEMPLATE (when creating a file):',
  '    import AppKit',
  '    import Foundation',
  '    import SwiftUI',
  '    @preconcurrency import LyrebirdCore',
  '    // add `import os` / `import MediaPlayer` / `import LyrebirdAudio` / `import Observation` ONLY if your moved code references those symbols',
  '',
  '    extension AppModel {',
  '        // moved methods here, unchanged, 4-space indent',
  '    }',
  'Top-of-file doc comment: ONE durable sentence naming the domain (e.g. `/// Session lifecycle: login, restore, logout, and auth-error handling.`). NO process/campaign prose — never write "Phase N", "extracted from AppModel", "pure relocation", "moved verbatim"; the reviewer rejects that.',
  '',
  'APPEND MODE (when adding to an existing AppModel+*.swift): place the moved method INSIDE the existing `extension AppModel { ... }` block (before its final closing brace). Add an import only if newly needed.',
  '',
  'BUILD GATE: after editing, from the repo root run `swift build --package-path macos 2>&1 | tail -40`. It MUST succeed. A "cannot find X in scope" / "X is inaccessible due to private protection level" error means you under-promoted (promote that one member) or missed an import (add it) — fix and rebuild until green. Do NOT run the test suite (the Verify phase owns that). Do NOT touch macos/.build.',
  '',
  'Return the structured result: which file you created/appended, the exact methods moved, any stored props you intentionally LEFT behind in your range, every promotion you made (member + why), whether `swift build` is green, and any residual build errors.',
].join('\n')

// ---- Domains, ordered bottom-of-file -> top (descending start line) ------
// so each deletion only shifts ALREADY-processed (lower) regions.
const DOMAINS = [
  {
    name: 'AlbumDetail',
    target: 'macos/Sources/Lyrebird/AppModel+AlbumDetail.swift',
    mode: 'create',
    funcs: [
      'func loadAlbumDetail(albumId: String) async -> AlbumDetail',
      'static func parseAlbumDetail(from json: String) -> AlbumDetail',
      'func goToArtist(album: Album)',
      'func goToAlbum(album: Album)',
      'func startAlbumRadio(album: Album)',
      'func markAllAsPlayed(album: Album)',
      'func addAlbumToPlaylist(album: Album, playlist: Playlist)',
    ],
    stay: ['(none — this is the cleanest block: no stored properties in range)'],
    promote: ['(none expected)'],
    notes: 'Cleanest block. These sit just below the Offline-downloads section and above the "Track info sheet" MARK (~lines 2126-2247 on origin/main, will have drifted). They call internal members (setPlayed, addToPlaylist, nav state mutators) that remain reachable cross-file.',
  },
  {
    name: 'Strays',
    target: 'macos/Sources/Lyrebird/AppModel+Downloads.swift (enqueueDownload) and macos/Sources/Lyrebird/AppModel+PlaylistTracks.swift (addToPlaylist)',
    mode: 'append',
    funcs: [
      'func enqueueDownload(album: Album)   ->  append into AppModel+Downloads.swift',
      'func addToPlaylist(trackIds: [String], playlistId: String) async -> Bool   ->  append into AppModel+PlaylistTracks.swift',
    ],
    stay: ['(none — both are methods)'],
    promote: ['(none expected)'],
    notes: 'Two stray methods that belong in already-extracted domains. Append each into the EXISTING `extension AppModel { }` block of its target file (before the closing brace), and delete it from AppModel.swift. ~lines 2082 / 2100 on origin/main.',
  },
  {
    name: 'Favorites',
    target: 'macos/Sources/Lyrebird/AppModel+Favorites.swift',
    mode: 'create',
    funcs: [
      'func toggleFavorite(album: Album)',
      'func toggleFavorite(track: Track)',
      'func isFavorite(id: String) -> Bool',
      'func isFavorite(track: Track) -> Bool',
      'func isFavorite(album: Album) -> Bool',
      'func isFavorite(playlist: Playlist) -> Bool',
      'func isFavorite(artist: Artist) -> Bool',
      'func setFavorite(itemId: String, enabled: Bool) async',
      'func isPlayed(id: String) -> Bool',
      'func setPlayed(itemId: String, played: Bool) async',
    ],
    stay: [
      'var favoriteById   (stored — already internal)',
      'var favoriteChangeToken   (stored)',
      'var playedById   (stored)',
      'var downloadStateById / var downloads / var downloadStats / var downloadsInFlight   (stored DOWNLOAD state that happens to sit in this textual range — definitely stays)',
    ],
    promote: ['(none expected — setFavorite/setPlayed and the favorite caches are already internal)'],
    notes: 'Move ONLY the 10 methods. The "Favorite cache" MARK region holds stored caches that are interleaved with / just above the methods — leave every stored var/let untouched. ~lines 1953-2080 on origin/main.',
  },
  {
    name: 'Library',
    target: 'macos/Sources/Lyrebird/AppModel+Library.swift',
    mode: 'create',
    funcs: [
      'func refreshLibrary() async',
      'func loadMoreAlbums() async',
      'func loadMoreArtists() async',
      'func refreshTracks() async',
      'func loadMoreTracks() async',
      'func ensurePlaylistLibraryId() async -> String',
      'func refreshPlaylists() async',
      'func loadMorePlaylists() async',
      'func refreshRecentlyPlayed() async',
      'func loadAllPlaylistTracks(playlistID: String) async -> [Track]',
      'func refreshForYou() async',
      'func refreshGenresToExplore() async',
      'static func rankGenresToExplore(...)   (multi-line signature — grep "func rankGenresToExplore")',
      'func refreshBrowseGenres() async',
      'static func rankBrowseGenres(...)   (multi-line signature — grep "func rankBrowseGenres")',
      'func fetchAlbumsViaItemsQuery(...)   (multi-line signature — grep "func fetchAlbumsViaItemsQuery")',
      'func fetchAlbumsWithPlayCounts(...)   (multi-line signature — grep "func fetchAlbumsWithPlayCounts")',
      'func fetchLatestAlbumsWithDates(limit: UInt32) async -> ([Album], [String: Date])',
      'func fetchFavoriteTracks(limit: UInt32) async -> [Track]',
    ],
    stay: [
      'var artistDetailCache   (stored — already internal)',
      'var resolvedNameCache   (stored)',
      'var artistAlbumsCache   (stored)',
      'var imageURLCache   (stored)',
    ],
    promote: ['(none expected — the 4 caches are already internal; buildItemsQuery/parseTracksFromItems already live in other extensions and are internal)'],
    notes: 'BIGGEST block and MULTI-RANGE: the 4 stored caches sit BETWEEN some of these methods (under the "Library" and "Items query helpers" MARKs). Move each of the 19 methods; leave the 4 cache declarations exactly in place. After you are done, those two MARK regions in AppModel.swift should contain only stored properties, no `func`. ~lines 1199-1835 on origin/main.',
  },
  {
    name: 'Session',
    target: 'macos/Sources/Lyrebird/AppModel+Session.swift',
    mode: 'create',
    funcs: [
      'func retryNetwork()',
      'func retryServer()',
      'func login(url: String, username: String, password: String) async',
      'func attemptRestoreSession() async',
      'func logout()',
      'func forgetToken()',
      'private func resetPaginationState()',
      'func markAuthExpired()',
      'func handleAuthError(_ error: Error) -> Bool',
    ],
    stay: ['private var hasAttemptedRestore   (STORED — leave it in AppModel.swift; PROMOTE to internal)'],
    promote: [
      'hasAttemptedRestore: private -> internal  (it stays in AppModel.swift but attemptRestoreSession, which moves, reads/writes it)',
      'resetPaginationState: it MOVES to +Session. Keep it `private` IF every caller also moved; promote to internal ONLY if a method that stays in AppModel.swift (or another extension) still calls it. Verify with the build.',
    ],
    notes: 'Network retry + session auth lifecycle. The one tricky member is hasAttemptedRestore (stored, stays, needs promotion). ~lines 907-1197 on origin/main.',
  },
  {
    name: 'Window',
    target: 'macos/Sources/Lyrebird/AppModel+Window.swift',
    mode: 'create',
    funcs: [
      'func toggleMiniPlayer()',
      'func setMiniPlayerAlwaysOnTop(_ on: Bool)',
      'private static func autoplayWhenQueueEndsDefault() -> Bool',
      'func setAutoplayWhenQueueEnds(_ on: Bool)',
      'func returnToFullWindow()',
      'func openInMainWindowFromMiniPlayer(_ route: Route)',
    ],
    stay: [
      'var autoplayWhenQueueEnds   (STORED; its default initializer calls AppModel.autoplayWhenQueueEndsDefault())',
      'var isCommandPaletteOpen / var isShowingInstantMixPicker   (STORED, unrelated — just nearby)',
    ],
    promote: [
      'autoplayWhenQueueEndsDefault: private static -> internal static  (the staying stored prop `autoplayWhenQueueEnds` initializes from `AppModel.autoplayWhenQueueEndsDefault()`, a cross-file call once the method moves)',
    ],
    notes: 'Mini Player + autoplay-toggle + window restore. Move the 6 methods; leave the 3 stored props. ~lines 709-808 on origin/main. Do NOT touch selectTab / requestSidebarToggle (they live in the heavily stored-prop-interleaved top half and are out of scope).',
  },
]

function builderPrompt(d) {
  const fmt = (arr) => arr.map((x) => '  - ' + x).join('\n')
  return [
    'TASK: Extract the ' + d.name + ' domain out of AppModel.swift (mode: ' + d.mode + ').',
    'Target file(s): ' + d.target,
    '',
    BASE_RULES,
    '',
    '===== ' + d.name + ' DOMAIN =====',
    'Methods to MOVE (locate each by grepping its name — line numbers below are stale hints):',
    fmt(d.funcs),
    '',
    'Stored properties / things that MUST STAY in AppModel.swift:',
    fmt(d.stay),
    '',
    'Expected promotions (private/fileprivate -> internal) — make ONLY those actually required by the build:',
    fmt(d.promote),
    '',
    'Domain notes: ' + d.notes,
    '',
    'Steps: (1) grep each method to find its current span and read it; (2) ' +
      (d.mode === 'create'
        ? 'create the target file from the template with the moved methods'
        : 'append each method into the existing extension block of its target file') +
      '; (3) delete each moved method from AppModel.swift, leaving every stored property in place; (4) apply only the promotions the build forces; (5) `swift build --package-path macos` until green; (6) return the structured result.',
  ].join('\n')
}

const BUILDER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    domain: { type: 'string' },
    targetFiles: { type: 'array', items: { type: 'string' } },
    funcsMoved: { type: 'array', items: { type: 'string' } },
    storedPropsLeftInRange: { type: 'array', items: { type: 'string' } },
    promotions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          member: { type: 'string' },
          from: { type: 'string' },
          to: { type: 'string' },
          reason: { type: 'string' },
        },
        required: ['member', 'from', 'to', 'reason'],
      },
    },
    buildOk: { type: 'boolean' },
    buildErrors: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['domain', 'targetFiles', 'funcsMoved', 'storedPropsLeftInRange', 'promotions', 'buildOk', 'buildErrors', 'notes'],
}

// ---- Phase 1: sequential extraction (hotspot-serialized) -----------------
phase('Extract')
const extractResults = []
for (const d of DOMAINS) {
  const r = await agent(builderPrompt(d), { label: 'extract:' + d.name, phase: 'Extract', schema: BUILDER_SCHEMA })
  extractResults.push(r)
  if (r && r.buildOk === false) {
    log('⚠️ ' + d.name + ' returned buildOk=false: ' + String(r.buildErrors || '').slice(0, 300))
  } else if (r) {
    log('✓ ' + d.name + ': moved ' + (r.funcsMoved || []).length + ' methods, ' + (r.promotions || []).length + ' promotions, build green')
  }
}

// ---- Phase 2: clean rebuild + full test suite ----------------------------
phase('Verify')
const verifyPrompt = [
  'You are the Verify gate for an AppModel god-object extraction on branch refactor/appmodel-finish-extraction (shared working tree, uncommitted edits present).',
  'Do exactly this, from the repo root, and report results. Do NOT edit any source, do NOT commit.',
  '1. `git add -A`  (stage everything so new files are visible to later git-diff review — staging only, NO commit).',
  '2. `rm -rf macos/.build && swift build --package-path macos 2>&1 | tail -50`  — this is the authoritative clean-build gate. Report whether it succeeded and any errors.',
  '3. `swift test --package-path macos 2>&1 | tail -40`  — report pass/fail and the test count (e.g. "NNN tests passed").',
  '4. `wc -l macos/Sources/Lyrebird/AppModel.swift`  and  `grep -c "^    func \\|^    private func \\|^    static func \\|^    private static func " macos/Sources/Lyrebird/AppModel.swift` — report the AppModel.swift line count and how many class-body funcs remain.',
  'Return the structured result. If the clean build fails, paste the exact compiler errors into buildErrors verbatim — they tell the foreground session what to fix.',
].join('\n')
const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    cleanBuildOk: { type: 'boolean' },
    buildErrors: { type: 'string' },
    testOk: { type: 'boolean' },
    testSummary: { type: 'string' },
    appModelLines: { type: 'integer' },
    remainingClassFuncs: { type: 'integer' },
  },
  required: ['cleanBuildOk', 'buildErrors', 'testOk', 'testSummary', 'appModelLines', 'remainingClassFuncs'],
}
const verify = await agent(verifyPrompt, { label: 'verify:clean-build+test', phase: 'Verify', schema: VERIFY_SCHEMA })

// ---- Phase 3: parallel calibrated adversarial review ---------------------
phase('Review')
const REVIEW_PREAMBLE = [
  'You are reviewing the STAGED diff of an AppModel.swift god-object extraction (branch refactor/appmodel-finish-extraction). The changes have been staged but not committed; inspect them with:',
  '  - `git diff --cached origin/main -- macos/Sources/Lyrebird/`   (all moves)',
  '  - `git diff --cached --stat origin/main`                        (file overview)',
  '  - `git show origin/main:macos/Sources/Lyrebird/AppModel.swift`  (the pre-extraction original, to compare method bodies)',
  '  - the new AppModel+*.swift files directly with Read.',
  '',
  'CALIBRATION (read carefully): the goal is pure relocation of methods out of a god-object. APPROVE the work unless you can cite a CONCRETE file:line defect under your lens. Your lens is a LENS, not a quota — "clean, no findings" is the expected and correct outcome for a faithful relocation. Do NOT manufacture a finding to avoid rubber-stamping, do NOT flag style/preference, do NOT propose "could add a test", do NOT flag hypotheticals. Only report a finding you could defend to a hostile senior engineer with the exact file:line and why it is wrong.',
  '',
].join('\n')
const LENSES = [
  {
    key: 'stored-prop-moved',
    desc: 'HARD violation check: did any STORED property (a `var`/`let` holding plain state with NO computed `{ }` body) get moved OUT of AppModel.swift into an extension file? Read every new/modified AppModel+*.swift and flag any stored var/let declaration that belongs to the @Observable surface and should have stayed. (Computed `var x: T { ... }` moving is FINE. Local `let`/`var` inside a method body is FINE.)',
  },
  {
    key: 'over-promotion',
    desc: 'Over-promotion check: in `git diff --cached origin/main -- macos/Sources/Lyrebird/AppModel.swift`, find every member whose access changed from private/fileprivate to internal (the `-    private ...` / `+    ...` pairs). For EACH, confirm a moved method in some AppModel+*.swift actually references it cross-file. Flag any promotion with NO cross-file caller (it should have stayed private). Expected-legitimate promotions: hasAttemptedRestore, autoplayWhenQueueEndsDefault.',
  },
  {
    key: 'non-verbatim',
    desc: 'Faithfulness check: pick each moved method and diff its body in the new extension file against the original in `git show origin/main:macos/Sources/Lyrebird/AppModel.swift`. Flag ANY change beyond pure relocation — altered logic, renamed locals, reordered statements, changed signature, changed error handling. Whitespace-only/indentation must be identical (4 spaces).',
  },
  {
    key: 'duplicates-orphans',
    desc: 'Duplicate/orphan check: use grep across macos/Sources/Lyrebird/AppModel*.swift for each moved function signature. Flag (a) any method defined in BOTH AppModel.swift and an extension (duplicate → would not compile, but verify), (b) any method that was supposed to move but is still present in AppModel.swift, (c) any obviously dangling reference. Also confirm no `<<<<<<<`/`>>>>>>>` conflict markers and no leftover empty MARK sections that now contain nothing.',
  },
  {
    key: 'imports-cohesion',
    desc: 'Hygiene check: does each new AppModel+*.swift import only what its code uses (flag a clearly-unused import, or a missing one that only compiles by luck)? Is each method in a sensibly-named file? Is there process/campaign prose in any doc comment ("Phase N", "extracted from", "pure relocation", "moved verbatim", issue-tracker chatter) that should be removed? Flag only concrete instances.',
  },
]
const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    lens: { type: 'string' },
    verdict: { type: 'string', enum: ['clean', 'issues'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          file: { type: 'string' },
          line: { type: 'string' },
          issue: { type: 'string' },
          suggestedFix: { type: 'string' },
        },
        required: ['severity', 'file', 'line', 'issue', 'suggestedFix'],
      },
    },
  },
  required: ['lens', 'verdict', 'findings'],
}
const reviews = await parallel(
  LENSES.map((L) => () =>
    agent(REVIEW_PREAMBLE + '\nYOUR LENS (' + L.key + '): ' + L.desc, {
      label: 'review:' + L.key,
      phase: 'Review',
      model: 'sonnet',
      schema: REVIEW_SCHEMA,
    }),
  ),
)

const confirmed = reviews
  .filter(Boolean)
  .flatMap((r) => (r.findings || []).map((f) => ({ ...f, lens: r.lens })))
  .filter((f) => f.severity === 'blocker' || f.severity === 'major')

log('Extraction complete. Clean build: ' + (verify ? verify.cleanBuildOk : '??') + ', tests: ' + (verify ? verify.testOk : '??') + ', AppModel.swift now ' + (verify ? verify.appModelLines : '??') + ' lines. Confirmed blocker/major findings: ' + confirmed.length)

return { extractResults, verify, reviews, confirmed }
