# Jellify macOS Distribution

End-to-end pipeline for producing a signed, notarized, stapled `Jellify-<version>.dmg`
that passes Gatekeeper and launches cleanly on a fresh Mac.

---

## **MANUAL PREREQUISITE — Apple Developer Program enrollment (issue #175)**

**This step is a multi-day, non-engineering task. The engineering pipeline
below cannot be exercised end-to-end until it is done. Start it first.**

1. Enroll at <https://developer.apple.com/programs/>. Individual
   enrollment is $99/year; organizational enrollment can take 1–4 weeks.
2. In the developer portal (**Certificates, IDs & Profiles →
   Certificates**) request a **Developer ID Application** certificate.
   - This is the cert used to sign `.app` bundles and `.dmg` files for
     distribution *outside* the Mac App Store.
   - **Do not** request **Developer ID Installer** — we ship a DMG, not
     a `.pkg`.
   - **Do not** request **Apple Distribution** / **Mac App Distribution**
     — those are MAS-only.
3. On a secure Mac, generate a CSR via **Keychain Access → Certificate
   Assistant → Request a Certificate from a Certificate Authority**.
   Upload the `.certSigningRequest`, download the resulting `.cer`,
   double-click it to import into your login keychain.
4. Export the resulting identity as a `.p12` from **Keychain Access → My
   Certificates**. Select both the certificate *and* its private key
   (if the key is missing from the selection, the Export menu item is
   greyed out). Set a long random password. Store the `.p12` + password
   in 1Password under `jellify-desktop / Apple Developer ID`.
5. From the portal's **Membership** page, record the **Team ID**. Save
   it in the same 1Password entry.
6. (Related to issue #176) In **Identifiers → + → App IDs → macOS App**,
   register the bundle identifier `org.jellify.desktop` exactly. A
   mismatch between the cert's recognized identifiers and the bundle ID
   is a common notarization surprise.

Once the certificate is in your login keychain the engineering pipeline
below will just work.

---

## Environment variables

All scripts read their secrets from the environment. Nothing touches
disk outside of the keychain-stored credentials and local build outputs.

| Variable        | Used by                            | Example                                                      |
| --------------- | ---------------------------------- | ------------------------------------------------------------ |
| `VERSION`       | `make-bundle.sh`, `make-dmg.sh`    | `0.1.0` (semver, matches a git tag)                          |
| `BUILD`         | `make-bundle.sh`                   | `1234` (monotonic build number, typically CI run number)     |
| `DEVELOPER_ID`  | `sign.sh`, `make-dmg.sh`           | `Developer ID Application: Jane Doe (TEAMID123)`             |
| `NOTARY_PROFILE`| `notarize.sh`                      | `jellify-notary` (keychain profile name)                     |

If `VERSION` / `BUILD` are unset, the scripts fall back to
`git describe --tags --abbrev=0` and `git rev-list --count HEAD` so local
dev builds still produce a sensibly-named bundle.

### One-time notary profile bootstrap

Store notary credentials in the keychain so the scripts never see raw
secrets:

```sh
xcrun notarytool store-credentials jellify-notary \
    --apple-id       "$APPLE_ID" \
    --team-id        "$APPLE_TEAM_ID" \
    --password       "$APPLE_NOTARY_APP_PASSWORD"
```

- `APPLE_ID` — the Apple ID associated with your developer account.
- `APPLE_TEAM_ID` — the 10-character team ID from the portal.
- `APPLE_NOTARY_APP_PASSWORD` — an **app-specific password** created at
  <https://appleid.apple.com> → Sign-In and Security → App-Specific
  Passwords. (Your real Apple ID password will not work.)

This only needs to run once per machine. The profile is stored in the
login keychain under the name `jellify-notary`.

### Tooling install

```sh
brew install create-dmg jq shellcheck
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

`shellcheck` is dev-only. `jq` is required by `notarize.sh`. Xcode
command line tools must be present (`xcode-select --install`).

---

## Files

| Path                                         | Purpose                                                        |
| -------------------------------------------- | -------------------------------------------------------------- |
| `macos/Resources/Info.plist`                 | Info.plist template with `$VERSION`/`$BUILD` placeholders      |
| `macos/Resources/Jellify.entitlements`       | Hardened-runtime entitlements applied at signing time          |
| `macos/Scripts/build-core.sh`                | Builds the Rust core as a universal `arm64 + x86_64` xcframework|
| `macos/Scripts/make-bundle.sh`               | Assembles `Jellify.app` and injects Info.plist version fields  |
| `macos/Scripts/sign.sh`                      | Codesigns the bundle inside-out with the hardened runtime      |
| `macos/Scripts/make-dmg.sh`                  | Produces `Jellify-<version>.dmg` via `create-dmg`              |
| `macos/Scripts/notarize.sh`                  | Submits to Apple's notary, waits, staples the ticket           |

---

## The release flow — run locally

Each script is idempotent and cleans up after itself on failure, so a
partial run can be retried from any step.

```sh
# 1. Build the Rust core as a universal xcframework.
./macos/Scripts/build-core.sh --release

# 2. Compile Swift for both architectures.
cd macos
swift build -c release --arch arm64 --arch x86_64
cd ..

# 3. Assemble Jellify.app. Picks up $VERSION / $BUILD (or git fallback).
VERSION=0.1.0 BUILD=1 ./macos/Scripts/make-bundle.sh --release --universal

# 4. Code-sign inside-out with the hardened runtime.
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID123)" \
    ./macos/Scripts/sign.sh macos/build/Jellify.app

# 5. Produce the DMG (signed with the same identity).
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID123)" \
    VERSION=0.1.0 \
    ./macos/Scripts/make-dmg.sh

# 6. Submit for notarization and staple the ticket on success.
./macos/Scripts/notarize.sh macos/build/Jellify-0.1.0.dmg
```

After step 6, the DMG is shippable. `spctl --assess --type open
--context context:primary-signature -v macos/build/Jellify-0.1.0.dmg`
should report `accepted`.

---

## Bundle layout (after step 4)

```
Jellify.app/
├── Contents/
│   ├── Info.plist           (rendered from Resources/Info.plist)
│   ├── MacOS/
│   │   └── Jellify          (universal Mach-O, signed + hardened runtime)
│   ├── Resources/
│   │   ├── AppIcon.icns     (optional — soft-dependency on icon pipeline)
│   │   └── Jellify_Jellify.bundle/   (SPM-processed fonts bundle)
│   └── _CodeSignature/
```

No `Frameworks/` directory yet. Sparkle ships in BATCH-19 (see
ROADMAP) and will live at `Contents/Frameworks/Sparkle.framework`.
`sign.sh` already handles it correctly when present.

---

## What each script does in detail

### `build-core.sh`

Builds `libjellify_core.a` for both `aarch64-apple-darwin` and
`x86_64-apple-darwin` (in release mode; LTO is pinned in `Cargo.toml`),
then fuses them into a single fat archive with `lipo`. The UniFFI
Swift binding is regenerated from the arm64 `.dylib` and both the
headers and the fat static lib go into `macos/Jellify.xcframework`,
which the SPM `binaryTarget` consumes.

Pass `--arm64-only` during development to skip the x86_64 leg.

### `make-bundle.sh`

Assembles `macos/build/Jellify.app` from the `swift build` output.
Copies `macos/Resources/Info.plist` into `Contents/Info.plist`, then
uses `plutil -replace` to inject `$VERSION` and `$BUILD`. Runs
`plutil -lint` on the result — a drift in the template that breaks
Core Foundation parsing fails the script loudly.

### `sign.sh`

Signs inside-out in a deterministic order: frameworks → XPC services
→ loose dylibs → auxiliary helpers → main bundle. Every sign call
uses `--options runtime --timestamp`. Entitlements are applied to
bundle-level binaries (frameworks, the app itself); inner helpers
inherit from the enclosing app.

**Never passes `--deep`.** `--deep` is deprecated, papers over real
signing bugs, and is correlated with notary rejections.

Verifies with `codesign --verify --strict` and previews the Gatekeeper
verdict with `spctl`. The Gatekeeper preview will report "rejected,
source=Unnotarized Developer ID" until `notarize.sh` runs — that's
expected.

### `make-dmg.sh`

Wraps `create-dmg`. Stages the `.app` in a scratch directory so
create-dmg doesn't sweep in any sibling junk in `build/`. Signs the
DMG with `--codesign`. **Does not** pass `--notarize` — notarization
happens via the dedicated `notarize.sh` so a rejected submission is
retriable without rebuilding the DMG.

### `notarize.sh`

`xcrun notarytool submit --wait --output-format json`, parses the
verdict with `jq`, and either staples (success) or dumps the
detail log (failure). Preserves logs in a temp dir on failure for
post-mortem; cleans up on success.

---

## Troubleshooting

### `security find-identity` shows no `Developer ID Application`

The certificate isn't installed in the active keychain. Double-click the
`.cer` or import the `.p12` into **login.keychain**. Run
`security list-keychains` to check which keychain is searched by default.

### `codesign` says "no identity found"

The name passed in `$DEVELOPER_ID` must exactly match the common name of
a cert in the keychain. Copy-paste from:

```sh
security find-identity -v -p codesigning
```

### `notarytool` rejects with "The signature of the binary is invalid"

Almost always one of:
1. You built on an old Xcode SDK (pre-15). The notary requires
   `LC_BUILD_VERSION` loads on every Mach-O — older SDKs emit
   `LC_VERSION_MIN_MACOSX` instead. Xcode 15+ fixes this.
2. Something inside `Contents/Frameworks/` was signed *after* the
   outer app. Rerun `sign.sh`; it orders passes correctly.
3. You passed `--deep` somewhere. Don't.

### `notarytool` rejects with "The binary uses an SDK older than 10.9"

A very old Rust toolchain or a pre-compiled binary dependency. Update
Rust (`rustup update`) and rebuild from clean (`cargo clean`).

### `notarytool` rejects with "The executable does not have the
hardened runtime enabled"

`sign.sh` was not run, or was run with a different tool that didn't set
`--options runtime`. Re-run `sign.sh` on the bundle.

### `stapler staple` says "Could not find the ticket"

Apple's CDN is eventually-consistent. `notarytool submit --wait`
returning "Accepted" does not guarantee the ticket is globally visible
yet. Wait 30 seconds and retry `stapler staple`.

### DMG mounts fine but Gatekeeper says "damaged and can't be opened"

The DMG was downloaded via a browser and the quarantine attribute was
applied after signing. This is expected for unnotarized builds. Once
notarized + stapled, Gatekeeper will accept the download without a
network lookup.

### `create-dmg` hangs / times out

`create-dmg` uses AppleScript to arrange window geometry, which fails
silently under SSH sessions without a logged-in GUI. Run from a local
terminal session.

### Entitlements rejected: "Unsupported entitlement"

Check that `Jellify.entitlements` does not contain MAS-only keys like
`com.apple.application-identifier` or sandbox keys. We are Developer
ID, not MAS.

---

## CI and auto-update

Intentionally out of scope here. CI wiring, Sparkle appcast/EdDSA key,
and auto-update delta channel are tracked separately in the BATCH-19
milestone.
