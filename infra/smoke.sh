#!/usr/bin/env bash
# Smoke check for the schermes daemon: health, first-run setup, login, the auth guard, the
# settings round-trip and the agent lifecycle. Idempotent — after the first run the owner and
# the smoke agents already exist, so it logs in and reuses them instead of creating them, which
# is what makes it safe to re-run after `docker compose restart`.
#
# The agent desktop assertions need the docker harness and are skipped without it.
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

compose() { (cd "$root" && docker compose "$@"); }
in_container() { compose exec -T schermes "$@"; }

harness=false
if command -v docker >/dev/null 2>&1 \
   && compose ps --format '{{.Service}}' 2>/dev/null | grep -qx schermes; then
  harness=true
fi

wait_health() {
  local _
  for _ in $(seq 60); do
    curl -fsS "$base/api/health" -o "$tmp/body" 2>/dev/null && break
    sleep 1
  done
  curl -fsS "$base/api/health" -o "$tmp/body" >/dev/null 2>&1 \
    || fail "the daemon never answered on $base"
  jq -e '.status == "ok"' "$tmp/body" >/dev/null || fail "health did not report ok: $(body)"
}

say "waiting for $base/api/health"
wait_health
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
if [ "$harness" = true ]; then
  if compose logs --no-color schermes 2>/dev/null | grep -q shouldnevershowup; then
    fail "the api key appears in the daemon log"
  fi
  echo "   log is clean"
else
  echo "   skipped: not running against a docker compose service"
fi

agent_one=smoke-one
agent_two=smoke-two
second_port=${SCHERMES_SMOKE_SECOND_PORT:-7778}
second_pidfile=/tmp/schermes-smoke-daemon.pid

say "agent names that could reach a shell are refused"
for bad in 'Smoke' 'has space' '../escape' '$(id)' '-leading-dash'; do
  req POST /api/agents "$(jq -nc --arg n "$bad" '{name: $n}')"
  expect 400 "invalid name $bad"
done
echo "   all refused with 400"

say "creating $agent_one and $agent_two"
for agent in "$agent_one" "$agent_two"; do
  req POST /api/agents "$(jq -nc --arg n "$agent" '{name: $n}')"
  case "$(cat "$tmp/status")" in
    201) echo "   created $agent" ;;
    409) echo "   $agent already exists" ;;
    *) fail "creating $agent: HTTP $(cat "$tmp/status") — $(body)" ;;
  esac
done

req GET /api/agents
expect 200 "agent list"
jq -e --arg a "$agent_one" --arg b "$agent_two" \
  '([.[] | select(.name == $a or .name == $b)] | length) == 2
   and ([.[].display] | length) == ([.[].display] | unique | length)' "$tmp/body" >/dev/null \
  || fail "the two agents did not list with distinct displays: $(body)"
display_one=$(jq -r --arg a "$agent_one" '.[] | select(.name == $a) | .display' "$tmp/body")
display_two=$(jq -r --arg b "$agent_two" '.[] | select(.name == $b) | .display' "$tmp/body")
echo "   $agent_one on :$display_one, $agent_two on :$display_two"

req GET "/api/agents/$agent_one"
expect 200 "fetch one agent"
req GET /api/agents/nobody
expect 404 "fetch a missing agent"

if [ "$harness" != true ]; then
  printf '\nOK: health, setup, login, auth guard, settings and the agents API all behave\n'
  printf '    (desktop assertions skipped: not running against a docker compose service)\n'
  exit 0
fi

xvnc_pid() { in_container sh -c "pgrep -u agent-$1 -f 'Xvnc :$2( |\$)' | head -1" | tr -d '\r'; }

vnc_socket() {
  in_container ss -ltnH "sport = :$((5900 + $1))" | awk '{print $4}' | head -1 | tr -d '\r'
}

wait_desktop() {
  local name=$1 display=$2 _
  for _ in $(seq 90); do
    [ -n "$(xvnc_pid "$name" "$display")" ] && [ -n "$(vnc_socket "$display")" ] && return 0
    sleep 1
  done
  fail "agent $name has no live desktop on :$display after 90s"
}

agent_home() { in_container sh -c "getent passwd agent-$1 | cut -d: -f6" | tr -d '\r'; }

assert_desktops() {
  local pair name display socket home
  for pair in "$agent_one:$display_one" "$agent_two:$display_two"; do
    name=${pair%:*} display=${pair#*:}
    wait_desktop "$name" "$display"

    home=$(agent_home "$name")
    [ -n "$home" ] || fail "agent $name has no linux user"
    in_container test -d "$home/workspace" || fail "agent $name has no workspace in $home"
    in_container test -d "$home/uploads" || fail "agent $name has no uploads dir in $home"
    [ -n "$(in_container sh -c "pgrep -u agent-$name -f openbox | head -1")" ] \
      || fail "agent $name has an X server but no window manager"

    socket=$(vnc_socket "$display")
    case "$socket" in
      127.0.0.1:*)
        echo "   $name  :$display  vnc $socket  pid $(xvnc_pid "$name" "$display")  home $home"
        ;;
      *) fail "agent $name: vnc listens on $socket, which is not loopback" ;;
    esac
  done
}

say "each agent has a live desktop on a loopback-only vnc port"
assert_desktops

say "the agents and their desktops survive a container restart"
compose restart schermes >/dev/null
wait_health
req GET /api/agents
expect 200 "agent list after restart"
jq -e --arg a "$agent_one" --arg b "$agent_two" \
  '([.[] | select(.name == $a or .name == $b)] | length) == 2' "$tmp/body" >/dev/null \
  || fail "the agents did not survive the restart: $(body)"
# Restarting the container destroys its pid namespace, so every desktop is respawned here. The
# adopt path is exercised below by restarting the daemon alone, which is what a real host does.
assert_desktops

# Runs a second daemon against the same database, which is what `systemctl restart schermes`
# leaves the desktops facing: a new daemon process while their X servers are still running. It
# reconciles on boot and we read the outcome it logged. Its cmdline is identical to the
# container's own daemon and `ss -p` shows no pids without CAP_SYS_PTRACE, so it records its own
# pid before exec'ing — that file is the only safe handle on it.
stop_second_daemon() {
  in_container sh -c \
    "if [ -f $second_pidfile ]; then kill \$(cat $second_pidfile) 2>/dev/null; fi
     rm -f $second_pidfile
     exit 0"
}
trap 'stop_second_daemon >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

reconcile() {
  local client _
  stop_second_daemon
  : > "$tmp/reconcile.log"
  compose exec -T schermes sh -c \
    "echo \$\$ > $second_pidfile
     exec setpriv --reuid schermes --regid schermes --init-groups \
       env HOME=/var/lib/schermes USER=schermes LOGNAME=schermes SCHERMES_PORT=$second_port \
       node /opt/schermes/daemon/src/main.ts" >"$tmp/reconcile.log" 2>&1 &
  client=$!
  for _ in $(seq 90); do
    [ "$(grep -c 'desktop reconciled' "$tmp/reconcile.log" || true)" -ge 2 ] && break
    sleep 1
  done
  grep -q 'desktop reconciled' "$tmp/reconcile.log" \
    || fail "the second daemon reconciled nothing — $(cat "$tmp/reconcile.log")"
  stop_second_daemon
  wait "$client" 2>/dev/null || true
}

outcome_of() {
  grep -h 'desktop reconciled' "$tmp/reconcile.log" \
    | jq -r --arg a "$1" 'select(.agent == $a) | .outcome' | tail -1
}

say "a restarted daemon adopts the desktops that are still running"
before_one=$(xvnc_pid "$agent_one" "$display_one")
before_two=$(xvnc_pid "$agent_two" "$display_two")
reconcile
for name in "$agent_one" "$agent_two"; do
  [ "$(outcome_of "$name")" = adopted ] \
    || fail "$name was $(outcome_of "$name"), expected adopted — $(cat "$tmp/reconcile.log")"
done
[ "$(xvnc_pid "$agent_one" "$display_one")" = "$before_one" ] \
  && [ "$(xvnc_pid "$agent_two" "$display_two")" = "$before_two" ] \
  || fail "the Xvnc pids changed, so the desktops were respawned rather than adopted"
echo "   both adopted, same pids ($before_one, $before_two)"

say "a desktop that died is respawned while the survivor is still adopted"
in_container kill -9 "$before_one"
for _ in $(seq 30); do [ -z "$(xvnc_pid "$agent_one" "$display_one")" ] && break; sleep 1; done
[ -z "$(xvnc_pid "$agent_one" "$display_one")" ] || fail "could not kill $agent_one's desktop"
reconcile
[ "$(outcome_of "$agent_one")" = started ] \
  || fail "$agent_one was $(outcome_of "$agent_one"), expected started"
[ "$(outcome_of "$agent_two")" = adopted ] \
  || fail "$agent_two was $(outcome_of "$agent_two"), expected adopted"
after_one=$(xvnc_pid "$agent_one" "$display_one")
[ -n "$after_one" ] && [ "$after_one" != "$before_one" ] \
  || fail "$agent_one's desktop did not come back with a new pid"
assert_desktops
echo "   $agent_one respawned as pid $after_one, $agent_two untouched"

printf '\nOK: health, setup, login, auth guard, settings, and two agents with adopted desktops\n'
