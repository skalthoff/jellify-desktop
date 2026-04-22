#!/usr/bin/env bash
# Build the jellify_core Rust library for macOS and wrap it as an XCFramework
# that the Swift package can consume.
#
# By default this builds a universal xcframework (arm64 + x86_64) stitched
# together with `lipo`. The install base still has a meaningful Intel tail
# (pre-2020 Macs, Ventura floor) so the shipped DMG must cover both.
#
# Single-arch is still available for dev-loop speed via --arm64-only.
#
# Usage:
#   ./macos/Scripts/build-core.sh                 # universal debug
#   ./macos/Scripts/build-core.sh --release       # universal release
#   ./macos/Scripts/build-core.sh --arm64-only    # skip x86_64 (dev only)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
PROFILE="debug"
CARGO_FLAGS=""
UNIVERSAL=1

for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            CARGO_FLAGS="--release"
            ;;
        --debug)
            PROFILE="debug"
            CARGO_FLAGS=""
            ;;
        --arm64-only)
            UNIVERSAL=0
            ;;
        -h | --help)
            sed -n '2,14p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "usage: $0 [--release|--debug] [--arm64-only]" >&2
            exit 2
            ;;
    esac
done

ARM64_TARGET="aarch64-apple-darwin"
X86_64_TARGET="x86_64-apple-darwin"

# Per-arch expected artifact paths.
ARM64_STATIC="$ROOT/target/$ARM64_TARGET/$PROFILE/libjellify_core.a"
X86_64_STATIC="$ROOT/target/$X86_64_TARGET/$PROFILE/libjellify_core.a"
UNIVERSAL_DIR="$ROOT/target/universal-apple-darwin/$PROFILE"
UNIVERSAL_STATIC="$UNIVERSAL_DIR/libjellify_core.a"

# Scratch dirs we might touch; cleaned up on failure so a re-run isn't
# bitten by a half-written xcframework.
GEN="$MACOS/build/generated"
HEADERS="$MACOS/build/Headers"
XCF="$MACOS/Jellify.xcframework"

cleanup_on_failure() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "==> build-core.sh failed (exit $code); cleaning scratch dirs" >&2
        rm -rf "$GEN" "$HEADERS"
        # Leave the xcframework alone if it was a completed prior run —
        # only remove it if we started rewriting it this run.
        if [[ -n "${XCF_IN_PROGRESS:-}" ]]; then
            rm -rf "$XCF"
        fi
    fi
    return $code
}
trap cleanup_on_failure EXIT

echo "==> Building jellify_core ($PROFILE, universal=$UNIVERSAL)"
(cd "$ROOT" && cargo build $CARGO_FLAGS --target "$ARM64_TARGET" -p jellify_core)
if [[ ! -f "$ARM64_STATIC" ]]; then
    echo "error: arm64 static lib not found at $ARM64_STATIC" >&2
    exit 1
fi

if [[ "$UNIVERSAL" -eq 1 ]]; then
    # Ensure the x86_64 target is installed; fail with a clear message if not.
    if ! rustup target list --installed 2>/dev/null | grep -q "^$X86_64_TARGET$"; then
        echo "error: $X86_64_TARGET rustup target is not installed." >&2
        echo "       run: rustup target add $X86_64_TARGET" >&2
        echo "       (or pass --arm64-only for a dev build)" >&2
        exit 1
    fi

    (cd "$ROOT" && cargo build $CARGO_FLAGS --target "$X86_64_TARGET" -p jellify_core)
    if [[ ! -f "$X86_64_STATIC" ]]; then
        echo "error: x86_64 static lib not found at $X86_64_STATIC" >&2
        exit 1
    fi

    echo "==> Fusing universal static lib via lipo"
    mkdir -p "$UNIVERSAL_DIR"
    lipo -create "$ARM64_STATIC" "$X86_64_STATIC" -output "$UNIVERSAL_STATIC"
    # Sanity check: lipo -info should report both arches.
    lipo -info "$UNIVERSAL_STATIC"
    STATIC="$UNIVERSAL_STATIC"
else
    STATIC="$ARM64_STATIC"
fi

echo "==> Building uniffi-bindgen"
(cd "$ROOT" && cargo build $CARGO_FLAGS --bin uniffi-bindgen -p jellify_core)

# The library was built for arm64 above; that's where the dylib lives.
# (When building only the uniffi-bindgen bin, cargo doesn't materialize the
# cdylib for the host target, so we can't rely on target/$PROFILE/ for it.)
DYLIB="$ROOT/target/$ARM64_TARGET/$PROFILE/libjellify_core.dylib"
BINDGEN="$ROOT/target/$PROFILE/uniffi-bindgen"

if [[ ! -f "$DYLIB" ]]; then
    echo "error: dylib not found at $DYLIB" >&2
    exit 1
fi

echo "==> Generating Swift bindings -> $GEN"
rm -rf "$GEN"
mkdir -p "$GEN"
# bindgen's --library mode runs `cargo metadata` internally, which needs to be
# invoked from inside the workspace.
(cd "$ROOT" && "$BINDGEN" generate --library "$DYLIB" --language swift --out-dir "$GEN")

# UniFFI produces: <name>.swift, <name>FFI.h, <name>FFI.modulemap.
# We consume the Swift in our own target and the header+modulemap in the xcframework.
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$GEN"/*.h "$HEADERS/"

# The generated Swift file looks for `import jellify_coreFFI` (see the
# `#if canImport(jellify_coreFFI)` block). The C module name must match.
cat > "$HEADERS/module.modulemap" <<'EOF'
module jellify_coreFFI {
    header "jellify_coreFFI.h"
    export *
}
EOF

echo "==> Creating $XCF"
XCF_IN_PROGRESS=1
rm -rf "$XCF"
xcodebuild -create-xcframework \
    -library "$STATIC" \
    -headers "$HEADERS" \
    -output "$XCF" >/dev/null
XCF_IN_PROGRESS=

# Place the generated Swift source where the SPM target picks it up.
DEST="$MACOS/Sources/JellifyCore/Generated"
mkdir -p "$DEST"
cp "$GEN/jellify_core.swift" "$DEST/jellify_core.swift"

echo "==> Done."
echo "    xcframework : $XCF"
echo "    swift source: $DEST/jellify_core.swift"
