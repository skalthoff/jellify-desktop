#!/usr/bin/env bash
# Build the jellify_core Rust library for macOS and wrap it as an XCFramework
# that the Swift package can consume.
#
# For M2 (dev), we build arm64-only. Universal binary (arm64 + x86_64) comes
# in M4 alongside signing / notarization.
#
# Usage:  ./macos/Scripts/build-core.sh [--release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
CORE="$ROOT/core"
PROFILE="debug"
CARGO_FLAGS=""

if [[ "${1:-}" == "--release" ]]; then
  PROFILE="release"
  CARGO_FLAGS="--release"
fi

echo "==> Building jellify_core ($PROFILE)"
TARGET="aarch64-apple-darwin"
(cd "$ROOT" && cargo build $CARGO_FLAGS --target "$TARGET" -p jellify_core)

STATIC="$ROOT/target/$TARGET/$PROFILE/libjellify_core.a"
if [[ ! -f "$STATIC" ]]; then
  echo "error: static lib not found at $STATIC" >&2
  exit 1
fi

echo "==> Building uniffi-bindgen"
(cd "$ROOT" && cargo build $CARGO_FLAGS --bin uniffi-bindgen -p jellify_core)

DYLIB="$ROOT/target/$PROFILE/libjellify_core.dylib"
BINDGEN="$ROOT/target/$PROFILE/uniffi-bindgen"

GEN="$MACOS/build/generated"
echo "==> Generating Swift bindings -> $GEN"
rm -rf "$GEN"
mkdir -p "$GEN"
# bindgen's --library mode runs `cargo metadata` internally, which needs to be
# invoked from inside the workspace.
(cd "$ROOT" && "$BINDGEN" generate --library "$DYLIB" --language swift --out-dir "$GEN")

# UniFFI produces: <name>.swift, <name>FFI.h, <name>FFI.modulemap.
# We consume the Swift in our own target and the header+modulemap in the xcframework.
HEADERS="$MACOS/build/Headers"
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

XCF="$MACOS/Jellify.xcframework"
echo "==> Creating $XCF"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$STATIC" \
  -headers "$HEADERS" \
  -output "$XCF" >/dev/null

# Place the generated Swift source where the SPM target picks it up.
DEST="$MACOS/Sources/JellifyCore/Generated"
mkdir -p "$DEST"
cp "$GEN/jellify_core.swift" "$DEST/jellify_core.swift"

echo "==> Done."
echo "    xcframework : $XCF"
echo "    swift source: $DEST/jellify_core.swift"
