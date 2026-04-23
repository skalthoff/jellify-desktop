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

# `GET /Startup/User` is what the Jellyfin web wizard hits when it mounts
# the "create admin" form — and that call is *also* what lazily seeds the
# default admin row in the database. Without it, the very next
# `POST /Startup/User` blows up with
# `System.InvalidOperationException: Sequence contains no elements`
# from `StartupController.UpdateStartupUser -> _userManager.Users.First()`.
# Works on 10.9 / 10.10 / 10.11 alike.
#
# Also acts as a readiness probe: Jellyfin accepts /System/Info/Public
# a few seconds before it's ready for write endpoints, and the first
# /Startup/Configuration after boot tends to 503 until the host stops
# reloading config. Retry until we get the 200 that says everything's up.
seed_default_user() {
	local deadline=$(( $(date +%s) + WAIT_SECONDS ))
	while (( $(date +%s) < deadline )); do
		if curl -fsS "$URL/Startup/User" >/dev/null 2>&1; then
			log "default admin seeded"
			return 0
		fi
		sleep 2
	done
	log "GET /Startup/User never returned 200 within ${WAIT_SECONDS}s"
	return 1
}

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
	local attempts="${3:-15}"
	local tmp
	tmp="$(mktemp)"
	# Jellyfin's startup endpoints are reachable before the server fully
	# finishes initializing — /Startup/User in particular has been seen to
	# 500 a handful of times immediately after /System/Info/Public starts
	# responding. Retry each call with a short backoff and surface the
	# response body if every attempt fails.
	local i=1
	while (( i <= attempts )); do
		local http_code
		if [[ -n "$body" ]]; then
			http_code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST "$URL$path" \
				-H 'Content-Type: application/json' \
				--data "$body" || echo "000")
		else
			http_code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST "$URL$path" || echo "000")
		fi
		if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
			cat "$tmp"
			rm -f "$tmp"
			return 0
		fi
		log "POST $path attempt $i/$attempts -> HTTP $http_code"
		(( i < attempts )) && sleep 2
		i=$((i + 1))
	done
	log "POST $path failed after $attempts attempts. Last response body:"
	cat "$tmp" >&2 || true
	rm -f "$tmp"
	return 1
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
seed_default_user

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
