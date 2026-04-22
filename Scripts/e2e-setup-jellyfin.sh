#!/usr/bin/env bash
#
# e2e-setup-jellyfin.sh — complete Jellyfin's first-run setup wizard.
#
# A freshly-started Jellyfin container gates every non-startup endpoint behind
# the wizard (POST /Startup/{Configuration,User,RemoteAccess,Complete}). This
# script drives the wizard to completion so the e2e tests can log in with a
# known admin user. Designed for CI, but works locally against any Jellyfin
# that hasn't completed initial setup.
#
# Usage:
#   e2e-setup-jellyfin.sh <server_url> <admin_user> <admin_pass>
#
# Example:
#   e2e-setup-jellyfin.sh http://localhost:8096 jellify-e2e jellify-e2e-password
set -euo pipefail

URL="${1:?server url required (e.g. http://localhost:8096)}"
USER="${2:?admin username required}"
PASS="${3:?admin password required}"

WAIT_SECONDS="${JELLIFY_E2E_WAIT_SECONDS:-180}"

log() { printf '[e2e-setup] %s\n' "$*" >&2; }

wait_for_server() {
	log "waiting up to ${WAIT_SECONDS}s for $URL/System/Info/Public"
	local deadline=$(( $(date +%s) + WAIT_SECONDS ))
	while (( $(date +%s) < deadline )); do
		if curl -fsS "$URL/System/Info/Public" >/dev/null 2>&1; then
			log "server responding"
			return 0
		fi
		sleep 2
	done
	log "server did not respond within ${WAIT_SECONDS}s"
	return 1
}

json_post() {
	local path="$1"
	local body="${2:-}"
	if [[ -n "$body" ]]; then
		curl -fsS -X POST "$URL$path" \
			-H 'Content-Type: application/json' \
			--data "$body"
	else
		curl -fsS -X POST "$URL$path"
	fi
}

# Emit arguments as a compact JSON object. Avoids a python/jq dep and keeps
# quoting controlled when values come from env.
json_kv() {
	local out='{'
	local sep=''
	while (( "$#" >= 2 )); do
		local key="$1" value="$2"
		shift 2
		# Escape only the characters that would break a JSON string literal
		# here — backslashes and double quotes. Values are plain ASCII in CI
		# so we don't need full RFC-8259 escaping.
		value="${value//\\/\\\\}"
		value="${value//\"/\\\"}"
		out+="${sep}\"${key}\":\"${value}\""
		sep=','
	done
	out+='}'
	printf '%s' "$out"
}

wait_for_server

log "POST /Startup/Configuration"
json_post /Startup/Configuration \
	"$(json_kv UICulture en-US MetadataCountryCode US PreferredMetadataLanguage en)" \
	>/dev/null

log "POST /Startup/User ($USER)"
json_post /Startup/User \
	"$(json_kv Name "$USER" Password "$PASS")" \
	>/dev/null

log "POST /Startup/RemoteAccess"
json_post /Startup/RemoteAccess \
	'{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
	>/dev/null

log "POST /Startup/Complete"
json_post /Startup/Complete >/dev/null

log "ready: $URL (admin=$USER)"
