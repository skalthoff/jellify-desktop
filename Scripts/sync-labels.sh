#!/usr/bin/env bash
# Create (or update) every label defined in .github/labels.yml.
# Idempotent — `gh label create --force` updates existing labels in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/.github/labels.yml"

if [[ ! -f "$FILE" ]]; then
  echo "error: labels file not found at $FILE" >&2
  exit 1
fi

# Parse the minimal YAML (one label per line, each a flow-style mapping).
while IFS= read -r line; do
  [[ "$line" =~ ^# || -z "${line// }" ]] && continue
  # Strip leading `- { ` and trailing ` }`
  entry="${line#*\{ }"
  entry="${entry% \}}"
  name=$(echo "$entry"        | awk -F'name: *"' '{print $2}' | awk -F'"' '{print $1}')
  color=$(echo "$entry"       | awk -F'color: *"' '{print $2}' | awk -F'"' '{print $1}')
  description=$(echo "$entry" | awk -F'description: *"' '{print $2}' | awk -F'"' '{print $1}')
  [[ -z "$name" ]] && continue
  echo "sync: $name"
  gh label create "$name" --color "$color" --description "$description" --force >/dev/null
done < "$FILE"

echo "done."
