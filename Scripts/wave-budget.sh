#!/usr/bin/env bash
# wave-budget.sh — the agentic pipeline's wall-clock gate.
#
# Each wave starts by writing a UNIX timestamp to .wave-start.
# Subsequent agents run `Scripts/wave-budget.sh remaining` before
# claiming new work; if seconds-remaining <= 0 they exit cleanly.
#
# Usage:
#   Scripts/wave-budget.sh start [budget-seconds]   # defaults to 4h
#   Scripts/wave-budget.sh remaining                 # prints integer secs (>=0)
#   Scripts/wave-budget.sh expired                   # exit 0 if expired, 1 if not
#   Scripts/wave-budget.sh end                       # clears the marker
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="$ROOT/.wave-start"
DEFAULT_BUDGET=14400  # 4 hours

cmd="${1:-}"
case "$cmd" in
  start)
    budget="${2:-$DEFAULT_BUDGET}"
    deadline=$(( $(date +%s) + budget ))
    printf '%s %s\n' "$(date +%s)" "$deadline" > "$MARKER"
    echo "wave started; deadline: $(date -r "$deadline")"
    ;;
  remaining)
    if [[ ! -f "$MARKER" ]]; then
      echo "0"
      exit 0
    fi
    deadline=$(awk '{print $2}' < "$MARKER")
    now=$(date +%s)
    remaining=$(( deadline - now ))
    if [[ "$remaining" -lt 0 ]]; then remaining=0; fi
    echo "$remaining"
    ;;
  expired)
    if [[ ! -f "$MARKER" ]]; then
      exit 0  # no wave => expired by default
    fi
    deadline=$(awk '{print $2}' < "$MARKER")
    now=$(date +%s)
    [[ "$now" -ge "$deadline" ]] && exit 0 || exit 1
    ;;
  end)
    rm -f "$MARKER"
    echo "wave ended."
    ;;
  *)
    cat <<EOF
usage:
  $0 start [budget-seconds]   default budget: ${DEFAULT_BUDGET}s (4h)
  $0 remaining                 prints integer seconds remaining
  $0 expired                   exit 0 if expired, 1 if not
  $0 end                       clears the wave marker

marker file: $MARKER
EOF
    exit 2
    ;;
esac
