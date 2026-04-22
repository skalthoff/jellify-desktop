# macOS Distribution — Research & Issue Backlog

Scope: ship a signed, notarized, auto-updating macOS `.dmg` of Jellify Desktop
that launches without the Gatekeeper "unidentified developer" popup. Current
state: `macos/Scripts/make-bundle.sh` wraps a debug `swift build` executable in
a minimal `Info.plist`-only bundle. No certificate, no notarization, no update
path, no CI. Goal: turn this into a repeatable one-tag-and-ship release pipeline
with an EdDSA-signed Sparkle appcast hosted on GitHub Pages.

Conventions:
- Every `.app` surface (executable, embedded frameworks, the Sparkle helper
  bundle, the outer `.dmg`) is signed with the same **Developer ID Application**
  certificate, in **inside-out** order, with the hardened runtime.
- CI-side the flow is `cargo build (universal) → swift build (universal) →
  bundle → sign → create-dmg → notarize → staple → upload → generate_appcast`.
- All sensitive material (signing `.p12`, Apple ID, team ID, app-specific
  password, Sparkle private EdDSA key) lives in GitHub Actions secrets.
- We stay **outside the Mac App Store** because Jellify ships under GPL-3.0;
  GPL is incompatible with Apple's MAS distribution agreement. Hardened-runtime
  + Developer ID notarized is the right end state.

Ordering: P0 issues are the critical path for a first public 0.1.0 release.
P1 is polish / automation that should land in the first month of distribution.
P2 is nice-to-have and can wait.

---

### Issue 1: Enroll in the Apple Developer Program and request a Developer ID Application certificate
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p0`
**Effort:** S

Without a Developer ID Application certificate we cannot sign for distribution
outside the MAS, and without a signed build we cannot notarize. This is a
non-engineering blocker with a multi-day lead time that gates everything else.

Steps:
1. Enroll at <https://developer.apple.com/programs/> ($99/yr, individual is
   fine — organizational enrollment takes 1–4 weeks).
2. In the developer portal → Certificates, IDs & Profiles → Certificates,
   request a **Developer ID Application** certificate (used to sign the `.app`
   and `.dmg`). *Do not* request Developer ID Installer — we ship a DMG, not a
   `.pkg`.
3. On a secure Mac: generate a CSR with Keychain Access (*Keychain Access →
   Certificate Assistant → Request a Certificate from a Certificate
   Authority*). Upload it. Download the resulting `.cer`, double-click to
   import into the login keychain.
4. Export `.p12` from Keychain Access → My Certificates. Select both the
   cert **and** its private key (if the key is missing, export is greyed out).
   Set a long random password. Store the `.p12` and password in 1Password
   under `jellify-desktop / Apple Developer ID`.
5. Note the Team ID (portal → Membership). Save to the same 1Password entry.
6. Register an App-Specific Password at <https://appleid.apple.com>
   (Security → App-Specific Passwords → "jellify-notarytool"). Save it.

Out of this step we produce three durable secrets:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`,
`APPLE_TEAM_ID`, `APPLE_NOTARY_APP_PASSWORD`.

---

### Issue 2: Register the bundle ID and reserve `jellify://` URL scheme
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p0`
**Effort:** S

The current Info.plist already uses `org.jellify.desktop`. Register this exact
string as an App ID in the developer portal (*Identifiers → + → App IDs →
macOS App*) so we can later add capabilities (associated domains, iCloud,
Sparkle deltas) without a bundle-ID migration. A mismatch between the bundle
ID and the cert's recognized identifiers is a common notarization surprise.

While here, finalize the custom URL scheme the Rust core will receive auth
callbacks on. Recommended: `jellify://`. Declare it in `Info.plist` via
`CFBundleURLTypes` with `CFBundleURLName = org.jellify.desktop` and
`CFBundleURLSchemes = ["jellify"]`. No App Sandbox → no extra entitlements
needed for URL scheme handling.

---

### Issue 3: Switch the bundler to a real Info.plist driven from a template
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

The current heredoc Info.plist in `macos/Scripts/make-bundle.sh` is too
skeletal for a release. Replace with a checked-in template at
`macos/Resources/Info.plist` and have the script `plutil -replace` the
version fields from `$VERSION` / `$BUILD` env vars. Keys to add:

- `CFBundleIconFile` → `AppIcon` (produced by the icon pipeline, Issue 12)
- `CFBundleShortVersionString` → marketing version (semver, e.g. `0.1.0`)
- `CFBundleVersion` → monotonic build number (e.g. CI run number)
- `LSMinimumSystemVersion` → `14.0` (matches `Package.swift`'s
  `.macOS(.v14)`)
- `NSHumanReadableCopyright` → `© 2026 Jellify. GPL-3.0-only.`
- `LSApplicationCategoryType` → `public.app-category.music`
- `NSHighResolutionCapable` → `true` (already set)
- `NSPrincipalClass` → `NSApplication` (already set)
- `CFBundleURLTypes` → as per Issue 2
- `SUFeedURL` → `https://jellify-music.github.io/jellify-desktop/appcast.xml`
  (Sparkle, see Issue 14)
- `SUPublicEDKey` → Sparkle EdDSA public key (base64, see Issue 13)
- `LSUIElement` → **do not set** — Jellify is a dock-visible app.
- Do *not* add `NSMicrophoneUsageDescription` yet; only add usage-description
  strings once a code path actually triggers TCC, otherwise Apple's notary
  will reject for "unused purpose string" on newer tool versions.

Output: bundle script produces a bundle that `plutil -lint` passes and
`codesign --verify --strict` can round-trip.

---

### Issue 4: Add entitlements file with the minimal hardened-runtime surface
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** S

Notarization requires the hardened runtime (`codesign -o runtime`). The app
needs to keep working under it. Create `macos/Resources/Jellify.entitlements`
with only what we actually need:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Outbound network to arbitrary Jellyfin servers -->
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- Sparkle XPC services are signed ad-hoc with the Sparkle team's key, not ours -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

What we deliberately *omit*:
- `com.apple.security.app-sandbox` — we are **not** MAS; hardened runtime
  alone is what notarization requires, and sandboxing would force the UniFFI
  SQLite store into a container path and require `user-selected.read-write`
  for downloads. Keep the full filesystem, gate abuse via code review.
- `com.apple.security.device.audio-input` — AVPlayer playback is audio
  *output* only; TCC doesn't prompt.
- `allow-jit` / `allow-unsigned-executable-memory` — Rust core is AOT.
- `files.downloads.read-write` — download destinations are chosen via
  `NSSavePanel` which Powerbox grants automatically, no entitlement needed.

`disable-library-validation` is present because Sparkle's embedded XPC
helpers are signed with Sparkle's team ID, not ours; without this Gatekeeper
refuses to load them under the hardened runtime.

---

### Issue 5: Build a universal xcframework (arm64 + x86_64)
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

`macos/Scripts/build-core.sh` builds only `aarch64-apple-darwin`. For a public
DMG we need to ship Apple Silicon **and** Intel — the install base still has a
meaningful Intel long tail (pre-2020 Macs, which stopped receiving macOS
updates at Ventura). Ship one universal `.app` so there's a single DMG.

Changes to the script:

```sh
cargo build --release --target aarch64-apple-darwin -p jellify_core
cargo build --release --target x86_64-apple-darwin  -p jellify_core

mkdir -p target/universal-apple-darwin/release
lipo -create \
  target/aarch64-apple-darwin/release/libjellify_core.a \
  target/x86_64-apple-darwin/release/libjellify_core.a \
  -output target/universal-apple-darwin/release/libjellify_core.a

xcodebuild -create-xcframework \
  -library target/universal-apple-darwin/release/libjellify_core.a \
  -headers "$HEADERS" \
  -output macos/Jellify.xcframework
```

Then Swift:

```sh
swift build -c release --arch arm64 --arch x86_64
```

Gotchas:
- `rustup target add x86_64-apple-darwin` on every dev/CI machine.
- Release profile (`lto = true`, `codegen-units = 1`) already pinned in root
  `Cargo.toml` — keep it.
- `reqwest = { default-features = false, features = ["rustls-tls"] }` avoids
  the native `Security.framework` link pain on Intel, already set.
- LTO + static lib can hit the "LC_BUILD_VERSION missing" notary rejection if
  an old Xcode SDK is used. Always build on Xcode 15+ (see Issue 23).

---

### Issue 6: Standalone signing script — `macos/Scripts/sign.sh`
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

Signing must be scripted and deterministic; `xcodebuild`-driven signing is
awkward in an SPM-only project. Write `sign.sh` that takes `Jellify.app` and
signs inside-out with the hardened runtime:

```sh
#!/usr/bin/env bash
set -euo pipefail
APP="$1"
IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application}"
ENTITLEMENTS="$(dirname "$0")/../Resources/Jellify.entitlements"

# 1. Sign everything nested inside Frameworks/ first (Sparkle, any dylibs).
find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0 2>/dev/null | \
  while IFS= read -r -d '' fw; do
    codesign --force --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS" \
      --sign "$IDENTITY" "$fw"
  done

# 2. XPC services inside Sparkle (Installer, Downloader).
find "$APP/Contents/Frameworks" -type d -name "*.xpc" -print0 2>/dev/null | \
  while IFS= read -r -d '' xpc; do
    codesign --force --timestamp --options runtime \
      --sign "$IDENTITY" "$xpc"
  done

# 3. The main executable last.
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

# 4. Verify.
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
```

Notes:
- **Never pass `--deep`.** It's deprecated, papers over real signing bugs,
  and correlates with notary rejections. Use explicit bottom-up order.
- `--timestamp` (Apple's timestamp server) is mandatory for notarization.
- `--options runtime` enables the hardened runtime.
- Entitlements file is reapplied to every bundle-level binary; inner
  dylibs/XPC don't carry entitlements.

---

### Issue 7: Notarization script using `notarytool` + keychain profile
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

Legacy `altool` has been deprecated since Nov 2023; use `xcrun notarytool`
exclusively. Add `macos/Scripts/notarize.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail
DMG="$1"
PROFILE="${NOTARY_PROFILE:-jellify-notary}"

xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json \
  > notarize.log

STATUS=$(jq -r .status notarize.log)
if [[ "$STATUS" != "Accepted" ]]; then
  SUB_ID=$(jq -r .id notarize.log)
  xcrun notarytool log "$SUB_ID" --keychain-profile "$PROFILE"
  exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
```

One-time local bootstrap (developer runs this once; CI uses env-var
variant — see Issue 17):

```sh
xcrun notarytool store-credentials jellify-notary \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_NOTARY_APP_PASSWORD"
```

Stapling is essential: without it, first-launch requires a network roundtrip
to Apple to verify the ticket. Stapled DMGs work fully offline.

---

### Issue 8: DMG creation via `create-dmg`
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

`hdiutil` raw works but requires hand-rolling the background image, window
geometry, and Applications symlink. Use `create-dmg`
(<https://github.com/create-dmg/create-dmg>, `brew install create-dmg`) which
wraps all of that:

```sh
create-dmg \
  --volname "Jellify" \
  --volicon "macos/Resources/AppIcon.icns" \
  --background "macos/Resources/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 96 \
  --icon "Jellify.app" 180 170 \
  --hide-extension "Jellify.app" \
  --app-drop-link 480 170 \
  --codesign "$DEVELOPER_ID_IDENTITY" \
  --notarize "jellify-notary" \
  "Jellify-${VERSION}.dmg" \
  "build/dist/"
```

Notes:
- `--codesign` + `--notarize` let `create-dmg` drive the full inside-out
  flow itself. Alternatively we drive signing/notarization externally (Issues
  6/7) and pass only `--codesign` — pick one to avoid double-signing.
- Produce a separate `dmg-background.png` at `1320×800` (2× of window size)
  for Retina. Keep source at `design/dmg-background.svg`.
- Output file name: `Jellify-0.1.0.dmg` — matches the Sparkle appcast
  enclosure URL convention.

---

### Issue 9: App icon pipeline — SVG → `.iconset` → `.icns`
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** S

Ship a proper `.icns` — the current bundle has none. Source of truth: a
single 1024×1024 SVG at `design/icons/jellify-app.svg` (design already lives
under `design/`). Add `macos/Scripts/make-iconset.sh`:

```sh
SRC="design/icons/jellify-app.svg"
OUT="macos/Resources/AppIcon.iconset"
mkdir -p "$OUT"
for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $size -h $size "$SRC" -o "$OUT/icon_${size}x${size}.png"
  rsvg-convert -w $((size*2)) -h $((size*2)) "$SRC" -o "$OUT/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$OUT" -o macos/Resources/AppIcon.icns
```

- `brew install librsvg` for `rsvg-convert` on CI.
- Apple's canonical sizes are 16, 32, 128, 256, 512 with `@2x` variants —
  extra sizes are harmless. `iconutil` rejects incomplete sets, so keep the
  for-loop exhaustive.
- Commit `AppIcon.icns` artifact or regenerate in CI; regenerating is
  cleaner because the SVG is the canonical source.

---

### Issue 10: Integrate Sparkle 2 as a Swift Package dependency
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

Sparkle 2 supports SPM and is MIT-licensed (GPL-compatible). In
`macos/Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
],
// …
.executableTarget(
    name: "Jellify",
    dependencies: [
        "JellifyCore", "JellifyAudio",
        .product(name: "Sparkle", package: "Sparkle"),
    ],
    …
)
```

Add an `Updater.swift` in `Sources/Jellify/`:

```swift
import Sparkle
import SwiftUI

final class UpdaterController: NSObject, ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheck = false
    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheck)
    }
    func check() { controller.checkForUpdates(nil) }
}
```

Wire a "Check for Updates…" menu item in the app's `CommandMenu`, bound to
`updater.canCheck`. Since we are **not** sandboxed, Sparkle's XPC
helpers are optional — we can strip them to reduce bundle size (see
`SPARKLE_DISABLE_XPC` in Sparkle docs) but leaving them in is safer and still
notarizes fine under `disable-library-validation`.

References:
- <https://sparkle-project.org/documentation/>
- <https://sparkle-project.org/documentation/sandboxing/>

---

### Issue 11: Generate EdDSA signing keypair for Sparkle and store it
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p0`
**Effort:** S

Sparkle 2 mandates EdDSA (ed25519) signatures on every update — unsigned
updates are rejected by the client. Run once:

```sh
./Sparkle/bin/generate_keys
# Prints a base64 public key to stdout; private key lands in login keychain
# under service "https://sparkle-project.org" account "ed25519".
```

Actions:
1. Copy the printed public key into `Info.plist` as `SUPublicEDKey`.
2. Export the private key from Keychain Access → "https://sparkle-project.org"
   → "Copy Password to Clipboard" (it's a 64-byte base64 string).
3. Store private key in 1Password **and** as GitHub Actions secret
   `SPARKLE_ED_PRIVATE_KEY`.
4. Private key rotation breaks the update chain for installed users — they'd
   need to reinstall. Treat it like a TLS root: never rotate without a very
   good reason.

---

### Issue 12: `appcast.xml` generation and GitHub Pages hosting
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

Sparkle clients poll `SUFeedURL` for a RSS feed describing available
updates. Host on GitHub Pages — free, global CDN, HTTPS, static.

Setup:
1. Enable Pages on `jellify-desktop` repo → Source: `gh-pages` branch, or a
   sibling repo `jellify-desktop-updates` (preferred: keeps the main repo
   git history clean).
2. The `generate_appcast` tool (ships with Sparkle) reads a directory of
   DMGs + their release notes and emits an appcast XML:
   ```sh
   generate_appcast ./updates \
     --ed-key-file sparkle_ed_private.key \
     --download-url-prefix "https://github.com/Jellify-Music/jellify-desktop/releases/download/" \
     --full-release-notes-url "https://github.com/Jellify-Music/jellify-desktop/releases"
   ```
3. Release notes per version go at `./updates/Jellify-0.1.0.html` (Sparkle
   renders this inline in the updater prompt — keep it short and in plain
   HTML, no inline scripts).
4. CI publishes the freshly-generated `appcast.xml` + `.html` files to the
   Pages branch (Issue 17 covers the workflow).

Feed shape Sparkle expects:

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Jellify Updates</title>
    <item>
      <title>Version 0.1.0</title>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/…/Jellify-0.1.0.dmg"
                 sparkle:edSignature="…" length="…"
                 type="application/octet-stream"/>
      <sparkle:releaseNotesLink>…/release-notes/0.1.0.html</sparkle:releaseNotesLink>
    </item>
  </channel>
</rss>
```

---

### Issue 13: Delta updates for Sparkle (size optimization)
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p2`
**Effort:** M

Sparkle supports binary delta updates (BSDiff over archive contents). A
Jellify `.dmg` is ~30–60 MB once Rust + Sparkle + fonts are bundled; deltas
typically shrink to <5 MB. `generate_appcast` will produce both full and
delta enclosures automatically if an adjacent older DMG is present in the
updates dir. Defer until 2–3 versions are out, then:

1. Keep the last N=4 DMGs in `./updates/`.
2. Re-run `generate_appcast` after each release.

No client changes needed — Sparkle picks the smallest path automatically.

---

### Issue 14: GitHub Release automation with `gh release create`
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** M

Distribution vehicle: attach the signed + notarized DMG to a GitHub Release
on the main repo. Git tag drives the version. In CI (Issue 17), on a
`v*` tag push:

```sh
gh release create "v${VERSION}" \
  --title "Jellify ${VERSION}" \
  --notes-file "release-notes/${VERSION}.md" \
  "dist/Jellify-${VERSION}.dmg#Jellify ${VERSION} (macOS universal)"
```

Versioning: strict semver (`v0.1.0`, `v0.1.1`, `v1.0.0-beta.1`).
Pre-releases get `--prerelease` flag so stable users don't auto-update onto
them (Sparkle appcast channels handled separately, Issue 21).

---

### Issue 15: GitHub Actions release workflow on tag push
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p0`
**Effort:** L

End-to-end workflow at `.github/workflows/macos-release.yml`. Runs on
`macos-14` (Apple Silicon runner) — now the default and cheapest macOS tier.

Pipeline phases:

```yaml
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-14
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 15.4+
        run: sudo xcode-select -s /Applications/Xcode_15.4.app

      - name: Install Rust targets
        run: |
          rustup target add aarch64-apple-darwin x86_64-apple-darwin

      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: ". -> target"

      - name: Import signing certificate
        uses: apple-actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.DEVELOPER_ID_P12_BASE64 }}
          p12-password: ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}

      - name: Store notary credentials
        run: |
          xcrun notarytool store-credentials jellify-notary \
            --apple-id "${{ secrets.APPLE_ID }}" \
            --team-id "${{ secrets.APPLE_TEAM_ID }}" \
            --password "${{ secrets.APPLE_NOTARY_APP_PASSWORD }}"

      - name: Build Rust core (universal)
        run: macos/Scripts/build-core.sh --release --universal

      - name: Build Swift app (universal)
        working-directory: macos
        run: swift build -c release --arch arm64 --arch x86_64

      - name: Bundle .app
        run: macos/Scripts/make-bundle.sh --release

      - name: Sign .app
        env:
          DEVELOPER_ID_IDENTITY: ${{ secrets.DEVELOPER_ID_IDENTITY }}
        run: macos/Scripts/sign.sh macos/build/Jellify.app

      - name: Build DMG
        run: macos/Scripts/make-dmg.sh

      - name: Notarize DMG
        run: macos/Scripts/notarize.sh "dist/Jellify-${VERSION}.dmg"

      - name: Generate appcast
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: macos/Scripts/update-appcast.sh

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh release create "$GITHUB_REF_NAME" dist/*.dmg \
               --title "Jellify ${VERSION}" \
               --notes-file "release-notes/${VERSION}.md"

      - name: Publish appcast to Pages
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_branch: gh-pages
          publish_dir: ./appcast-site
```

Notes:
- Keep timeout generous — universal Rust build on a busy runner is ~12 min.
- Cache `target/` between runs with `Swatinem/rust-cache`; Swift caches are
  less useful because SPM re-resolves dependencies cheaply.
- `apple-actions/import-codesign-certs@v3` creates an ephemeral keychain
  that's torn down at job end — no leakage across tenants.
- The `.p12` must be re-exported with modern encryption (OpenSSL 3.x on the
  runners rejects RC2-encrypted legacy `.p12`s): `openssl pkcs12 -legacy
  -in old.p12 -nodes -out pem && openssl pkcs12 -export -in pem -out new.p12`.

---

### Issue 16: GitHub Actions secrets inventory + rotation runbook
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p0`
**Effort:** S

Document the exact list and rotation story in `macos/DISTRIBUTION.md` (or a
new doc file), so future maintainers aren't blocked by a silent key expiry.

| Secret                         | Source                 | Expires |
|--------------------------------|------------------------|---------|
| `DEVELOPER_ID_P12_BASE64`      | Apple Dev portal cert  | 5 years |
| `DEVELOPER_ID_P12_PASSWORD`    | chosen at export time  | –       |
| `DEVELOPER_ID_IDENTITY`        | "Developer ID Application: Name (TEAMID)" | — |
| `APPLE_ID`                     | Apple ID email         | –       |
| `APPLE_TEAM_ID`                | Dev portal → Membership| –       |
| `APPLE_NOTARY_APP_PASSWORD`    | appleid.apple.com ASP  | never¹  |
| `SPARKLE_ED_PRIVATE_KEY`       | `generate_keys` once   | never²  |

¹ App-specific passwords don't expire but are revoked if the main Apple ID
password changes. Rotation: regenerate → update secret → re-run last
release workflow to verify. ² EdDSA key rotation breaks updates for
installed clients; do not rotate without a migration plan.

Cert-rotation playbook (before 5-year expiry):
1. Request new Developer ID Application cert 60 days before expiry.
2. Export to `.p12`, base64, update `DEVELOPER_ID_P12_BASE64` secret.
3. Update `DEVELOPER_ID_IDENTITY` secret if the Common Name changed.
4. Cut a no-op point release to confirm the pipeline still ships.
5. Old cert stays valid for installed apps — notarization tickets don't
   re-verify the cert at launch, only the chain to Apple's root.

---

### Issue 17: Reproducible toolchain pinning
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p1`
**Effort:** S

CI drift is the #1 reason a previously-working release pipeline breaks.
Pin:

- Rust: `rust-toolchain.toml` at repo root:
  ```toml
  [toolchain]
  channel = "1.83.0"
  targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]
  components = ["rustfmt", "clippy"]
  ```
- Swift: enforced by the runner's selected Xcode. Pin in CI with
  `sudo xcode-select -s /Applications/Xcode_15.4.app` — `macos-14` ships
  multiple Xcodes side by side. Match the version locally via
  `.envrc` / README note.
- `Cargo.lock` is already committed (confirmed: 72 KB file at repo root).
  Good — keep it committed for reproducibility even though `core/` is a
  library crate.
- Sparkle version pinned in `Package.resolved` (commit this file; by
  default SPM gitignores it for library packages but we're an app).

---

### Issue 18: Rust release-profile flags + hardened-runtime compatibility
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p1`
**Effort:** S

Confirm nothing Rust emits trips the hardened runtime. The static lib itself
doesn't carry entitlements or a signature — only the final executable does —
but two flags to double-check:

- `strip = true` (already set in `[profile.release]`): strips debug symbols.
  Keep. Not harmful to notarization; the notary doesn't require dSYMs to
  live in the bundle.
- `lto = true` + `codegen-units = 1`: fine for hardened runtime. These only
  shuffle object code; no runtime codegen is introduced.
- Avoid `-C link-arg=-sectcreate`, `-Wl,-bundle_loader`, or any post-link
  step that rewrites `LC_*` load commands without a re-sign. UniFFI
  generates none of this.
- Add to CI: `codesign --test-requirement="=designated => anchor apple
  generic and certificate leaf[field.1.2.840.113635.100.6.1.13]"
  Jellify.app` — this is the exact predicate Gatekeeper uses for Developer
  ID and catches certificate-chain breakage before shipping.

---

### Issue 19: LetsMove "move to Applications" prompt
**Labels:** `area:macos`, `area:ux`, `kind:feat`, `priority:p2`
**Effort:** S

A DMG that users drag-drop to `/Applications` is the happy path; users who
double-click from `~/Downloads` hit auto-update issues (Sparkle cannot
replace the app while it's running from a read-only mounted image). Use
[LetsMove](https://github.com/potionfactory/LetsMove) on first launch:

- BSD-licensed, GPL-compatible.
- SPM-incompatible but vendoring as source (1 `.m` file + header) is
  acceptable. Call `PFMoveToApplicationsFolderIfNecessary()` from
  `applicationDidFinishLaunching`.
- Skip if the user declined once; Sparkle persists this in UserDefaults.

---

### Issue 20: Crash reporting via Sentry (opt-in) or skip for v1
**Labels:** `area:macos`, `area:observability`, `kind:feat`, `priority:p1`
**Effort:** M

Sentry's `sentry-cocoa` SPM package is the polished 2026 option: one-line
init, symbolication via Sentry dSYM upload, covers Swift + ObjC + signals.
Alternative is PLCrashReporter (just the crash capture, you manage upload)
or plain `os_log` + Console.app (no remote telemetry).

Recommendation: Sentry, *strictly opt-in*, matches Jellify's
privacy-first stance.

Integration sketch:

```swift
import Sentry
if Settings.shared.crashReportsEnabled {
    SentrySDK.start { options in
        options.dsn = "https://…@sentry.io/…"
        options.releaseName = "jellify@\(Bundle.main.shortVersion)"
        options.enableAppHangTracking = true
        options.enableUncaughtNSExceptionReporting = true  // macOS-only flag
        options.beforeSend = { event in
            // Scrub server URL, username, path, track titles
            event.user = nil
            event.contexts?.removeValue(forKey: "device")
            return event
        }
    }
}
```

Upload dSYMs to Sentry from CI via `sentry-cli upload-dif` — only needed if
we enable Sentry. Without it, macOS system crash reports still land in
`~/Library/Logs/DiagnosticReports/` for users to attach manually.

Default: opt-in off. Surface toggle in Settings → Privacy. Never enable by
default; never beacon on install.

---

### Issue 21: Telemetry — opt-in usage metrics
**Labels:** `area:macos`, `area:observability`, `kind:feat`, `priority:p2`
**Effort:** M

If we measure anything at all beyond crashes, use **TelemetryDeck**
(Apple-focused, anonymous-by-design, GDPR-clean, EU-hosted) over PostHog.
Metrics *allowed*:

- App launch
- Session length (bucketed)
- macOS version
- Play started (no track, no album, no artist, no server)
- Skip / pause counts per session

Metrics *forbidden*:

- Any Jellyfin server URL or IP
- Any content identifier (track/album/artist IDs, titles)
- User account name or any credential surface
- Queue contents, library size

Keep the implementation behind `Settings.telemetryEnabled` (default off).
Ship a single JSON-schema dashboard-independent beacon so we can swap
backends without a client update.

---

### Issue 22: First-launch Gatekeeper UX write-up
**Labels:** `area:macos`, `area:docs`, `kind:chore`, `priority:p1`
**Effort:** S

Even on a notarized build, first launch after download shows the "Jellify is
an app downloaded from the Internet. Are you sure you want to open it?"
dialog — this is normal and is *not* the unidentified-developer popup. Add
a short `macos/DISTRIBUTION.md` ("First launch") section so support channels
can link users to it:

- Expected quarantine prompt on first run → click Open.
- No Gatekeeper popup = success. If users see "Jellify cannot be opened
  because the developer cannot be verified", the cert/notarization chain is
  broken — treat as release-blocker.
- `xattr -d com.apple.quarantine Jellify.app` is a user-level workaround
  only, never advertise it.

---

### Issue 23: Uninstall and data locations
**Labels:** `area:macos`, `area:docs`, `kind:feat`, `priority:p2`
**Effort:** S

macOS has no uninstall standard; dragging `Jellify.app` to Trash leaves:

- `~/Library/Application Support/jellify-desktop/` — UniFFI SQLite store
  (seen in `CoreConfig.dataDir`).
- `~/Library/Preferences/org.jellify.desktop.plist` — `UserDefaults`.
- `~/Library/Caches/org.jellify.desktop/` — URLCache, image cache.
- Keychain entries under service `org.jellify.desktop` (access token,
  refresh token — `keyring` crate).

Options:
1. Document in `macos/DISTRIBUTION.md` + README with a copy-paste `rm -rf`
   block. Lowest effort.
2. Ship a "Reset Jellify…" menu item that drops all of the above after a
   confirmation dialog. Cleaner UX, modest effort.

Recommended: do (1) for v0.1.0, file (2) as a follow-up feature.

---

### Issue 24: Sparkle beta channel + user opt-in
**Labels:** `area:macos`, `area:dist`, `kind:feat`, `priority:p2`
**Effort:** M

Expose a "Receive beta updates" checkbox in Settings. Backed by a separate
appcast at `appcast-beta.xml` or by using Sparkle's
`SUAllowedChannels`/`SUAllowedSystemProfileKeys` + per-item
`sparkle:channel` tag in the same feed. Single-feed-with-channels is
simpler to host (one appcast, one URL) and matches Sparkle's recommended
pattern:

```xml
<item>
  <sparkle:channel>beta</sparkle:channel>
  <sparkle:shortVersionString>0.2.0-beta.1</sparkle:shortVersionString>
  …
</item>
```

Swift side:

```swift
class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Settings.shared.betaOptIn ? ["beta"] : []
    }
}
```

Stable users never see beta items. Beta users see both stable and beta and
get whichever is newer.

---

### Issue 25: Homebrew Cask submission (deferred to post-1.0)
**Labels:** `area:macos`, `area:dist`, `kind:chore`, `priority:p2`
**Effort:** S

Once the Sparkle-driven DMG pipeline is stable for ~2 releases, submit to
[homebrew-cask](https://github.com/Homebrew/homebrew-cask). A minimal
`jellify.rb` cask:

```ruby
cask "jellify" do
  version "0.3.0"
  sha256 "…sha256 of Jellify-0.3.0.dmg…"

  url "https://github.com/Jellify-Music/jellify-desktop/releases/download/v#{version}/Jellify-#{version}.dmg"
  name "Jellify"
  desc "Native desktop client for Jellyfin"
  homepage "https://github.com/Jellify-Music/jellify-desktop"

  depends_on macos: ">= :sonoma"

  app "Jellify.app"

  zap trash: [
    "~/Library/Application Support/jellify-desktop",
    "~/Library/Preferences/org.jellify.desktop.plist",
    "~/Library/Caches/org.jellify.desktop",
  ]
end
```

Requirements:
- Must be notarized (✓).
- Must work on latest macOS (✓, we target macOS 14+).
- Must have reached a stable, non-preview milestone — Cask reviewers often
  push back on `0.0.x` submissions.
- Let Sparkle handle updates; the Cask `livecheck` block auto-syncs version
  from GitHub Releases so `brew upgrade` works too.

We do **not** need to pursue MAS. Per
<https://developer.apple.com/app-store/review/guidelines/> and FSF
guidance, GPL-3's anti-TPM clause conflicts with MAS's DRM. Stay
Developer-ID-only; file a note in `macos/DISTRIBUTION.md` so nobody tries.

---

## Runbook — Ship a release

A step-by-step checklist. The happy path is "tag, go have coffee" — the
items here are either human review steps or break-glass actions.

1. **Pre-flight**
   - [ ] `cargo test --workspace` green on `main`.
   - [ ] `swift build && swift test` green locally on `macos-14`.
   - [ ] Write `release-notes/X.Y.Z.md` + corresponding `.html` for Sparkle.
   - [ ] Bump version in `Cargo.toml` (`workspace.package.version`) and
         `macos/Resources/Info.plist` (`CFBundleShortVersionString`). Build
         number (`CFBundleVersion`) is CI's `$GITHUB_RUN_NUMBER`.
   - [ ] Open a PR "Release vX.Y.Z", squash-merge.
2. **Tag**
   - [ ] `git tag vX.Y.Z && git push origin vX.Y.Z`
3. **CI runs `macos-release.yml`**, which:
   1. Checks out, selects Xcode, restores Rust cache.
   2. Imports signing cert into ephemeral keychain.
   3. Stores notary creds.
   4. `build-core.sh --release --universal` → universal xcframework.
   5. `swift build -c release --arch arm64 --arch x86_64`.
   6. `make-bundle.sh --release` → `Jellify.app`.
   7. `sign.sh` → inside-out hardened-runtime signing.
   8. `make-dmg.sh` → signed DMG.
   9. `notarize.sh` → notarytool submit + staple.
   10. `update-appcast.sh` → regenerate `appcast.xml` + push to Pages.
   11. `gh release create vX.Y.Z` with the DMG attached.
4. **Smoke test** (human)
   - [ ] Download the DMG from Releases in Safari (triggers quarantine).
   - [ ] Mount, drag to `/Applications`, launch.
   - [ ] Expect: normal "downloaded from internet" prompt → Open →
         app starts. No Gatekeeper popup.
   - [ ] In-app → Jellify menu → Check for Updates…, confirm it reports
         "up to date".
5. **Post-flight**
   - [ ] Announce on GitHub Discussions / project channel.
   - [ ] If cask exists: bump version (via `brew bump-cask-pr jellify
         --version X.Y.Z` — fully automated).
6. **Break-glass: rollback**
   - Notarization typically doesn't need revocation for bad builds; just
     ship `X.Y.Z+1` with the fix. Sparkle will deliver it on next check.
   - If a release contains a security issue: mark the GitHub Release as a
     "pre-release" to hide it from the default list, remove it from
     `appcast.xml` (delete the `<item>`, push Pages), and ship a fix.
   - Only as a last resort: revoke the Developer ID Application
     certificate via Apple Dev portal. This breaks all installed copies of
     the offending build. Requires a full re-issuance of all future
     releases under a new cert — treat as nuclear.
7. **Yearly**
   - [ ] Apple Developer Program renewal ($99/yr, auto-renews).
   - [ ] Confirm `APPLE_NOTARY_APP_PASSWORD` still works (no rotation on
         appleid.apple.com recently? if yes, regen + update secret).
   - [ ] Confirm Sparkle EdDSA public key in Info.plist unchanged and
         private key backup still accessible.
8. **Every 5 years**
   - [ ] Developer ID Application cert renewal — see Issue 16.
