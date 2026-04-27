#!/usr/bin/env bash
# area-lock.sh — claim / release / status for hotspot file locks.
#
# Hotspots are tracked as GitHub issues bearing a `lock:hotspot-<name>` label.
# An open lock issue means the hotspot is in use; a fixer must abort and
# wait. Issues are squashed-closed by `release` when the work merges.
#
# Usage:
#   Scripts/area-lock.sh claim   <hotspot> <pr-number-or-pending> <agent-id>
#   Scripts/area-lock.sh release <hotspot>
#   Scripts/area-lock.sh status  [<hotspot>]
#
# Hotspots: clientrs | testsrs | appmodel | jellifyapp
set -euo pipefail

VALID_HOTSPOTS=("clientrs" "testsrs" "appmodel" "jellifyapp")

is_valid_hotspot() {
  local h="$1"
  for v in "${VALID_HOTSPOTS[@]}"; do
    [[ "$v" == "$h" ]] && return 0
  done
  return 1
}

cmd="${1:-}"
case "$cmd" in
  claim)
    hotspot="${2:-}"
    pr="${3:-pending}"
    agent="${4:-unknown}"
    if ! is_valid_hotspot "$hotspot"; then
      echo "error: hotspot must be one of: ${VALID_HOTSPOTS[*]}" >&2
      exit 2
    fi
    label="lock:hotspot-$hotspot"
    existing=$(gh issue list --label "$label" --state open --json number,title --limit 5)
    count=$(echo "$existing" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
    if [[ "$count" -gt 0 ]]; then
      echo "LOCKED: $label is already held by:"
      echo "$existing" | python3 -c 'import json,sys; [print(f"  #{i[\"number\"]}: {i[\"title\"]}") for i in json.load(sys.stdin)]'
      exit 1
    fi
    title="lock: $hotspot held by $agent (PR #$pr)"
    body=$(printf 'Claim time: %s\nAgent: %s\nPR: #%s\n\nDo not assign manually. Closes when `Scripts/area-lock.sh release %s` runs.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$pr" "$hotspot")
    issue_url=$(gh issue create --title "$title" --body "$body" --label "$label")
    echo "CLAIMED: $issue_url"
    ;;
  release)
    hotspot="${2:-}"
    if ! is_valid_hotspot "$hotspot"; then
      echo "error: hotspot must be one of: ${VALID_HOTSPOTS[*]}" >&2
      exit 2
    fi
    label="lock:hotspot-$hotspot"
    nums=$(gh issue list --label "$label" --state open --json number -q '.[].number')
    if [[ -z "$nums" ]]; then
      echo "no lock open for $hotspot"
      exit 0
    fi
    for n in $nums; do
      gh issue close "$n" --comment "Released by Scripts/area-lock.sh release $hotspot."
      echo "RELEASED: #$n"
    done
    ;;
  status)
    hotspot="${2:-}"
    if [[ -z "$hotspot" ]]; then
      for h in "${VALID_HOTSPOTS[@]}"; do
        label="lock:hotspot-$h"
        n=$(gh issue list --label "$label" --state open --json number -q 'length')
        if [[ "$n" -gt 0 ]]; then
          echo "$h: LOCKED ($n)"
        else
          echo "$h: free"
        fi
      done
      exit 0
    fi
    if ! is_valid_hotspot "$hotspot"; then
      echo "error: hotspot must be one of: ${VALID_HOTSPOTS[*]}" >&2
      exit 2
    fi
    label="lock:hotspot-$hotspot"
    gh issue list --label "$label" --state open --json number,title,createdAt
    ;;
  *)
    cat <<EOF
usage:
  $0 claim   <hotspot> <pr-number-or-pending> <agent-id>
  $0 release <hotspot>
  $0 status  [<hotspot>]

hotspots: ${VALID_HOTSPOTS[*]}
EOF
    exit 2
    ;;
esac
