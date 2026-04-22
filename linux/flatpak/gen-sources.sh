#!/usr/bin/env bash
#
# gen-sources.sh — generate cargo-sources.json for offline Flatpak builds.
#
# Runs flatpak-cargo-generator.py from flatpak-builder-tools against the
# workspace Cargo.lock and writes linux/flatpak/cargo-sources.json, which the
# Flatpak manifest references to vendor all crate dependencies.
#
# Prerequisites:
#   - git (run from within the jellify-desktop git checkout)
#   - python3
#   - pip install aiohttp toml
#
# Resolution order for the generator script:
#   1. $FLATPAK_CARGO_GENERATOR (absolute path to an existing file)
#   2. flatpak-cargo-generator.py on $PATH
#   3. downloaded to linux/flatpak/.cache/ from the pinned URL below
#
# The generator is pinned to a specific upstream commit for reproducibility
# and supply-chain safety. Bump the pin manually during dependency updates;
# see CONTRIBUTING.md.
#
# Pinned upstream: flatpak/flatpak-builder-tools @ 34ecf07ef4843f36b3078637ca13f1dbb1c2963a
#
# Usage:
#   ./linux/flatpak/gen-sources.sh
#
# The script works from any cwd; it resolves the repo root via git.

set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
	echo "error: gen-sources.sh requires git; install git and run from within the jellify-desktop git checkout" >&2
	exit 1
fi

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	echo "error: gen-sources.sh must be run from within the jellify-desktop git checkout" >&2
	exit 1
fi

FLATPAK_DIR="$REPO_ROOT/linux/flatpak"
CACHE_DIR="$FLATPAK_DIR/.cache"
OUTPUT="$FLATPAK_DIR/cargo-sources.json"
CARGO_LOCK="$REPO_ROOT/Cargo.lock"
GENERATOR_PIN="34ecf07ef4843f36b3078637ca13f1dbb1c2963a"
GENERATOR_URL="https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/${GENERATOR_PIN}/cargo/flatpak-cargo-generator.py"

if [[ ! -f "$CARGO_LOCK" ]]; then
	echo "error: $CARGO_LOCK not found" >&2
	exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "error: python3 is required but not found on PATH" >&2
	exit 1
fi

resolve_generator() {
	if [[ -n "${FLATPAK_CARGO_GENERATOR:-}" ]]; then
		if [[ -f "$FLATPAK_CARGO_GENERATOR" ]]; then
			printf '%s' "$FLATPAK_CARGO_GENERATOR"
			return 0
		fi
		echo "error: FLATPAK_CARGO_GENERATOR is set but '$FLATPAK_CARGO_GENERATOR' is not a file" >&2
		return 1
	fi

	if command -v flatpak-cargo-generator.py >/dev/null 2>&1; then
		command -v flatpak-cargo-generator.py
		return 0
	fi

	mkdir -p "$CACHE_DIR"
	local cached="$CACHE_DIR/flatpak-cargo-generator-${GENERATOR_PIN}.py"
	if [[ ! -f "$cached" ]]; then
		echo "downloading flatpak-cargo-generator.py (pinned to ${GENERATOR_PIN}) into $CACHE_DIR" >&2
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL "$GENERATOR_URL" -o "$cached"
		elif command -v wget >/dev/null 2>&1; then
			wget -q "$GENERATOR_URL" -O "$cached"
		else
			echo "error: need curl or wget to download the generator" >&2
			return 1
		fi
	fi
	printf '%s' "$cached"
}

GENERATOR="$(resolve_generator)"

TMP_OUTPUT=""
cleanup_tmp() {
	if [[ -n "$TMP_OUTPUT" && -f "$TMP_OUTPUT" ]]; then
		rm -f "$TMP_OUTPUT"
	fi
}
trap cleanup_tmp EXIT

TMP_OUTPUT="$(mktemp "${FLATPAK_DIR}/cargo-sources.json.tmp.XXXXXX")"

echo "using generator: $GENERATOR" >&2
python3 "$GENERATOR" "$CARGO_LOCK" -o "$TMP_OUTPUT"
mv "$TMP_OUTPUT" "$OUTPUT"
TMP_OUTPUT=""

echo "wrote $OUTPUT"
