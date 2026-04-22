#!/usr/bin/env bash
# Launch a debug build of Jellify.app in a known state for Accessibility
# Inspector audits. Accessibility Inspector itself cannot be driven from the
# command line, so the manual steps are:
#
#   1. Run this script.
#   2. Open Xcode -> Open Developer Tool -> Accessibility Inspector.
#   3. In Accessibility Inspector, use the target chooser at the top-left to
#      select the running "Jellify" process.
#   4. Switch to the Audit panel, click Run Audit, and walk the app through
#      each screen listed in ../docs/a11y/README.md.
#   5. Save each report as plain text to
#      ../docs/a11y/audits/<YYYY-MM-DD>/<screen>.txt.
#   6. Ctrl-C this script (or `kill $PID`) when done.
#
# Usage:  ./macos/Scripts/a11y-audit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"

cd "$MACOS"

echo "==> Building jellify_core (xcframework)"
./Scripts/build-core.sh

echo "==> swift build"
swift build

echo "==> Wrapping as Jellify.app"
./Scripts/make-bundle.sh

APP="$MACOS/build/Jellify.app"
EXE="$APP/Contents/MacOS/Jellify"

if [[ ! -x "$EXE" ]]; then
  echo "error: Jellify executable not found at $EXE" >&2
  exit 1
fi

echo "==> Launching $APP"
"$EXE" &
PID=$!

cleanup() {
  if kill -0 "$PID" 2>/dev/null; then
    echo
    echo "==> Stopping Jellify (PID $PID)"
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

cat <<EOF

App is running (PID $PID).

Next steps:
  1. Xcode -> Open Developer Tool -> Accessibility Inspector.
  2. In Accessibility Inspector, select "Jellify" in the target chooser
     (top-left of the Inspector window).
  3. Open the Audit panel and run it against each screen listed in
     macos/docs/a11y/README.md (Login, Library, Search, Album Detail,
     empty-state Home, PlayerBar playing, PlayerBar idle).
  4. Save each audit report as plain text to
     macos/docs/a11y/audits/\$(date +%Y-%m-%d)/<screen>.txt.

Press Ctrl-C (or run: kill $PID) to stop the app when the sweep is done.
EOF

wait "$PID"
