#!/usr/bin/env bash
# Smoke check for the schermes daemon: health, first-run setup, login, the auth guard and the
# settings round-trip. Idempotent — after the first run the owner already exists, so it logs in
# instead of setting up, which is what makes it safe to re-run after `docker compose restart`.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
base=${SCHERMES_URL:-http://127.0.0.1:${SCHERMES_PORT:-7777}}
password=${SCHERMES_SMOKE_PASSWORD:-smoke-test-password}
api_key='sk-smoke-shouldnevershowup'
model="smoke-model-$$"
base_url='https://api.example.com/v1'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/jar"

say()  { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
body() { cat "$tmp/body"; }

# Sends a request through the cookie jar and leaves the status in $tmp/status.
req() {
  local method=$1 path=$2; shift 2
  local args=(-sS -o "$tmp/body" -w '%{http_code}' -X "$method" -b "$tmp/jar" -c "$tmp/jar")
  [ $# -gt 0 ] && args+=(-H 'content-type: application/json' -d "$1")
  curl "${args[@]}" "$base$path" > "$tmp/status"
}

expect() {
  local want=$1
  [ "$(cat "$tmp/status")" = "$want" ] || fail "$2: expected HTTP $want, got $(cat "$tmp/status") — $(body)"
}

say "waiting for $base/api/health"
for _ in $(seq 60); do
  curl -fsS "$base/api/health" -o "$tmp/body" 2>/dev/null && break
  sleep 1
done
curl -fsS "$base/api/health" -o "$tmp/body" >/dev/null 2>&1 || fail "the daemon never answered on $base"
jq -e '.status == "ok"' "$tmp/body" >/dev/null || fail "health did not report ok: $(body)"
setup_required=$(jq -r '.setupRequired' "$tmp/body")
echo "   ok, setupRequired=$setup_required"

if [ "$setup_required" = "true" ]; then
  say "first visit: setting the owner password"
  req POST /api/auth/setup "{\"password\":\"$password\"}"
  expect 201 "setup"
else
  say "owner password already set, skipping setup"
fi

say "setup refuses to run a second time"
req POST /api/auth/setup '{"password":"attacker-chosen-password"}'
expect 409 "second setup"

say "the auth guard rejects an unauthenticated request"
rm -f "$tmp/jar"
code=$(curl -sS -o "$tmp/body" -w '%{http_code}' "$base/api/settings")
[ "$code" = "401" ] || fail "settings without a session returned $code, expected 401"

say "logging in issues a session cookie"
req POST /api/auth/login "{\"password\":\"$password\"}"
expect 200 "login"
grep -q schermes_session "$tmp/jar" || fail "login did not set a session cookie"

say "settings round-trip"
req PUT /api/settings "{\"baseUrl\":\"$base_url\",\"model\":\"$model\",\"apiKey\":\"$api_key\"}"
expect 200 "settings write"

req GET /api/settings
expect 200 "settings read"
jq -e --arg u "$base_url" --arg m "$model" \
  '.baseUrl == $u and .model == $m and .apiKeySet == true' "$tmp/body" >/dev/null \
  || fail "settings did not round-trip: $(body)"
grep -q shouldnevershowup "$tmp/body" && fail "the api key came back in the settings response"
echo "   baseUrl and model round-tripped, api key withheld"

say "the api key never reached the daemon log"
if command -v docker >/dev/null 2>&1 \
   && (cd "$root" && docker compose ps --format '{{.Service}}' 2>/dev/null | grep -qx schermes); then
  if (cd "$root" && docker compose logs --no-color schermes 2>/dev/null) | grep -q shouldnevershowup; then
    fail "the api key appears in the daemon log"
  fi
  echo "   log is clean"
else
  echo "   skipped: not running against a docker compose service"
fi

printf '\nOK: health, setup, login, auth guard and settings all behave\n'
