#!/usr/bin/env bash
# wave-report.sh — emit a wave summary at end-of-wave.
#
# Pulls counts from GitHub for issues filed and PRs opened/merged within
# the wave's wall-clock window. Reads the wave-start marker if present.
#
# Usage:
#   Scripts/wave-report.sh         # report on the current/most-recent wave
#   Scripts/wave-report.sh <since> # report on activity since ISO timestamp
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="$ROOT/.wave-start"

since="${1:-}"
if [[ -z "$since" ]]; then
  if [[ -f "$MARKER" ]]; then
    started=$(awk '{print $1}' < "$MARKER")
    since=$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ)
  else
    since=$(date -u -v-4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u --date='4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  fi
fi

echo "wave report"
echo "==========="
echo "since: $since"
echo

# Issues filed by the auto-audit during this wave.
echo "## Issues filed (source:auto-audit)"
gh issue list --label "source:auto-audit" --state all --search "created:>$since" \
  --json number,title,labels,state \
  --template '{{range .}}- #{{.number}} [{{.state}}] {{.title}}{{"\n"}}{{end}}'
echo

# PRs opened in this wave.
echo "## PRs opened"
gh pr list --state all --search "created:>$since" \
  --json number,title,state,mergedAt,headRefName \
  --template '{{range .}}- #{{.number}} [{{.state}}] {{.title}} ({{.headRefName}}){{if .mergedAt}} merged {{.mergedAt}}{{end}}{{"\n"}}{{end}}'
echo

# Hotspot lock state right now.
echo "## Hotspot locks (current)"
"$ROOT/Scripts/area-lock.sh" status
echo

# Quiet areas.
echo "## Areas in cooldown (triage:quiet-30d)"
gh issue list --label "triage:quiet-30d" --state open \
  --json number,title \
  --template '{{range .}}- #{{.number}} {{.title}}{{"\n"}}{{end}}' || true
echo

# Wall-clock if marker present.
if [[ -f "$MARKER" ]]; then
  start=$(awk '{print $1}' < "$MARKER")
  deadline=$(awk '{print $2}' < "$MARKER")
  now=$(date +%s)
  used=$(( now - start ))
  budget=$(( deadline - start ))
  echo "## Time"
  echo "used:    ${used}s of ${budget}s"
  if [[ "$now" -ge "$deadline" ]]; then
    echo "status:  EXPIRED"
  else
    echo "status:  active ($((deadline - now))s remaining)"
  fi
fi
