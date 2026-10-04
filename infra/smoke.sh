#!/usr/bin/env bash
# Smoke check for the schermes daemon: health, first-run setup, login, the auth guard, the
# built UI on the same port, the settings round-trip and the agent lifecycle. Idempotent — after the first run the owner and
# the smoke agents already exist, so it logs in and reuses them instead of creating them, which
# is what makes it safe to re-run after `docker compose restart` and, now that /var/lib/schermes
# is a volume, after `docker compose up --build` too: nothing here wipes the database, and every
# read of a thread is a page rather than the whole of one, so a growing history costs nothing.
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
  say "first visit: setup is refused without the token from the daemon log"
  req POST /api/auth/setup "{\"password\":\"$password\"}"
  expect 403 "setup without a token"

  setup_token=${SCHERMES_SETUP_TOKEN:-}
  if [ -z "$setup_token" ] && [ "$harness" = true ]; then
    # Every boot without an owner prints a fresh one, so the newest line is the live token.
    setup_token=$(compose logs --no-log-prefix schermes 2>/dev/null \
      | grep '"msg":"first-run setup token"' | tail -1 | jq -r '.code // empty' || true)
  fi
  [ -n "$setup_token" ] || fail "no setup token: set SCHERMES_SETUP_TOKEN to the code in the daemon log"

  say "first visit: setting the owner password"
  req POST /api/auth/setup "{\"password\":\"$password\",\"setupToken\":\"$setup_token\"}"
  expect 201 "setup"
else
  say "owner password already set, skipping setup"
fi

say "setup refuses to run a second time"
req POST /api/auth/setup '{"password":"attacker-chosen-password","setupToken":"attacker-guess"}'
expect 409 "second setup"

say "the auth guard rejects an unauthenticated request"
rm -f "$tmp/jar"
code=$(curl -sS -o "$tmp/body" -w '%{http_code}' "$base/api/settings")
[ "$code" = "401" ] || fail "settings without a session returned $code, expected 401"

say "the daemon serves nothing but its api"
# An unknown api path is still the guard's 401 and not a 404, so an unauthenticated caller
# cannot map the routes; everything outside /api is Hono's own 404.
for pair in '/ 404' '/nope 404' '/api/nope 401'; do
  set -- $pair
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$base$1")
  [ "$code" = "$2" ] || fail "$1 returned $code, expected $2"
done
code=$(curl -sS --path-as-is -o /dev/null -w '%{http_code}' "$base/../../etc/passwd")
[ "$code" = "404" ] || fail "a traversal path returned $code, expected 404"
echo "   unknown paths 404, unknown api paths still 401, traversal refused"

say "logging in issues a session cookie"
req POST /api/auth/login "{\"password\":\"$password\"}"
expect 200 "login"
grep -q schermes_session "$tmp/jar" || fail "login did not set a session cookie"

say "the session list and the audit log see this login, and never show the session id"
login_sid=$(awk '$6 == "schermes_session" {print $7}' "$tmp/jar" | tail -1)
req GET /api/auth/sessions
expect 200 "list sessions"
jq -e 'any(.[]; .current == true and (.handle | length) == 16)' "$tmp/body" >/dev/null \
  || fail "the session list does not mark this session: $(body)"
grep -qF "$login_sid" "$tmp/body" && fail "the session list returned the raw session id"
req GET '/api/audit?limit=5'
expect 200 "read the audit log"
jq -e '.[0].action == "login" and .[0].detail.method == "password"' "$tmp/body" >/dev/null \
  || fail "the audit log does not start with this login: $(body)"
echo "   listed by handle, and the login is the newest audit entry"

agent_one=smoke-one
agent_two=smoke-two
registry_name=smoke-registry
registry_key='sk-registry-shouldnevershowup'

# Before the settings round-trip: that writes whichever model is the default, and a leftover the
# run made the default must not be the one it writes.
say "no registry model is left over from an earlier run"
req GET /api/models
expect 200 "list models"
keeper=$(jq -r --arg n "$registry_name" '[.[] | select(.name != $n)][0].id // empty' "$tmp/body")
for stale in $(jq -r --arg n "$registry_name" '.[] | select(.name == $n) | .id' "$tmp/body"); do
  for agent in "$agent_one" "$agent_two"; do req PUT "/api/agents/$agent/model" '{"id":null}'; done
  if [ -n "$keeper" ]; then
    req PUT /api/models/default "{\"id\":$keeper}"
    expect 200 "move the default off leftover model $stale"
  fi
  req DELETE "/api/models/$stale"
  expect 200 "remove model $stale, left behind by an earlier run"
  echo "   removed leftover model $stale"
done

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

second_port=${SCHERMES_SMOKE_SECOND_PORT:-7778}
# The second daemon runs one loop at a time, which is what lets the run hit the cap on purpose.
# Caps are per process, so the daemon on $base is unaffected and keeps its own.
second_max_loops=1
second_pidfile=/tmp/schermes-smoke-daemon.pid

say "agent names that could reach a shell are refused"
for bad in 'Smoke' 'has space' '../escape' '$(id)' '-leading-dash'; do
  req POST /api/agents "$(jq -nc --arg n "$bad" '{name: $n}')"
  expect 400 "invalid name $bad"
done
echo "   all refused with 400"

say "creating $agent_one and $agent_two"
# Born with a profile, or the daemon would open each thread with an interview turn against a
# provider that is not there yet, and the transcripts below would carry that failure.
for agent in "$agent_one" "$agent_two"; do
  req POST /api/agents "$(jq -nc --arg n "$agent" '{name: $n, profile: "A smoke-test agent."}')"
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

# A label is what the owner calls an agent: free text, renamable, and never the identity. Set
# here rather than at creation so a re-run over an existing agent checks the same thing.
say "renaming $agent_one does not move the name it runs as"
req PATCH "/api/agents/$agent_one" "$(jq -nc '{label: "Smoke 🔥 Één"}')"
expect 200 "rename"
jq -e --arg a "$agent_one" '.label == "Smoke 🔥 Één" and .name == $a' "$tmp/body" >/dev/null \
  || fail "the label did not round-trip: $(body)"
req GET "/api/agents/$agent_one"
jq -e '.label == "Smoke 🔥 Één"' "$tmp/body" >/dev/null || fail "the label was not kept: $(body)"
req PATCH "/api/agents/$agent_one" '{"label": "   "}'
expect 400 "an empty label"
req PATCH /api/agents/nobody '{"label": "Ghost"}'
expect 404 "renaming a missing agent"
echo "   renamed, and $agent_one still runs as agent-$agent_one"

say "a look the app picks for $agent_one is kept by the daemon for every device"
req PATCH "/api/agents/$agent_one" '{"look": "cloud:teal"}'
expect 200 "set a look"
req GET "/api/agents/$agent_one"
jq -e '.look == "cloud:teal" and .label == "Smoke 🔥 Één"' "$tmp/body" >/dev/null \
  || fail "the look was not kept beside the label: $(body)"
req PATCH "/api/agents/$agent_one" '{}'
expect 400 "a change with nothing in it"

say "a file handed to $agent_one lands in its home, owned by it"
req POST "/api/agents/$agent_one/uploads" \
  "$(jq -nc --arg b "$(printf 'smoke upload' | base64)" '{name: "smoke note.txt", base64: $b}')"
expect 201 "upload"
upload_path=$(jq -r '.path' "$tmp/body")
[ "$(in_container sudo -u "agent-$agent_one" cat "$upload_path" | tr -d '\r')" = "smoke upload" ] \
  || fail "the upload did not land at $upload_path"
[ "$(in_container stat -c %U "$upload_path" | tr -d '\r')" = "agent-$agent_one" ] \
  || fail "the upload is not owned by agent-$agent_one"
req POST "/api/agents/$agent_one/uploads" '{"name": "../etc/passwd", "base64": "aGk="}'
expect 400 "a name with a path in it"
echo "   $upload_path"

say "the owner reads and rewrites $agent_one's memory as the agent"
req PUT "/api/agents/$agent_one/memory" '{"lasting": "- the smoke run was here\n"}'
expect 200 "write memory"
req GET "/api/agents/$agent_one/memory"
expect 200 "read memory"
jq -e '.lasting == "- the smoke run was here\n"' "$tmp/body" >/dev/null \
  || fail "memory did not round-trip: $(body)"
[ "$(in_container stat -c %U "/home/agent-$agent_one/memory/MEMORY.md" | tr -d '\r')" = "agent-$agent_one" ] \
  || fail "MEMORY.md is not owned by agent-$agent_one"

say "stopping an agent that is not running is a plain no"
req POST "/api/agents/$agent_one/stop"
expect 200 "stop while idle"
jq -e '.stopped == false' "$tmp/body" >/dev/null || fail "nothing was running: $(body)"
req POST /api/agents/nobody/stop
expect 404 "stop a missing agent"

# Before anything below runs, not in the section that creates one: a schedule left behind by an
# interrupted run fires every tick, and a turn starting under its own steam in the middle of the
# loop-cap or human-takeover sections is a confusing failure a long way from its cause.
say "no scheduled task is left over from an earlier run"
for agent in "$agent_one" "$agent_two"; do
  req GET "/api/agents/$agent/schedules"
  expect 200 "list $agent's schedules"
  for stale in $(jq -r '.[].id' "$tmp/body"); do
    req DELETE "/api/agents/$agent/schedules/$stale"
    expect 200 "remove schedule $stale, left behind by an earlier run"
    echo "   removed a leftover schedule from $agent"
  done
  req GET "/api/agents/$agent/triggers"
  expect 200 "list $agent's triggers"
  for stale in $(jq -r '.[].id' "$tmp/body"); do
    req POST "/api/triggers/$stale" '{"action":"delete"}'
    expect 200 "remove trigger $stale, left behind by an earlier run"
    echo "   removed a leftover trigger from $agent"
  done
done

# ---------------------------------------------------------------- the model registry

say "a second model joins the registry and its key never comes back"
req GET /api/models
expect 200 "list models"
first_default=$(jq -r '[.[] | select(.isDefault)][0].id // empty' "$tmp/body")
[ -n "$first_default" ] || fail "the settings round-trip left no default model: $(body)"
# The endpoint and its key belong to a provider; a model names one.
req POST /api/providers \
  "$(jq -nc --arg n "$registry_name" --arg u "$base_url" --arg k "$registry_key" '{name: $n, baseUrl: $u, apiKey: $k}')"
expect 201 "create a provider"
grep -q shouldnevershowup "$tmp/body" && fail "the new provider's key came back in the create response"
registry_provider=$(jq -r '.id' "$tmp/body")
req POST /api/models \
  "$(jq -nc --arg n "$registry_name" --arg m "$model-registry" --argjson p "$registry_provider" \
     '{name: $n, model: $m, providerId: $p}')"
expect 201 "create a model"
grep -q shouldnevershowup "$tmp/body" && fail "the new model's key came back in the create response"
registry_id=$(jq -r '.id' "$tmp/body")
jq -e '.apiKeySet == true and .isDefault == false' "$tmp/body" >/dev/null \
  || fail "the new model should have a key set and not be the default: $(body)"
req GET /api/models
expect 200 "list models with the new one"
grep -q shouldnevershowup "$tmp/body" && fail "a key came back in the model listing"
jq -e --argjson id "$registry_id" 'any(.[]; .id == $id and .apiKeySet)' "$tmp/body" >/dev/null \
  || fail "the listing does not show model $registry_id with its key set: $(body)"
echo "   model $registry_id listed with apiKeySet only"

say "the default and the backup move, and the settings read the default"
req PUT /api/models/default "{\"id\":$registry_id}"
expect 200 "make the new model the default"
jq -e --argjson id "$registry_id" '[.[] | select(.isDefault) | .id] == [$id]' "$tmp/body" >/dev/null \
  || fail "model $registry_id is not the one default: $(body)"
req GET /api/settings
expect 200 "settings with the new default"
jq -e --arg m "$model-registry" '.model == $m' "$tmp/body" >/dev/null \
  || fail "the settings do not read the new default: $(body)"
req PUT /api/models/backup "{\"id\":$first_default}"
expect 200 "make the old default the backup"
jq -e --argjson id "$first_default" '[.[] | select(.isBackup) | .id] == [$id]' "$tmp/body" >/dev/null \
  || fail "model $first_default is not the backup: $(body)"
req PUT /api/models/backup '{"id":null}'
expect 200 "no backup"
jq -e 'all(.[]; .isBackup | not)' "$tmp/body" >/dev/null || fail "a backup is still set: $(body)"
# Back before anything below: the stub and the rebuild checks write and read "the default".
req PUT /api/models/default "{\"id\":$first_default}"
expect 200 "put the default back"
echo "   default and backup moved, and put back"

say "a model an agent uses cannot be deleted"
req PUT "/api/agents/$agent_one/model" "{\"id\":$registry_id}"
expect 200 "assign the new model to $agent_one"
jq -e --argjson id "$registry_id" '.modelId == $id' "$tmp/body" >/dev/null \
  || fail "$agent_one is not on model $registry_id: $(body)"
req DELETE "/api/models/$registry_id"
expect 409 "delete a model in use"
jq -e --arg a "$agent_one" '.error | test($a + ".* still use")' "$tmp/body" >/dev/null \
  || fail "the refusal does not name $agent_one: $(body)"
req PUT "/api/agents/$agent_one/model" '{"id":null}'
expect 200 "put $agent_one back on the default"
jq -e 'has("modelId") | not' "$tmp/body" >/dev/null || fail "$agent_one still has a model: $(body)"
req DELETE "/api/models/$registry_id"
expect 200 "delete the unused model"
req DELETE "/api/providers/$registry_provider"
expect 200 "delete its provider"
echo "   409 while $agent_one used it, deleted once it did not"

if [ "$harness" = true ]; then
  compose logs --no-color schermes 2>/dev/null | grep -q shouldnevershowup \
    && fail "a model key appears in the daemon log"
fi

# ---------------------------------------------------------------- rules

say "the owner reads and sets $agent_one's rules, and passwords stay the owner's"
req PUT "/api/agents/$agent_one/rules" '{"levels":{"delete_files":"ask_first"},"preApproved":{"browse":[]}}'
expect 200 "set $agent_one's rules"
req GET "/api/agents/$agent_one/rules"
expect 200 "read $agent_one's rules"
jq -e '.levels.delete_files == "ask_first" and .levels.passwords_security == "hand_to_you" and .preApproved == {}' \
  "$tmp/body" >/dev/null || fail "the rules did not round-trip: $(body)"
req PUT "/api/agents/$agent_one/rules" '{"levels":{"passwords_security":"on_its_own"}}'
expect 400 "hand passwords to the agent"
req PUT "/api/agents/$agent_one/rules" '{"preApproved":{"browse":["Example.com","example.com"]}}'
expect 200 "a pre-approved site"
jq -e '.preApproved == {"browse": ["example.com"]}' "$tmp/body" >/dev/null || fail "the list was not lowercased and deduped: $(body)"
req PUT "/api/agents/$agent_one/rules" '{"preApproved":{"browse":[]}}'
expect 200 "clear the list"
echo "   Ask first for deletes, passwords refused, the list lowercased and deduped"

if [ "$harness" != true ]; then
  printf '\nOK: health, setup, login, auth guard, settings, the model registry, rules and the agents API\n'
  printf '    all behave (skipped, as they need the docker compose service: desktops, agent turns, the\n'
  printf '    rules refusal, approvals and Needs you, the webhook trigger and search)\n'
  exit 0
fi

xvnc_pid() { in_container sh -c "pgrep -u agent-$1 -f 'Xvnc :$2( |\$)' | head -1" | tr -d '\r'; }

vnc_socket() {
  in_container ss -ltnH "sport = :$((5900 + $1))" | awk '{print $4}' | head -1 | tr -d '\r'
}

wm_pid() { in_container sh -c "pgrep -u agent-$1 -f openbox | head -1" | tr -d '\r'; }

# Openbox is forked about a second after Xvnc answers, so a probe that stopped at the X server
# would land in that gap on roughly every other run.
wait_desktop() {
  local name=$1 display=$2 _
  for _ in $(seq 90); do
    [ -n "$(xvnc_pid "$name" "$display")" ] && [ -n "$(vnc_socket "$display")" ] \
      && [ -n "$(wm_pid "$name")" ] && return 0
    sleep 1
  done
  [ -z "$(xvnc_pid "$name" "$display")" ] || fail "agent $name has an X server on :$display but no window manager after 90s"
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
stub_port=${SCHERMES_SMOKE_STUB_PORT:-7790}
stub_pidfile=/tmp/schermes-smoke-stub.pid

stop_stub() {
  in_container sh -c \
    "if [ -f $stub_pidfile ]; then kill \$(cat $stub_pidfile) 2>/dev/null; fi
     rm -f $stub_pidfile
     exit 0"
}

stop_second_daemon() {
  in_container sh -c \
    "if [ -f $second_pidfile ]; then kill \$(cat $second_pidfile) 2>/dev/null; fi
     rm -f $second_pidfile
     exit 0"
}
cleanup() { stop_second_daemon >/dev/null 2>&1 || true; stop_stub >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

spawn_second_daemon() {
  stop_second_daemon
  : > "$tmp/reconcile.log"
  compose exec -T schermes sh -c \
    "echo \$\$ > $second_pidfile
     exec setpriv --reuid schermes --regid schermes --init-groups \
       env HOME=/var/lib/schermes USER=schermes LOGNAME=schermes SCHERMES_PORT=$second_port \
       SCHERMES_MAX_LOOPS=$second_max_loops \
       node /opt/schermes/daemon/src/main.ts" >"$tmp/reconcile.log" 2>&1 &
  second_client=$!
}

# Waits for the second daemon to log a line at least $2 times. Its log is the only view of it.
await_log() {
  local pattern=$1 want=$2 _
  for _ in $(seq 90); do
    [ "$(grep -c "$pattern" "$tmp/reconcile.log" || true)" -ge "$want" ] && return 0
    sleep 1
  done
  return 1
}

reconcile() {
  spawn_second_daemon
  await_log 'desktop reconciled' 2 || grep -q 'desktop reconciled' "$tmp/reconcile.log" \
    || fail "the second daemon reconciled nothing — $(cat "$tmp/reconcile.log")"
  stop_second_daemon
  wait "$second_client" 2>/dev/null || true
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

# ---------------------------------------------------------------- the tool layer

computer() {
  req POST "/api/agents/$agent_one/computer" "$1"
}

run_cmd() {
  local cmd=$1 timeout=${2:-120000} background=${3:-false}
  req POST "/api/agents/$agent_one/command" \
    "$(jq -nc --arg c "$cmd" --argjson t "$timeout" --argjson b "$background" \
       '{command: $c, timeoutMs: $t, background: $b}')"
}

screenshot() {
  computer '{"action":"screenshot"}'
  expect 200 "screenshot"
  jq -r '.image.base64' "$tmp/body"
}

# Polls a command until it succeeds. Used instead of a flat sleep for anything the X server
# does asynchronously, like mapping a new window.
until_ok() {
  local cmd=$1 tries=${2:-30} _
  for _ in $(seq "$tries"); do
    run_cmd "$cmd" 10000
    jq -e '.exitCode == 0' "$tmp/body" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# A run that died with the mouse held would gate every computer action in the next one, and the
# hold lives in the daemon process rather than in a row, so clear it before driving a display.
say "nobody is holding a desktop from an earlier run"
for agent in "$agent_one" "$agent_two"; do
  req DELETE "/api/agents/$agent/control"
  expect 200 "release control of $agent"
done

say "the tool routes refuse what they cannot make sense of"
req POST "/api/agents/nobody/computer" '{"action":"screenshot"}'
expect 404 "computer on an unknown agent"
req POST "/api/agents/nobody/command" '{"command":"id"}'
expect 404 "command on an unknown agent"
computer '{"action":"explode"}'
expect 400 "unknown action"
computer '{"action":"move","x":99999,"y":0}'
expect 400 "out-of-range coordinates"
computer '{"action":"key","keys":"ctrl+l; rm -rf /"}'
expect 400 "a keystroke that is not a keystroke"
run_cmd ""
expect 400 "an empty command"
req POST "/api/agents/$agent_one/command" '{"command":"id","timeoutMs":0}'
expect 400 "a timeout below the floor"
echo "   404s and 400s all behave"

proof=.schermes-typed-proof
say "resetting $agent_one's desktop so the run is repeatable"
run_cmd "pkill -x xterm || true; rm -f ~/$proof"
expect 200 "reset"
sleep 2

say "screenshot of the bare desktop"
shot_bare=$(screenshot)
case $shot_bare in
  iVBORw0KGgo*) echo "   ${#shot_bare} base64 chars, PNG magic present" ;;
  *) fail "the screenshot is not a PNG (starts with ${shot_bare:0:16})" ;;
esac

say "launching xterm in the background returns immediately"
started=$(date +%s)
run_cmd 'xterm -geometry 80x24+40+40' 5000 true
expect 200 "background xterm"
jq -e '.background == true and .exitCode == 0 and .stdout == ""' "$tmp/body" >/dev/null \
  || fail "the background launch did not report as backgrounded: $(body)"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 5 ] || fail "a background command took ${elapsed}s to return"
echo "   returned in ${elapsed}s"

until_ok 'xdotool search --onlyvisible --class xterm' \
  || fail "xterm never mapped a window on $agent_one's desktop"
# Keyboard actions go to the display, not to a window, so the target must hold focus first.
until_ok 'xdotool search --onlyvisible --class xterm windowactivate --sync %1' \
  || fail "could not activate the xterm window"

say "the new window visibly changed the desktop"
shot_xterm=$(screenshot)
[ "$shot_xterm" != "$shot_bare" ] || fail "the screenshot did not change after xterm opened"
echo "   ${#shot_bare} -> ${#shot_xterm} base64 chars, and the images differ"

say "typed keystrokes reach the focused window"
computer "$(jq -nc --arg t "touch ~/$proof" '{action: "type", text: $t}')"
expect 200 "type"
computer '{"action":"key","keys":"Return"}'
expect 200 "key"
until_ok "test -f ~/$proof" || fail "typing never produced ~/$proof, so the keys went nowhere"
echo "   ~/$proof exists, so the keystrokes landed in the shell running in xterm"

shot_typed=$(screenshot)
[ "$shot_typed" != "$shot_xterm" ] || fail "the screenshot did not change after typing"
[ "${#shot_typed}" -gt 5000 ] || fail "the screenshot looks blank (${#shot_typed} base64 chars)"

say "mouse actions are accepted by the display"
computer '{"action":"move","x":640,"y":400}'
expect 200 "move"
computer '{"action":"click","x":640,"y":400,"button":1}'
expect 200 "click"
computer '{"action":"drag","x":100,"y":100,"toX":300,"toY":300}'
expect 200 "drag"
computer '{"action":"scroll","x":640,"y":400,"direction":"down","amount":2}'
expect 200 "scroll"
echo "   move, click, drag and scroll all accepted"

say "the corner of the model's view is the corner of the display"
read -r view_w view_h <<<"$(screenshot | in_container sh -c 'base64 -d | identify -format "%w %h" png:-')"
run_cmd 'xdpyinfo | awk "/dimensions:/ {print \$2}" | tr x " "'
expect 200 "measure the display"
read -r display_w display_h <<<"$(jq -r .stdout "$tmp/body")"
computer "$(jq -nc --argjson x $((view_w - 1)) --argjson y $((view_h - 1)) '{action: "move", x: $x, y: $y}')"
expect 200 "move to the corner"
run_cmd 'xdotool getmouselocation --shell | head -2 | paste -sd " "'
landed=$(jq -r .stdout "$tmp/body")
[ "$landed" = "X=$((display_w - 1)) Y=$((display_h - 1))" ] \
  || fail "the ${view_w}x${view_h} view's corner landed at '$landed' on a ${display_w}x${display_h} display"
echo "   ${view_w}x${view_h} view, ${display_w}x${display_h} display, corner to corner"

say "the clipboard round-trips"
clip="schermes-clip-$$-$(date +%s)"
computer "$(jq -nc --arg t "$clip" '{action: "clipboard_write", text: $t}')"
expect 200 "clipboard write"
computer '{"action":"clipboard_read"}'
expect 200 "clipboard read"
jq -e --arg c "$clip" '.text == $c' "$tmp/body" >/dev/null \
  || fail "the clipboard did not round-trip: $(body)"
echo "   read back $clip"

say "a command reports its output and its exit code"
run_cmd 'echo hello-stdout; echo hello-stderr >&2; exit 3'
expect 200 "command with a non-zero exit"
jq -e '.exitCode == 3 and .timedOut == false
       and (.stdout | contains("hello-stdout"))
       and (.stderr | contains("hello-stderr"))' "$tmp/body" >/dev/null \
  || fail "the command result is wrong: $(body)"
echo "   exit 3 reported as data, not as an error"

say "the agent can create and edit a file in its workspace"
run_cmd 'printf "one\n" > ~/workspace/smoke.txt && sed -i s/one/two/ ~/workspace/smoke.txt && cat ~/workspace/smoke.txt'
expect 200 "file edit"
jq -e '.exitCode == 0 and (.stdout | contains("two"))' "$tmp/body" >/dev/null \
  || fail "the file was not created and edited: $(body)"

say "a command that outruns its timeout is killed, children and all"
started=$(date +%s)
run_cmd 'sleep 300 | cat' 3000
expect 200 "timed-out command"
elapsed=$(( $(date +%s) - started ))
jq -e '.timedOut == true and .exitCode == 124' "$tmp/body" >/dev/null \
  || fail "the command was not reported as timed out: $(body)"
[ "$elapsed" -le 20 ] || fail "the timeout took ${elapsed}s to fire"
# `timeout` signals the whole process group, so the sleep must be gone too. Matched by process
# name so the bash wrapper carrying the same text in its cmdline cannot be mistaken for it.
sleep 2
run_cmd 'pgrep -u $(id -un) -x sleep | wc -l'
expect 200 "leftover sleep count"
jq -e '(.stdout | ltrimstr(" ") | tonumber) == 0' "$tmp/body" >/dev/null \
  || fail "the timeout left a child process behind: $(body)"
echo "   killed after ${elapsed}s with nothing left running"

say "the agent can install a package with apt-get"
run_cmd 'sudo -n apt-get update -qq && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y hello' 300000
expect 200 "apt-get install"
jq -e '.exitCode == 0' "$tmp/body" >/dev/null || fail "apt-get install failed: $(body)"
run_cmd 'hello' 10000
expect 200 "run the installed package"
jq -e '.exitCode == 0 and (.stdout | test("Hello"))' "$tmp/body" >/dev/null \
  || fail "the installed package does not run: $(body)"
echo "   installed hello and ran it"

# ---------------------------------------------------------------- the sandbox

run_on() {
  local agent=$1 cmd=$2 timeout=${3:-120000} background=${4:-false}
  req POST "/api/agents/$agent/command" \
    "$(jq -nc --arg c "$cmd" --argjson t "$timeout" --argjson b "$background" \
       '{command: $c, timeoutMs: $t, background: $b}')"
}

say "agents have no host sudo, and the daemon is an agent only through its sandbox"
desktop_dir=/opt/schermes/infra/desktop
in_container test ! -e /etc/sudoers.d/agents || fail "/etc/sudoers.d/agents still grants host root"
in_container sh -c "! grep -rqsE '^[[:space:]]*%agents' /etc/sudoers /etc/sudoers.d" \
  || fail "a host sudoers rule still grants %agents: $(in_container sh -c "grep -rsE '^[[:space:]]*%agents' /etc/sudoers /etc/sudoers.d")"
in_container runuser -u "agent-$agent_one" -- sudo -n true >/dev/null 2>&1 \
  && fail "agent-$agent_one has passwordless sudo outside its sandbox"
in_container runuser -u schermes -- sudo -n -u "agent-$agent_one" id >/dev/null 2>&1 \
  && fail "the daemon can still run anything as agent-$agent_one"
in_container runuser -u schermes -- sudo -n /usr/bin/apt-get --version >/dev/null 2>&1 \
  && fail "the daemon can still run apt-get as root"
[ "$(in_container runuser -u schermes -- sudo -n -u "agent-$agent_one" "$desktop_dir/sandbox.sh" enter id -u | tr -d '\r')" \
  = "$(in_container id -u "agent-$agent_one" | tr -d '\r')" ] \
  || fail "the daemon cannot run a command in $agent_one's sandbox"
echo "   no %agents grant; the daemon gets a refusal for a bare command and apt-get, and a shell through enter"

say "an agent's desktop and its commands run in a user namespace of their own"
container_ns=$(in_container readlink /proc/self/ns/user | tr -d '\r')
xvnc_ns=$(in_container runuser -u "agent-$agent_one" -- readlink "/proc/$(xvnc_pid "$agent_one" "$display_one")/ns/user" | tr -d '\r')
run_cmd 'readlink /proc/self/ns/user' 10000
expect 200 "the namespace of a command"
command_ns=$(jq -r '.stdout' "$tmp/body" | tr -d '\n')
[ -n "$xvnc_ns" ] && [ "$xvnc_ns" != "$container_ns" ] || fail "Xvnc runs in the container's userns ($xvnc_ns)"
[ "$command_ns" = "$xvnc_ns" ] || fail "a command ran in $command_ns, not in the sandbox's $xvnc_ns"
echo "   container $container_ns; Xvnc and a command both $xvnc_ns"

say "from inside $agent_one's sandbox the daemon, its secrets and $agent_two are out of reach"
daemon_port=$(in_container printenv SCHERMES_PORT | tr -d '\r')
daemon_pid=$(in_container pgrep -u schermes -o -f 'daemon/src/main.ts' | tr -d '\r')
container_ip=$(in_container sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" | tr -d '\r')
gateway=$(in_container sh -c "ip route | awk '/^default/ {print \$3; exit}'" | tr -d '\r')
vnc_two=$((5900 + display_two)) cdp_two=$((9222 + display_two))
xvnc_two=$(xvnc_pid "$agent_two" "$display_two")
# Each denial below is only worth something if the thing is there and reachable from outside.
in_container test -s /var/lib/schermes/master.key || fail "no master.key to be denied"
in_container test -s /var/lib/schermes/schermes.db || fail "no database to be denied"
in_container test -d "/home/agent-$agent_two/memory" || fail "$agent_two has no home to be denied"
[ -n "$daemon_pid" ] && [ -n "$xvnc_two" ] && [ -n "$container_ip" ] && [ -n "$gateway" ] \
  || fail "could not find the daemon ($daemon_pid), $agent_two's Xvnc ($xvnc_two), the IP ($container_ip) or the gateway ($gateway)"
[ "$(in_container bash -c "exec 3<>/dev/tcp/127.0.0.1/$vnc_two; head -c 3 <&3" | tr -d '\r')" = RFB ] \
  || fail "$agent_two's VNC does not answer on the container loopback"
in_container curl -fsS -o /dev/null "http://127.0.0.1:$cdp_two/json/version" 2>/dev/null \
  || run_on "$agent_two" "python3 -m http.server $cdp_two --bind 127.0.0.1" 10000 true
for _ in $(seq 20); do
  [ "$(in_container curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$cdp_two/" | tr -d '\r')" != 000 ] && break
  sleep 0.5
done
[ "$(in_container curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$cdp_two/" | tr -d '\r')" != 000 ] \
  || fail "nothing answers on $agent_two's CDP port $cdp_two from the container loopback"
read -r -d '' probe <<PROBE || true
leaks=0
denied() {
  local what=\$1; shift
  if timeout 5 "\$@" >/dev/null 2>&1; then echo "LEAK: \$what"; leaks=\$((leaks + 1)); else echo "ok (denied): \$what"; fi
}
denied 'master.key as the agent' cat /var/lib/schermes/master.key
denied 'master.key as sandbox root' sudo -n cat /var/lib/schermes/master.key
denied 'the database as the agent' cat /var/lib/schermes/schermes.db
denied 'the database as sandbox root' sudo -n cat /var/lib/schermes/schermes.db
denied 'the database through the daemon root' cat /proc/$daemon_pid/root/var/lib/schermes/schermes.db
denied 'the database through the daemon root, as sandbox root' sudo -n cat /proc/$daemon_pid/root/var/lib/schermes/schermes.db
denied 'the daemon fds' ls /proc/$daemon_pid/fd
denied 'the daemon fds, as sandbox root' sudo -n ls /proc/$daemon_pid/fd
denied '$agent_two home' ls /home/agent-$agent_two
denied '$agent_two home, as sandbox root' sudo -n ls /home/agent-$agent_two
denied '$agent_two memory, as sandbox root' sudo -n cat /home/agent-$agent_two/memory/MEMORY.md
denied '$agent_two root through its Xvnc, as sandbox root' sudo -n ls /proc/$xvnc_two/root/
for host in 127.0.0.1 $container_ip $gateway; do
  for port in $vnc_two $cdp_two; do denied "$agent_two port \$port via \$host" bash -c "exec 3<>/dev/tcp/\$host/\$port"; done
done
for host in 127.0.0.1 $container_ip; do denied "the daemon port via \$host" bash -c "exec 3<>/dev/tcp/\$host/$daemon_port"; done
code=\$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$gateway:$daemon_port/api/settings)
case \$code in
  000|401) echo "ok: the daemon port via the gateway answers \$code, as it does any network client" ;;
  *) echo "LEAK: the daemon port via the gateway answers \$code"; leaks=\$((leaks + 1)) ;;
esac
exit \$leaks
PROBE
run_cmd "$probe" 120000
expect 200 "the isolation probe"
jq -r '.stdout' "$tmp/body" | sed 's/^/   /'
jq -e '.exitCode == 0' "$tmp/body" >/dev/null || fail "$agent_one reached something it must not: $(body)"
run_on "$agent_two" "pkill -f 'http.server $cdp_two'; true" 10000

# A pre-existing agent is one made before the sandbox: a plain useradd user with useradd's own
# subordinate-id line, a home, a Chromium profile and memory. Creating the agent through the API
# is the same create-agent-user.sh pass boot runs over every agent.
legacy=smoke-legacy
legacy_home=/home/agent-$legacy

say "an agent made before the sandbox moves into one with its home, Chromium profile and memory"
req DELETE "/api/agents/$legacy"
in_container "$desktop_dir/delete-agent-user.sh" "$legacy" >/dev/null
in_container useradd --create-home --shell /bin/bash --groups agents "agent-$legacy"
for file in /etc/subuid /etc/subgid; do
  in_container sh -c "grep -q '^agent-$legacy:' $file || echo 'agent-$legacy:100000:65536' >> $file"
done
legacy_note="- remembered before the sandbox $$"
in_container runuser -u "agent-$legacy" -- sh -c "mkdir -p ~/memory && printf '%s\n' '$legacy_note' > ~/memory/MEMORY.md"
in_container runuser -u "agent-$legacy" -- sh -c \
  'cd && chromium --headless --no-first-run --user-data-dir=$HOME/.chromium-profile --dump-dom about:blank >/dev/null 2>&1; echo legacy > ~/.chromium-profile/smoke-marker'
in_container test -s "$legacy_home/.chromium-profile/Local State" || fail "the legacy Chromium wrote no profile"
profile_sum() { echo "cd \"\$HOME/.chromium-profile\" && find . -type f ! -name 'Singleton*' -print0 | sort -z | xargs -0 sha256sum | sha256sum"; }
legacy_sum=$(in_container runuser -u "agent-$legacy" -- bash -c "$(profile_sum)" | tr -d '\r')
legacy_uid=$(in_container id -u "agent-$legacy" | tr -d '\r')

req POST /api/agents "$(jq -nc --arg n "$legacy" '{name: $n, profile: "A smoke-test agent from before the sandbox."}')"
expect 201 "adopt the legacy user as an agent"
legacy_block=$(in_container cat "/var/lib/schermes-sandboxes/$legacy/subid" | tr -d '\r')
[ "$(in_container grep -c "^agent-$legacy:" /etc/subuid | tr -d '\r')" = 1 ] \
  && in_container grep -qx "agent-$legacy:$legacy_block:65536" /etc/subuid \
  || fail "useradd's subuid line was not replaced by the recorded block $legacy_block"
[ "$legacy_block" != "$(in_container cat "/var/lib/schermes-sandboxes/$agent_one/subid" | tr -d '\r')" ] \
  || fail "the legacy agent shares $agent_one's subuid block"
run_on "$legacy" "id -u; readlink /proc/self/ns/user; $(profile_sum)" 30000
expect 200 "read the migrated profile"
read -r inside_uid inside_ns inside_sum <<<"$(jq -r '.stdout' "$tmp/body" | awk '{print $1}' | tr '\n' ' ')"
[ "$inside_uid" = "$legacy_uid" ] || fail "the legacy agent runs as $inside_uid inside, not $legacy_uid"
[ "$inside_ns" != "$container_ns" ] || fail "the legacy agent's commands are not sandboxed"
[ "$inside_sum" = "${legacy_sum%% *}" ] || fail "the Chromium profile changed in the move: $(body)"
req GET "/api/agents/$legacy/memory"
expect 200 "the legacy agent's memory"
jq -e --arg n "$legacy_note" '.lasting | contains($n)' "$tmp/body" >/dev/null || fail "the memory did not survive: $(body)"
# Without DISPLAY: with a live X display, headless Chromium prints the page and then never exits.
run_on "$legacy" 'env -u DISPLAY chromium --headless --no-first-run --user-data-dir=$HOME/.chromium-profile --dump-dom about:blank 2>/dev/null' 60000
jq -e '.exitCode == 0 and (.stdout | contains("<html"))' "$tmp/body" >/dev/null \
  || fail "Chromium in the sandbox does not open the migrated profile: $(body)"
echo "   uid $legacy_uid, block $legacy_block, profile $inside_sum unchanged, memory kept, Chromium opens it"

say "deleting an agent removes its user, home and sandbox, with the daemon racing it"
run_on "$legacy" 'echo kept > ~/workspace/keep.txt && sudo -n touch /etc/smoke-layer-marker' 30000
jq -e '.exitCode == 0' "$tmp/body" >/dev/null || fail "could not write into the legacy sandbox: $(body)"
in_container test -e "/var/lib/schermes-sandboxes/$legacy/upper/etc/smoke-layer-marker" \
  || fail "the sandbox write did not land in the layer"
# The daemon's own route into a sandbox, the one search, idle and triggers take, run flat out:
# any start landing between the stop and the userdel would leave a sandbox behind.
in_container rm -f /tmp/smoke-hammer.stop /tmp/smoke-hammer.pid
compose exec -d -T schermes runuser -u schermes -- sh -c \
  "echo \$\$ > /tmp/smoke-hammer.pid; while [ ! -e /tmp/smoke-hammer.stop ]; do sudo -n -u agent-$legacy $desktop_dir/sandbox.sh enter true >/dev/null 2>&1; done"
for _ in $(seq 20); do in_container test -s /tmp/smoke-hammer.pid && break; sleep 0.2; done
req DELETE "/api/agents/$legacy"
expect 200 "delete the legacy agent"
in_container touch /tmp/smoke-hammer.stop
for _ in $(seq 50); do in_container sh -c 'kill -0 "$(cat /tmp/smoke-hammer.pid)" 2>/dev/null' || break; sleep 0.2; done
in_container id -u "agent-$legacy" >/dev/null 2>&1 && fail "agent-$legacy is still a user"
in_container test ! -e "$legacy_home" || fail "$legacy_home is still there"
in_container test ! -e "/var/lib/schermes-sandboxes/$legacy" || fail "the sandbox layer of $legacy is still there"
in_container sh -c "! grep -q '^agent-$legacy:' /etc/subuid /etc/subgid" || fail "agent-$legacy still has subordinate ids"
left=$(in_container ps -eo pid=,uid=,args= | awk -v uid="$legacy_uid" -v lo="$legacy_block" \
  '$2 == uid || ($2 >= lo && $2 < lo + 65536) || /schermes-sandboxes\/'"$legacy"'\// { print }')
[ -z "$left" ] || fail "processes of the deleted agent are still running:
$left"
echo "   user, home, layer and subid lines gone; nothing left running"

say "an agent recreated under a deleted agent's name starts empty"
req POST /api/agents "$(jq -nc --arg n "$legacy" '{name: $n, profile: "A smoke-test agent, born again."}')"
expect 201 "recreate the legacy agent"
run_on "$legacy" 'ls -A ~ ~/workspace ~/memory ~/.chromium-profile; test ! -e /etc/smoke-layer-marker && echo no-layer-marker' 30000
expect 200 "list the new home"
jq -e '(.stdout | contains("no-layer-marker")) and (.stdout | test("keep.txt|MEMORY.md|smoke-marker|Local State") | not)' \
  "$tmp/body" >/dev/null || fail "the recreated agent inherited something: $(body)"
req GET "/api/agents/$legacy/memory"
jq -e '.lasting == ""' "$tmp/body" >/dev/null || fail "the recreated agent remembers: $(body)"
echo "   an empty home and a fresh layer"

say "a rename with the daemon racing it moves the user and the sandbox"
moved="$legacy-2"
req DELETE "/api/agents/$moved"
in_container "$desktop_dir/delete-agent-user.sh" "$moved" >/dev/null
in_container rm -f /tmp/smoke-hammer.stop /tmp/smoke-hammer.pid
compose exec -d -T schermes runuser -u schermes -- sh -c \
  "echo \$\$ > /tmp/smoke-hammer.pid; while [ ! -e /tmp/smoke-hammer.stop ]; do sudo -n -u agent-$legacy $desktop_dir/sandbox.sh enter true >/dev/null 2>&1; done"
for _ in $(seq 20); do in_container test -s /tmp/smoke-hammer.pid && break; sleep 0.2; done
req PATCH "/api/agents/$legacy" "$(jq -nc --arg n "$moved" '{name: $n}')"
expect 200 "rename while the daemon enters the sandbox"
in_container touch /tmp/smoke-hammer.stop
in_container id -u "agent-$moved" >/dev/null || fail "agent-$moved was not created by the rename"
in_container test -d "/var/lib/schermes-sandboxes/$moved" -a ! -e "/var/lib/schermes-sandboxes/$moved/disabled" \
  || fail "the sandbox layer did not move, or is still marked as retired"
run_on "$moved" 'id -un' 30000
jq -e --arg u "agent-$moved" '.exitCode == 0 and (.stdout | contains($u))' "$tmp/body" >/dev/null \
  || fail "the renamed agent's sandbox does not run commands: $(body)"
req DELETE "/api/agents/$moved"
expect 200 "delete the renamed agent"
in_container id -u "agent-$moved" >/dev/null 2>&1 && fail "agent-$moved is still a user after its delete"
echo "   renamed to $moved, its sandbox back up under the new name, and deleted"

# ---------------------------------------------------------------- the agent loop

# A scripted OpenAI-compatible endpoint on loopback, so the run exercises the real model client
# rather than a fake provider object: screenshot, then a command, then an answer that reports
# what the stub saw in the transcript.
nonce="schermes-loop-$$-$(date +%s)"
stub_model=smoke-stub-model

# Restarts the scripted endpoint with the command it will ask the agent to run, the timeout that
# command gets, and which script every agent follows. A long command parks a turn inside a tool
# call, which is how the run posts to a busy agent and how a daemon gets killed mid tool call.
start_stub() {
  local cmd=$1 timeout_ms=$2 script=${3:-tools} sender=${4:-} to=${5:-} url=${6:-} socket='' _
  stop_stub
  compose exec -d \
    -e STUB_PORT="$stub_port" -e STUB_NONCE="$nonce" -e STUB_CMD="$cmd" \
    -e STUB_CMD_TIMEOUT_MS="$timeout_ms" \
    -e STUB_SCRIPT="$script" -e STUB_SENDER="$sender" -e STUB_TO="$to" -e STUB_URL="$url" \
    schermes sh -c "echo \$\$ > $stub_pidfile
                    exec python3 /opt/schermes/infra/provider-stub.py \"\$STUB_PORT\" \"\$STUB_NONCE\" \"\$STUB_CMD\""
  for _ in $(seq 20); do
    socket=$(in_container ss -ltnH "sport = :$stub_port" | awk '{print $4}' | head -1 | tr -d '\r')
    [ -n "$socket" ] && break
    sleep 1
  done
  [ "$socket" = "127.0.0.1:$stub_port" ] \
    || fail "the stub listens on '${socket:-nothing}', expected 127.0.0.1:$stub_port"
  echo "   listening on $socket"
}

say "serving the scripted model endpoint on 127.0.0.1:$stub_port"
in_container test -f /opt/schermes/infra/provider-stub.py \
  || fail "provider-stub.py is not in the image — rebuild with 'docker compose up -d --build'"
start_stub "echo $nonce; id -un" 30000

say "pointing the provider settings at the stub"
req PUT /api/settings \
  "$(jq -nc --arg u "http://127.0.0.1:$stub_port/v1" --arg m "$stub_model" --arg k "$api_key" \
     '{baseUrl: $u, model: $m, apiKey: $k}')"
expect 200 "settings for the stub"

say "the stored provider settings answer a test call"
req POST /api/settings/test
expect 200 "provider test"
jq -e '.ok == true' "$tmp/body" >/dev/null || fail "the stub did not answer the test: $(body)"

say "a message with no text, and a message to an agent that does not exist, are refused"
req POST "/api/agents/$agent_one/messages" '{"text":"   "}'
expect 400 "an empty message"
req POST /api/agents/nobody/messages '{"text":"hello"}'
expect 404 "a message to an unknown agent"
req GET /api/agents/nobody/events
expect 404 "events for an unknown agent"

req GET "/api/agents/$agent_one/events"
expect 200 "events before the turn"
last_event=$(jq -r '[.[].id] | max // 0' "$tmp/body")

# The newest event of an agent that a settle has already accounted for. Waiting for the owner is
# also the state a turn starts from, and the snapshot before it can take seconds, so a settle is
# only done once a turn has ended past the mark. Seeded here so a re-run ignores the last run's.
mark_turns() { req GET "/api/agents/$1/events?limit=1"; jq -r '.[0].id // 0' "$tmp/body" > "$tmp/mark-$1"; }
mark_turns "$agent_one"
mark_turns "$agent_two"

# Polls until an agent has finished a turn since the last settle and leaves the answer in $state.
# Not a subshell: `fail` has to be able to end the run from in here.
settle() {
  local agent=$1 mark _
  mark=$(cat "$tmp/mark-$agent")
  state=''
  for _ in $(seq 180); do
    req GET "/api/agents/$agent"
    state=$(jq -r '.state' "$tmp/body")
    case $state in
      waiting_for_user|waiting_for_agent)
        req GET "/api/agents/$agent/events?limit=200"
        if jq -e --argjson m "$mark" 'any(.[]; .id > $m and .type == "turn")' "$tmp/body" >/dev/null; then
          jq -r '[.[].id] | max' "$tmp/body" > "$tmp/mark-$agent"
          return 0
        fi
        ;;
      failed)
        req GET "/api/agents/$agent/events?limit=200"
        jq -e --argjson m "$mark" 'any(.[]; .id > $m and .type == "turn")' "$tmp/body" >/dev/null \
          && fail "$agent failed: $(jq -c '[.[] | select(.type == "failure")] | last' "$tmp/body")"
        ;;
    esac
    sleep 1
  done
  fail "$agent is $state and never finished a turn"
}

say "posting a message to $agent_one"
req POST "/api/agents/$agent_one/messages" \
  '{"text":"Look at your screen and tell me who and where you are."}'
expect 202 "post a message"
jq -e '.message.role == "user"' "$tmp/body" >/dev/null || fail "the message was not stored: $(body)"

settle "$agent_one"
[ "$state" = waiting_for_user ] || fail "the agent is $state, expected waiting_for_user"
echo "   the turn finished and the agent is waiting for the user"

say "the transcript records the whole exchange"
# No query string: the default page is the newest end of the thread, which is what the turn
# just wrote. On a database that is no longer wiped between runs the thread keeps growing, and
# this read stays the same size.
req GET "/api/agents/$agent_one/messages"
expect 200 "read the transcript"
grep -q shouldnevershowup "$tmp/body" && fail "the api key appears in the transcript"

jq -e --arg n "$nonce" '
  ([.[] | select(.role == "tool" and .image.mediaType == "image/png"
                 and (.image.base64 | startswith("iVBORw0KGgo")))] | length) >= 1
  and ([.[] | select(.role == "tool" and (.content | contains($n)))] | length) >= 1
  and ([.[] | select(.role == "assistant" and (.toolCalls | length) > 0)] | length) >= 2
' "$tmp/body" >/dev/null \
  || fail "the transcript is missing the screenshot or the command result: $(body)"

answer=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
echo "   the agent answered: $answer"
for want in "nonce=$nonce" "model=$stub_model" 'auth=yes' 'system=yes' 'png=yes' \
            'tools=add_helper,ask_for_hands,ask_owner,browser,cancel_schedule,computer,list_schedules,pause_schedule,propose_trigger,remember,request_approval,request_deletion,request_form,run_command,schedule_task,send_message,set_name,set_profile,spawn_task_worker,update_goal,web_fetch,web_search' 'valid=yes'; do
  case $answer in
    *"$want"*) ;;
    *) fail "the model never saw $want — it reported: $answer" ;;
  esac
done
[ "$(printf '%s' "$answer" | sed -n 's/.*images=\([0-9]*\).*/\1/p')" -ge 1 ] \
  || fail "the screenshot never reached the model: $answer"
[ "$(printf '%s' "$answer" | sed -n 's/.*results=\([0-9]*\).*/\1/p')" -ge 2 ] \
  || fail "both tool results should have been fed back: $answer"
transcript_length=$(jq -r 'length' "$tmp/body")
echo "   $transcript_length messages, screenshot and command output both fed back"

say "the screenshot is stored as a file on the data volume, not in the database"
shot_sha=$(jq -r '[.[] | select(.role == "tool" and .image.mediaType == "image/png" and .image.base64 != "")] | last | .image.base64' "$tmp/body" \
  | in_container sh -c 'base64 -d | sha256sum' | cut -d' ' -f1)
in_container test -f "/var/lib/schermes/images/$(printf '%s' "$shot_sha" | cut -c1-2)/$shot_sha" \
  || fail "no image file named $shot_sha under /var/lib/schermes/images"
counts=$(in_container runuser -u schermes -- sh -c 'cd /opt/schermes/daemon && node --input-type=commonjs -' <<JS | tr -d '\r'
const db = new (require('better-sqlite3'))('/var/lib/schermes/schermes.db', { readonly: true });
const refs = db.prepare("SELECT count(*) AS n FROM messages WHERE json_extract(image_ref, '\$.sha256') = ?").get('$shot_sha').n;
const inline = db.prepare('SELECT count(*) AS n FROM messages WHERE image IS NOT NULL').get().n;
process.stdout.write(refs + ' ' + inline);
JS
)
[ "${counts%% *}" -ge 1 ] 2>/dev/null && [ "${counts##* }" = 0 ] \
  || fail "expected a row naming the screenshot's file and no inline base64 left, got refs/inline: $counts"
echo "   images/$(printf '%s' "$shot_sha" | cut -c1-12)… holds the screenshot; no row carries base64"

say "the events say what the agent did, without the payloads"
req GET "/api/agents/$agent_one/events"
expect 200 "read the events"
grep -q shouldnevershowup "$tmp/body" && fail "the api key appears in the events"
grep -q iVBORw0KGgo "$tmp/body" && fail "a screenshot was written into the event log"

jq -e --argjson since "$last_event" '
  [.[] | select(.id > $since)] as $new
  | ([$new[] | select(.type == "tool_call") | .data.tool] | sort | unique)
      == ["computer", "run_command"]
  and ([$new[] | select(.type == "state") | .data.to])
      == ["thinking", "using_computer", "thinking", "using_terminal", "thinking",
          "waiting_for_user"]
  and ([$new[] | select(.type == "tool_result") | .data.imageBytes | numbers] | length) == 1
  and ([$new[] | select(.type == "tool_result") | .data.exitCode | numbers] | add) == 0
' "$tmp/body" >/dev/null || fail "the event log does not describe the turn: $(body)"
echo "   tool calls, tool results and every state transition are recorded"

say "the thread reads back a page at a time"
req GET "/api/agents/$agent_one/messages"
expect 200 "the default page"
tail_ids=$(jq -c '[.[-2:][].id]' "$tmp/body")
req GET "/api/agents/$agent_one/messages?limit=2"
expect 200 "the newest page"
[ "$(jq -c '[.[].id]' "$tmp/body")" = "$tail_ids" ] \
  || fail "the newest page is not the end of the thread: $(jq -c '[.[].id]' "$tmp/body") vs $tail_ids"
oldest_shown=$(jq -r '.[0].id' "$tmp/body")
req GET "/api/agents/$agent_one/messages?limit=2&before=$oldest_shown"
expect 200 "the page before the newest one"
jq -e --argjson before "$oldest_shown" '
  length >= 1 and ([.[].id] | max) < $before and ([.[].id] | sort) == [.[].id]
' "$tmp/body" >/dev/null || fail "walking backwards did not return older messages: $(body)"
echo "   newest page $tail_ids, then the page before it, each ordered oldest first"
for bad in 'limit=0' 'limit=999' 'before=nope' 'before=1&after=1'; do
  req GET "/api/agents/$agent_one/messages?$bad"
  expect 400 "a read asking for $bad"
done
echo "   a page nobody can serve is a 400"

say "a reader watching the thread asks only for what it has not seen"
# What the UI polls on. An idle poll is an empty array rather than a page of base64 screenshots,
# which is the whole reason the UI can watch a thread on a timer instead of a push channel.
req GET "/api/agents/$agent_one/messages"
expect 200 "the default page"
newest=$(jq -r '.[-1].id' "$tmp/body")
req GET "/api/agents/$agent_one/messages?after=$newest"
expect 200 "a poll with nothing new"
[ "$(jq -c '.' "$tmp/body")" = "[]" ] || fail "a poll at the end of the thread was not empty: $(body)"
req GET "/api/agents/$agent_one/messages?after=$((newest - 2))"
expect 200 "a poll that missed two messages"
jq -e --argjson mark "$((newest - 2))" '
  length >= 1 and ([.[].id] | min) > $mark and ([.[].id] | sort) == [.[].id]
' "$tmp/body" >/dev/null || fail "a poll did not return the rows after the mark: $(body)"
echo "   an idle poll is empty and a late one returns only what came after the mark"

say "the exchange is still there after a rebuild, not just a restart"
# --force-recreate is what makes this a real test: compose leaves a running container alone when
# neither the image nor the config changed. The replacement comes up with an empty /etc/passwd
# and no agent homes, so everything below has to come back out of the /var/lib/schermes volume.
compose up -d --build --force-recreate >/dev/null
wait_health
# The session cookie is a row in that database, so a guarded route answering at all is the first
# thing proving the owner and the sessions came back.
req GET "/api/agents/$agent_one/messages"
expect 200 "read the transcript after the rebuild"
[ "$(jq -r 'length' "$tmp/body")" = "$transcript_length" ] \
  || fail "the transcript changed across the rebuild: $(jq -r 'length' "$tmp/body") messages"
jq -e --arg n "$nonce" '[.[] | select(.content | contains($n))] | length >= 2' "$tmp/body" >/dev/null \
  || fail "the rebuilt daemon lost the exchange"
req GET "/api/agents/$agent_one"
expect 200 "agent state after the rebuild"
jq -e '.state == "waiting_for_user"' "$tmp/body" >/dev/null \
  || fail "the agent state did not survive the rebuild: $(body)"

# The api key is encrypted under master.key, which lives in the same volume. Reading the model
# back proves the settings row survived; every turn below proves the key still decrypts.
req GET /api/settings
expect 200 "settings after the rebuild"
jq -e --arg m "$stub_model" '.model == $m and .apiKeySet == true' "$tmp/body" >/dev/null \
  || fail "the provider settings did not survive the rebuild: $(body)"
echo "   $transcript_length messages, the agent state and the encrypted settings came back"

say "the rebuilt container rebuilds the linux users and desktops from the surviving rows"
assert_desktops

say "a package $agent_one installed with sudo apt-get survived the rebuild"
run_cmd 'hello && dpkg -s hello | grep -qx "Status: install ok installed"' 30000
expect 200 "run hello after the rebuild"
jq -e '.exitCode == 0 and (.stdout | test("Hello"))' "$tmp/body" >/dev/null \
  || fail "hello did not survive the rebuild: $(body)"
echo "   hello still installed and runs, from $agent_one's layer on the sandboxes volume"
# The container took the scripted endpoint down with it, and everything below needs one.
start_stub "echo $nonce; id -un" 30000

# ---------------------------------------------------------------- agents talking

# Every agent has exactly one thread, the one it shares with the owner; agents talk across
# threads (docs/architecture.md, "Messaging"). There are no shared or group threads to open.
say "a thread that does not exist is a 404"
req GET /api/conversations/999999/messages
expect 404 "an unknown conversation"
req GET /api/agents/nobody/messages
expect 404 "the thread of an unknown agent"

say "a message to a busy agent is taken rather than refused"
start_stub 'sleep 8' 30000 busy

reports() {
  req GET "$1"
  jq -r --arg n "$nonce" \
    '[.[] | select(.role == "assistant" and (.content | startswith("nonce=" + $n)))] | length' \
    "$tmp/body"
}
before=$(reports "/api/agents/$agent_one/messages")

req POST "/api/agents/$agent_one/messages" '{"text":"Run something slow please."}'
expect 202 "the first message"

state=''
for _ in $(seq 60); do
  req GET "/api/agents/$agent_one"
  state=$(jq -r '.state' "$tmp/body")
  [ "$state" = using_terminal ] && break
  sleep 1
done
[ "$state" = using_terminal ] || fail "$agent_one is $state, expected it to be inside a command"

req POST "/api/agents/$agent_one/messages" '{"text":"And answer this one as well."}'
expect 202 "a second message while the agent is still in a tool call"
echo "   taken with 202 while $agent_one was $state"

after=$before
for _ in $(seq 90); do
  after=$(reports "/api/agents/$agent_one/messages")
  [ "$after" -ge "$((before + 2))" ] && break
  sleep 1
done
[ "$after" -ge "$((before + 2))" ] \
  || fail "the message posted to a busy agent was never answered ($before -> $after)"
settle "$agent_one"
echo "   both messages answered, $before -> $after turns"

say "$agent_one writes to $agent_two, whose answer comes back to $agent_one and wakes it"
start_stub "echo $nonce; id -un" 30000 talk "$agent_one" "$agent_two"

last_id() { req GET "/api/agents/$1/messages"; jq -r '[.[].id] | max // 0' "$tmp/body"; }
# A fresh agent's thread is empty, and after=0 is not a message id.
thread_since() { req GET "/api/agents/$1/messages$([ "$2" -gt 0 ] && echo "?after=$2")"; }
one_last=$(last_id "$agent_one")
two_last=$(last_id "$agent_two")

req POST "/api/agents/$agent_one/messages" \
  "$(jq -nc --arg b "$agent_two" '{text: ("Ask " + $b + " for its hostname, then tell me.")}')"
expect 202 "the message that starts the exchange"

# The exchange crosses both threads and comes back: $agent_one ends its turn, $agent_two's
# answer lands in $agent_one's thread, and that is what starts $agent_one again.
woken() {
  thread_since "$agent_one" "$one_last"
  jq -e --arg a "$agent_one" --arg b "$agent_two" '
    any(.[]; .role == "assistant" and .sender == $a and (.content | test("heard=[^ ]*" + $b)))
  ' "$tmp/body" >/dev/null
}
for _ in $(seq 120); do woken && break; sleep 1; done
woken || fail "$agent_one was never woken by $agent_two's answer: $(body)"

jq -e --arg b "$agent_two" '
  any(.[]; .role == "user" and .sender == $b and (.content | contains("agent=" + $b)))
' "$tmp/body" >/dev/null || fail "$agent_two's answer is not in $agent_one's thread under its name: $(body)"

thread_since "$agent_two" "$two_last"
expect 200 "$agent_two's thread after the exchange"
jq -e --arg a "$agent_one" --arg n "$nonce" '
  [.[] | select(.role == "user" and .sender == $a and (.content | contains($n)))] | length == 1
' "$tmp/body" >/dev/null || fail "the message $agent_one sent is not in $agent_two's thread under its name: $(body)"
two_said=$(jq -r --arg b "$agent_two" '[.[] | select(.role == "assistant" and .sender == $b)] | last | .content' "$tmp/body")
for want in "agent=$agent_two" 'valid=yes'; do
  case $two_said in *"$want"*) ;; *) fail "$agent_two never saw $want — it reported: $two_said" ;; esac
done
case $two_said in
  *heard=*"$agent_one"*) ;;
  *) fail "$agent_two was not shown the message as coming from $agent_one: $two_said" ;;
esac
echo "   $agent_two answered $agent_one in its own thread, and the answer woke $agent_one"

req GET "/api/agents/$agent_one/events"
expect 200 "the events of the exchange"
jq -e --arg b "$agent_two" \
  '[.[] | select(.type == "tool_result" and .data.to == $b)] | length >= 1' "$tmp/body" \
  >/dev/null || fail "no send_message result is in the history: $(body)"
settle "$agent_one"
settle "$agent_two"

# ---------------------------------------------------------------- task workers

# The worker is answered by the same scripted endpoint as everyone else: it is keyed off the
# `You are <name>,` line, and a worker is told apart by its prompt because its name only exists
# once it has been spawned. Every run spawns another one, so the newest row is this run's.
say "$agent_one hands a job to a task worker, which does it in its own directory"
start_stub "echo $nonce > result.txt; pwd" 30000 worker "$agent_one"

req GET "/api/agents/$agent_one"
expect 200 "the parent before it spawns"
parent_id=$(jq -r '.id' "$tmp/body")

req POST "/api/agents/$agent_one/messages" \
  '{"text":"Hand this job to a task worker, then tell me what it reported."}'
expect 202 "the message that spawns a worker"

settle "$agent_one"
[ "$state" = waiting_for_user ] || fail "$agent_one is $state after the worker exchange"

req GET /api/agents
expect 200 "the agent list with the worker in it"
worker=$(jq -r --argjson p "$parent_id" \
  '[.[] | select(.parentId == $p)] | max_by(.id) | .name // empty' "$tmp/body")
[ -n "$worker" ] || fail "$agent_one never spawned a task worker: $(body)"
worker_state=$(jq -r --arg w "$worker" '.[] | select(.name == $w) | .state' "$tmp/body")
[ "$worker_state" = completed ] || fail "$worker is $worker_state, expected completed"
jq -e '([.[].display] | length) == ([.[].display] | unique | length)' "$tmp/body" >/dev/null \
  || fail "the worker took a display number something else already had: $(body)"

one_home=$(agent_home "$agent_one")
worker_dir="$one_home/workspace/workers/$worker"
in_container test -f "$worker_dir/result.txt" || fail "$worker wrote no file in $worker_dir"
in_container grep -q "$nonce" "$worker_dir/result.txt" \
  || fail "the file in $worker_dir is not the one this run asked for"
file_owner=$(in_container stat -c '%U' "$worker_dir/result.txt" | tr -d '\r')
[ "$file_owner" = "agent-$agent_one" ] \
  || fail "$worker wrote as $file_owner, expected to run as agent-$agent_one"
echo "   $worker completed, and its file in $worker_dir belongs to $file_owner"

say "the worker only ever had the terminal, and its brief was its own thread"
req GET "/api/agents/$worker/messages"
expect 200 "the worker transcript"
jq -e --arg n "$nonce" '.[0].role == "user" and (.[0].content | contains($n))' "$tmp/body" \
  >/dev/null || fail "the brief is not the first thing in the worker thread: $(body)"
jq -e --arg d "$worker_dir" \
  '[.[] | select(.role == "tool" and (.content | contains($d)))] | length >= 1' "$tmp/body" \
  >/dev/null || fail "the worker did not run its command in $worker_dir: $(body)"
worker_said=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
for want in "agent=$worker" 'tools=run_command,web_fetch,web_search' 'valid=yes'; do
  case $worker_said in
    *"$want"*) ;;
    *) fail "the worker never saw $want — it reported: $worker_said" ;;
  esac
done
echo "   one tool, no desktop: $worker was offered run_command and nothing else"

say "the result reached $agent_one, which reported it to the owner"
req GET "/api/agents/$agent_one/messages"
expect 200 "the parent transcript after the worker reported"
jq -e --arg w "$worker" \
  '([.[] | select(.role == "user" and .sender == $w)] | length) >= 1' "$tmp/body" >/dev/null \
  || fail "the worker result never landed in $agent_one's thread: $(body)"
parent_said=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
case $parent_said in
  *"heard="*"$worker"*) ;;
  *) fail "$agent_one was never shown the result as coming from $worker: $parent_said" ;;
esac

req GET "/api/agents/$agent_one/events"
expect 200 "the events of the worker exchange"
jq -e --arg w "$worker" '
  ([.[] | select(.type == "tool_result" and .data.worker == $w)] | length) >= 1
  and ([.[] | select(.type == "state" and .data.to == "waiting_for_task_worker")] | length) >= 1
' "$tmp/body" >/dev/null || fail "the history does not show the worker being spawned: $(body)"
echo "   $agent_one waited on $worker, was woken by its result and answered the owner"

# ---------------------------------------------------------------- human takeover

# Sessions are rows in the shared database, so this cookie works against any daemon on it — the
# probe below runs inside the container, and so does the restart-recovery section further down.
sid=$(awk '$6 == "schermes_session" {print $7}' "$tmp/jar" | tail -1)
[ -n "$sid" ] || fail "no session cookie to reuse inside the container"

# A raw upgrade request rather than a client library, so the assertion is on the bytes. The
# server never masks what it sends, so Xvnc's greeting is readable inside the frame carrying it.
vnc_probe=$(cat <<'JS'
const net = require('node:net');
const cookie = process.env.VNC_COOKIE || '';
const request = [
  'GET ' + process.env.VNC_PATH + ' HTTP/1.1',
  'Host: 127.0.0.1',
  'Upgrade: websocket',
  'Connection: Upgrade',
  'Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==',
  'Sec-WebSocket-Version: 13',
].concat(cookie ? ['Cookie: ' + cookie] : []).concat(['', '']).join('\r\n');

let seen = Buffer.alloc(0);
const socket = net.connect(Number(process.env.VNC_PORT), '127.0.0.1');
const finish = () => {
  console.log(JSON.stringify(seen.toString('latin1')));
  socket.destroy();
  process.exit(0);
};
socket.on('connect', () => socket.write(request));
socket.on('data', (chunk) => {
  seen = Buffer.concat([seen, chunk]);
  const text = seen.toString('latin1');
  if (text.includes('RFB 003.008') || /^HTTP\/1\.1 [45]/.test(text)) finish();
});
socket.on('error', (error) => {
  seen = Buffer.from('socket error: ' + error.message);
  finish();
});
setTimeout(finish, 10000);
JS
)

probe_vnc() {
  compose exec -T -e VNC_PORT="${SCHERMES_PORT:-7777}" -e VNC_PATH="$1" -e VNC_COOKIE="${2:-}" \
    schermes node -e "$vnc_probe" | tr -d '\r'
}

say "the desktop proxy is behind the same session guard as everything else"
anon=$(probe_vnc "/api/agents/$agent_one/vnc")
case $anon in
  *'HTTP/1.1 401'*) echo "   401 without a session" ;;
  *) fail "the vnc proxy answered without a session: $anon" ;;
esac

missing=$(probe_vnc "/api/agents/nobody/vnc" "schermes_session=$sid")
case $missing in
  *'HTTP/1.1 404'*) echo "   404 for an agent that has no desktop" ;;
  *) fail "the vnc proxy did not 404 an unknown agent: $missing" ;;
esac

say "the owner gets $agent_one's real vnc stream through the daemon"
wait_desktop "$agent_one" "$display_one"
stream=$(probe_vnc "/api/agents/$agent_one/vnc" "schermes_session=$sid")
case $stream in
  *'HTTP/1.1 101'*'RFB 003.008'*) echo "   upgraded, and Xvnc's RFB 003.008 came back through it" ;;
  *) fail "no RFB handshake through the proxy: $stream" ;;
esac

say "taking control stands $agent_one's input down"
req GET "/api/agents/$agent_one/control"
expect 200 "control before the takeover"
jq -e '.held == false' "$tmp/body" >/dev/null || fail "$agent_one is already held: $(body)"

req POST "/api/agents/$agent_one/control" '{}'
expect 200 "take control"
jq -e '.held == true' "$tmp/body" >/dev/null || fail "taking control did not hold it: $(body)"

computer '{"action":"screenshot"}'
expect 409 "a computer action while the owner holds the mouse"
case $(body) in
  *'taken control of this desktop'*) echo "   the puppet route stood down too" ;;
  *) fail "the refusal does not say why: $(body)" ;;
esac

# run_command is not input to the display, so a human at the screen does not stop the work.
run_cmd 'id -un'
expect 200 "a command while the owner holds the mouse"
jq -e '.exitCode == 0' "$tmp/body" >/dev/null || fail "the terminal was gated as well: $(body)"

say "$agent_one is refused the display and ends its turn waiting for the owner"
start_stub "echo $nonce; id -un" 30000

req GET "/api/agents/$agent_one/events"
expect 200 "events before the gated turn"
gated_last=$(jq -r '[.[].id] | max // 0' "$tmp/body")

req POST "/api/agents/$agent_one/messages" '{"text":"Take a look at your screen for me."}'
expect 202 "the message that runs into the takeover"

settle "$agent_one"
[ "$state" = waiting_for_user ] || fail "$agent_one is $state, expected waiting_for_user"

req GET "/api/agents/$agent_one/messages"
expect 200 "the gated transcript"
jq -e '[.[] | select(.role == "tool" and (.content | contains("taken control of this desktop")))]
       | length >= 1' "$tmp/body" >/dev/null \
  || fail "the agent was never told the owner has the mouse: $(body)"
jq -e 'last | .role == "tool"' "$tmp/body" >/dev/null \
  || fail "the gated turn did not stop at the refusal: $(body)"

req GET "/api/agents/$agent_one/events"
expect 200 "the events of the takeover"
jq -e --argjson since "$gated_last" '
  [.[] | select(.id > $since)] as $new
  | ([$new[] | select(.type == "tool_result" and .data.error == "control held")] | length) == 1
  and ([$new[] | select(.type == "state") | .data.to] | last) == "waiting_for_user"
' "$tmp/body" >/dev/null || fail "the history does not show the refusal: $(body)"
jq -e '[.[] | select(.type == "control" and .data.held == true)] | length >= 1' "$tmp/body" \
  >/dev/null || fail "the takeover itself is not in the history: $(body)"
echo "   refused, recorded, and $agent_one is waiting for the owner"

say "returning control gives $agent_one its display back"
req DELETE "/api/agents/$agent_one/control"
expect 200 "return control"
jq -e '.held == false' "$tmp/body" >/dev/null || fail "control was not returned: $(body)"

computer '{"action":"screenshot"}'
expect 200 "a computer action after control is returned"
jq -e '.image.base64 | startswith("iVBORw0KGgo")' "$tmp/body" >/dev/null \
  || fail "the screenshot after the handback is not a PNG: $(body)"
echo "   the desktop is the agent's again"

# ---------------------------------------------------------------- restart recovery

# The turn runs on a second daemon so it can be killed outright, mid tool call, the way a crash
# or `systemctl restart` kills one. A `docker compose restart` cannot stand in: it takes the pid
# namespace with it, so nothing would still be holding the interrupted call.

reconciled_from() {
  grep -h 'agent reconciled' "$tmp/reconcile.log" \
    | jq -r --arg a "$1" 'select(.agent == $a) | .from' | tail -1
}

say "parking $agent_two inside a command that will not return"
wait_desktop "$agent_two" "$display_two"
start_stub 'sleep 600' 600000

req GET "/api/agents/$agent_two/events"
expect 200 "events before the interrupted turn"
two_last_event=$(jq -r '[.[].id] | max // 0' "$tmp/body")

spawn_second_daemon
await_log 'daemon listening' 1 \
  || fail "the second daemon never listened — $(cat "$tmp/reconcile.log")"

posted=$(in_container curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H 'content-type: application/json' -H "cookie: schermes_session=$sid" \
  -d '{"text":"Run something slow and tell me how it went."}' \
  "http://127.0.0.1:$second_port/api/agents/$agent_two/messages" | tr -d '\r')
[ "$posted" = 202 ] || fail "the second daemon refused the message: HTTP $posted"

state=''
for _ in $(seq 120); do
  req GET "/api/agents/$agent_two"
  state=$(jq -r '.state' "$tmp/body")
  [ "$state" = using_terminal ] && break
  sleep 1
done
[ "$state" = using_terminal ] || fail "$agent_two is $state, expected using_terminal"

say "a turn above the loop cap is taken and queued, and a daemon sharing the queue runs it"
# Any daemon on this database drains the queue: the container's own one sweeps it within
# SWEEP_MS. So the stub answers everyone straight away before the turn is posted, or the
# queued turn would start on the sleep that parks $agent_two. That sleep is already running
# and does not ask the stub again.
start_stub true 5000 memory
queued_turn_lines() {
  compose logs --no-log-prefix schermes 2>/dev/null \
    | jq -R --arg a "$agent_one" -c 'fromjson? | select(.msg == "queued turn started" and .agent == $a and .kind == "message")' \
    | wc -l | tr -d ' '
}
queued_before=$(queued_turn_lines)
over_cap=$(in_container curl -sS -w '\n%{http_code}' \
  -X POST -H 'content-type: application/json' -H "cookie: schermes_session=$sid" \
  -d '{"text":"And answer me too, please."}' \
  "http://127.0.0.1:$second_port/api/agents/$agent_one/messages" | tr -d '\r')
[ "$(printf '%s' "$over_cap" | tail -1)" = 202 ] \
  || fail "the second daemon did not take the turn above its cap of $second_max_loops: $over_cap"
await_log 'turn queued at the loop cap' 1 \
  || fail "the second daemon never said it queued the turn — $(cat "$tmp/reconcile.log")"
grep -h 'turn queued at the loop cap' "$tmp/reconcile.log" \
  | jq -e --arg a "$agent_one" -s 'any(.[]; .agent == $a and .kind == "message")' >/dev/null \
  || fail "the queued turn is not $agent_one's message — $(cat "$tmp/reconcile.log")"
echo "   202, and queued while the second daemon's one loop was busy"

settle "$agent_one"
[ "$state" = waiting_for_user ] || fail "$agent_one is $state after its queued turn"
[ "$(queued_turn_lines)" -gt "$queued_before" ] \
  || fail "$agent_one answered, but not from the queue: the container daemon logged no queued turn for it"
req GET "/api/agents/$agent_one/messages"
expect 200 "$agent_one's thread after the queued turn"
jq -e '(map(.role == "user" and ((.content // "") | contains("And answer me too"))) | index(true)) as $asked
       | $asked != null and (.[$asked + 1:] | any(.role == "assistant"))' "$tmp/body" >/dev/null \
  || fail "the queued message was never answered: $(body)"
echo "   the container daemon started it from the queue, and $agent_one answered"

req GET "/api/agents/$agent_two/messages"
expect 200 "the half-written transcript"
jq -e 'last | .role == "assistant" and (.toolCalls | length) == 1' "$tmp/body" >/dev/null \
  || fail "the transcript does not end in an unanswered tool call: $(body)"
interrupted_call=$(jq -r 'last | .toolCalls[0].id' "$tmp/body")
echo "   tool call $interrupted_call is in flight with nothing answering it"

say "killing the daemon out from under the tool call"
in_container sh -c "kill -9 \$(cat $second_pidfile) 2>/dev/null; exit 0"
wait "$second_client" 2>/dev/null || true
# ponytail: the command it was running is an orphan no daemon will ever read. Reaping it belongs
# to restart recovery proper; for now the smoke run cleans up after itself.
in_container sh -c "pkill -u agent-$agent_two -x sleep; exit 0"

say "a fresh daemon repairs what the killed one left behind"
reconcile
[ "$(reconciled_from "$agent_two")" = using_terminal ] \
  || fail "the fresh daemon did not reconcile $agent_two — $(cat "$tmp/reconcile.log")"

req GET "/api/agents/$agent_two"
expect 200 "agent state after the repair"
jq -e '.state == "waiting_for_user"' "$tmp/body" >/dev/null \
  || fail "$agent_two is $(jq -r '.state' "$tmp/body"), expected waiting_for_user"

req GET "/api/agents/$agent_two/messages"
expect 200 "the repaired transcript"
jq -e --arg id "$interrupted_call" \
  'last | .role == "tool" and .toolCallId == $id and (.content | test("daemon restarted"))' \
  "$tmp/body" >/dev/null || fail "the interrupted call was never answered: $(body)"

req GET "/api/agents/$agent_two/events"
expect 200 "the events after the repair"
jq -e --argjson since "$two_last_event" --arg id "$interrupted_call" '
  [.[] | select(.id > $since)] as $new
  | ([$new[] | select(.type == "restart" and .data.from == "using_terminal"
                      and (.data.interrupted | index($id)))] | length) == 1
  and ([$new[] | select(.type == "state") | .data.to] | last) == "waiting_for_user"
' "$tmp/body" >/dev/null || fail "the history does not say a restart happened: $(body)"
echo "   $interrupted_call answered, state repaired, and the restart is in the history"

say "$agent_two takes another message and finishes a turn on the repaired history"
req POST "/api/agents/$agent_two/messages" '{"text":"Never mind that. Who and where are you?"}'
expect 202 "a message after the repair"

settle "$agent_two"
[ "$state" = waiting_for_user ] || fail "$agent_two is $state after the second message"

req GET "/api/agents/$agent_two/messages"
expect 200 "the transcript after the second turn"
recovered=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
case $recovered in
  *valid=yes*) ;;
  *) fail "the model was handed a transcript with an unanswered tool call: $recovered" ;;
esac
# The synthetic result is what makes these two match; without it the endpoint sees a call with
# no answer, which is exactly what a strict one rejects.
asked=$(printf '%s' "$recovered" | sed -n 's/.*calls=\([^ ]*\).*/\1/p' | awk -F, '{print NF}')
answered=$(printf '%s' "$recovered" | sed -n 's/.*results=\([0-9]*\).*/\1/p')
[ -n "$asked" ] && [ "$asked" = "$answered" ] \
  || fail "the model saw $asked tool calls but $answered results: $recovered"
echo "   $asked tool calls, $answered results, and the model accepted the transcript"

# ---------------------------------------------------------------- memory and skills

say "a question finds what was said, across every thread"
# The stub's reply is not filters, so this is the plain-text fallback the daemon falls back to.
req POST /api/search "$(jq -nc --arg q "$nonce" '{q: $q}')"
expect 200 "search"
jq -e '(.understoodAs | length) > 0 and (.byModel | type) == "boolean"' "$tmp/body" >/dev/null \
  || fail "the answer does not say what the question was understood as: $(body | head -c 300)"
jq -e --arg a "$agent_one" 'any(.hits[]; .kind == "message" and .participants == [$a])' "$tmp/body" >/dev/null \
  || fail "the nonce was said in $agent_one's thread and not found: $(body | head -c 300)"
echo "   understood as: $(jq -r '.understoodAs | join("; ")' "$tmp/body")"
req GET "/api/agents/$agent_one/events"
expect 200 "the whole event log"
newest_three=$(jq -c '[.[-3:][] | .id]' "$tmp/body")
jq -e 'any(.[]; .type == "turn" and .data.steps > 0)' "$tmp/body" >/dev/null \
  || fail "no turn event records what a turn cost: $(body | head -c 300)"
req GET "/api/agents/$agent_one/events?limit=3"
expect 200 "the newest three events"
[ "$(jq -c '[.[] | .id]' "$tmp/body")" = "$newest_three" ] \
  || fail "limit=3 should be the newest three, oldest first: $(body)"

say "$agent_one starts from an empty memory and no skills"
# Idempotent, and both halves have to be: only the head of MEMORY.md is ever loaded, so a file
# left growing across runs would stop carrying the newest line, and the skills index below is
# asserted whole, so a folder left behind by an earlier run would make it a list.
run_cmd "rm -f ~/memory/MEMORY.md && rm -rf ~/skills/* && ls -d ~/memory ~/skills"
expect 200 "clear the memory and the skills"
jq -e '.exitCode == 0' "$tmp/body" >/dev/null \
  || fail "the agent has no memory or skills directory: $(body)"

say "a skill folder in ~/skills is there to be indexed on the next turn"
run_cmd "mkdir -p ~/skills/deploy && printf '%s\n' '---' 'name: deploy' \
         'description: how we ship' '---' 'the body, which the index must not carry' \
         > ~/skills/deploy/SKILL.md"
expect 200 "write a skill"

say "$agent_one remembers a fact"
start_stub true 5000 memory "$agent_one"
req POST "/api/agents/$agent_one/messages" '{"text":"Remember what I am called."}'
expect 202 "post the message that makes it remember"
settle "$agent_one"

run_cmd 'cat ~/memory/MEMORY.md'
expect 200 "read the memory back"
jq -e --arg n "$nonce" '.exitCode == 0 and (.stdout | contains($n))' "$tmp/body" >/dev/null \
  || fail "remember did not write the fact as the agent user: $(body)"
echo "   $(jq -r '.stdout' "$tmp/body" | tr -d '\r')"

say "the fact and the skill survive a daemon restart and reach the next turn's prompt"
# The stub gets no sender this time, so nobody remembers again: whatever comes back in the
# system prompt was read off disk by a daemon that was not running when it was written. The stub
# goes down first: its pid file outlives a container restart, and pids are recycled.
stop_stub
compose restart schermes >/dev/null
wait_health
start_stub true 5000 memory
req POST "/api/agents/$agent_one/messages" '{"text":"What am I called?"}'
expect 202 "post a message to the restarted daemon"
settle "$agent_one"

req GET "/api/agents/$agent_one/messages"
expect 200 "the transcript after the restart"
remembered=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
for want in 'memory=yes' 'skills=deploy' 'tools=add_helper,ask_for_hands,ask_owner,browser,cancel_schedule,computer,list_schedules,pause_schedule,propose_trigger,remember,request_approval,request_deletion,request_form,run_command,schedule_task,send_message,set_name,set_profile,spawn_task_worker,update_goal,web_fetch,web_search'; do
  case $remembered in
    *"$want"*) ;;
    *) fail "the model never saw $want — it reported: $remembered" ;;
  esac
done
echo "   the remembered line came back in the system prompt of a turn on a new daemon"

run_cmd "grep -c . ~/memory/MEMORY.md"
expect 200 "the memory is still one curated file"
echo "   ~/memory/MEMORY.md holds $(jq -r '.stdout' "$tmp/body" | tr -d '\r\n') line(s)"

# ---------------------------------------------------------------- scheduled tasks

# The one part of the daemon a unit test cannot really prove: that a real interval, on a real
# clock, in a real container, starts a turn nobody asked for. Everything else about schedules —
# pause, cancel, the once-at-boot catch-up, the per-agent scoping — is covered in loop.test.ts.

req GET "/api/agents/$agent_one/messages"
expect 200 "the thread before the job fires"
before=$(jq -r '[.[].id] | max // 0' "$tmp/body")

say "a job a few seconds out fires by itself and lands in the owner thread"
# Removed however this run ends: a job every ten seconds that outlived a failed run would keep
# starting turns against a stub that is no longer listening.
schedule_id=''
trap 'if [ -n "$schedule_id" ]; then
        curl -sS -o /dev/null -X DELETE -b "$tmp/jar" \
          "$base/api/agents/$agent_one/schedules/$schedule_id" || true
      fi
      rm -rf "$tmp"' EXIT INT TERM

start_stub true 5000 memory
req POST "/api/agents/$agent_one/schedules" \
  "$(jq -nc --arg p "$nonce say what the schedule asked for" '{cron: "*/10 * * * * *", prompt: $p}')"
expect 201 "create the schedule"
schedule_id=$(jq -r '.id' "$tmp/body")
jq -e --argjson now "$(date +%s)000" '.paused == false and .nextRunAt > $now' "$tmp/body" >/dev/null \
  || fail "the new schedule is not due in the future: $(body)"
echo "   schedule $schedule_id, next run $(jq -r '.nextRunAt' "$tmp/body")"

# Up to one tick after the row falls due, plus the turn it starts.
fired=''
for _ in $(seq 90); do
  req GET "/api/agents/$agent_one/messages?after=$before"
  fired=$(jq -r --arg n "$nonce" \
    '[.[] | select(.role == "user" and .sender == "System" and (.content | contains($n)))] | first | .content // ""' \
    "$tmp/body")
  [ -n "$fired" ] && break
  sleep 1
done
[ -n "$fired" ] || fail "no scheduled turn started within 90 seconds"
case $fired in
  "Scheduled task $schedule_id "*) ;;
  *) fail "the delivered message does not name the schedule it came from: $fired" ;;
esac
echo "   the tick delivered: $(printf '%s' "$fired" | head -1)"

settle "$agent_one"
req GET "/api/agents/$agent_one/messages?after=$before"
expect 200 "the thread after the scheduled turn"
scheduled_answer=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
case $scheduled_answer in
  *"schedules=$schedule_id"*) ;;
  *) fail "the agent was never shown the schedule it holds — it reported: $scheduled_answer" ;;
esac
echo "   and the agent's own schedules were in the prompt of the turn it started"

req GET "/api/agents/$agent_one/schedules"
expect 200 "the schedule after it fired"
jq -e --argjson id "$schedule_id" \
  '[.[] | select(.id == $id)] | first | (.lastRunAt != null) and (.nextRunAt > .lastRunAt)' \
  "$tmp/body" >/dev/null \
  || fail "the row did not move on to its next slot: $(body)"

say "pausing and cancelling the schedule work from the owner api"
req PATCH "/api/agents/$agent_one/schedules/$schedule_id" '{"paused":true}'
expect 200 "pause the schedule"
jq -e '.paused == true' "$tmp/body" >/dev/null || fail "the schedule did not pause: $(body)"

req DELETE "/api/agents/$agent_one/schedules/$schedule_id"
expect 200 "cancel the schedule"
schedule_id=''
req GET "/api/agents/$agent_one/schedules"
expect 200 "the schedules after the cancel"
jq -e 'length == 0' "$tmp/body" >/dev/null || fail "the cancelled schedule is still there: $(body)"

# ---------------------------------------------------------------- web fetch refuses the daemon

# The only web step that can run with no internet. A stub page would have to be served from
# loopback, and loopback is precisely what web_fetch will not touch — so the offline assertion
# is the refusal, made against the daemon's own API, which is the thing the guard protects.
say "web_fetch refuses the daemon's own address rather than reaching it"
start_stub true 5000 web "$agent_one" '' "http://127.0.0.1:${SCHERMES_PORT:-7777}/api/agents"

req GET "/api/agents/$agent_one/messages"
expect 200 "the thread before the web turn"
web_before=$(jq -r '[.[].id] | max // 0' "$tmp/body")

req POST "/api/agents/$agent_one/messages" '{"text":"Read the daemon api and tell me what you see."}'
expect 202 "post the message that makes it fetch"
settle "$agent_one"
[ "$state" = waiting_for_user ] || fail "$agent_one is $state after the web turn, not waiting"

req GET "/api/agents/$agent_one/messages?after=$web_before"
expect 200 "the thread after the web turn"
refusal=$(jq -r '[.[] | select(.role == "tool")] | last | .content' "$tmp/body")
case $refusal in
  *"loopback, link-local or private address"*) ;;
  *) fail "web_fetch did not refuse the daemon's own address, it answered: $refusal" ;;
esac
# A refusal, not a leak: `display` is a field of every agent row and has no business being in
# the observation, so it is there only if the API answer came back through the tool.
case $refusal in
  *display*) fail "the daemon's api answer reached the agent: $refusal" ;;
esac
echo "   $refusal"

web_answer=$(jq -r '[.[] | select(.role == "assistant")] | last | .content' "$tmp/body")
case $web_answer in
  *web_fetch*web_search*|*web_search*web_fetch*) ;;
  *) fail "the agent was not offered the web tools — it reported: $web_answer" ;;
esac
echo "   and the turn carried on and answered: $(printf '%s' "$web_answer" | cut -c1-60)..."

# ---------------------------------------------------------------- rules, approvals, Needs you, a webhook

guarded_file=smoke-guarded.txt
hook_nonce="$nonce-hook"

# A denial starts a turn in the asker's thread, so any leftover is answered with a stub that only
# reports: the guarded script below counts its calls from the first.
say "no approval is left over from an earlier run"
start_stub true 5000 memory
req GET /api/approvals
expect 200 "list approvals"
for stale in $(jq -r --arg a "$agent_one" '.[] | select(.agent == $a) | .id' "$tmp/body"); do
  req POST "/api/approvals/$stale" '{"approve":false}'
  expect 200 "deny approval $stale, left behind by an earlier run"
  settle "$agent_one"
  echo "   denied a leftover approval"
done

say "$agent_one's delete is refused by its rules and nothing is removed"
run_cmd "touch ~/$guarded_file"
expect 200 "create the file the agent will try to delete"
start_stub "rm -f ~/$guarded_file" 30000 guarded "$agent_one"
req GET "/api/agents/$agent_one/messages"
expect 200 "the thread before the guarded turn"
guarded_before=$(jq -r '[.[].id] | max // 0' "$tmp/body")
req POST "/api/agents/$agent_one/messages" '{"text":"Clear out your scratch file, and set up a way for me to wake you."}'
expect 202 "post the message that makes it delete"
settle "$agent_one"
[ "$state" = waiting_for_user ] || fail "$agent_one is $state after the guarded turn, not waiting"
req GET "/api/agents/$agent_one/messages?after=$guarded_before"
expect 200 "the thread after the guarded turn"
refused=$(jq -r '[.[] | select(.role == "tool")][0].content' "$tmp/body")
case $refused in
  *"rules say to ask the owner"*"Nothing was run"*) ;;
  *) fail "the delete was not refused by the rules, the tool said: $refused" ;;
esac
run_cmd "test -f ~/$guarded_file"
expect 200 "look for the file"
jq -e '.exitCode == 0' "$tmp/body" >/dev/null || fail "the refused delete removed the file anyway"
echo "   $(printf '%s' "$refused" | cut -c1-90)..."

say "the approval it asked for waits under Needs you, and answering it clears it everywhere"
req GET /api/approvals
expect 200 "list approvals"
approval_id=$(jq -r --arg n "$nonce" '[.[] | select(.target == $n and .category == "delete_files")][0].id // empty' "$tmp/body")
[ -n "$approval_id" ] || fail "$agent_one's request_approval left no approval: $(body | head -c 300)"
req GET /api/needs-you
expect 200 "Needs you"
jq -e --arg id "approval:$approval_id" 'any(.[]; .id == $id and (.actions | index("deny")))' "$tmp/body" >/dev/null \
  || fail "approval $approval_id is not under Needs you with a deny action: $(body | head -c 300)"
# Denied, not approved: an approval is a one-shot pass, and the next run's delete must be refused too.
req POST "/api/needs-you/approval:$approval_id/action" '{"action":"deny"}'
expect 200 "deny from Needs you"
settle "$agent_one"
req GET /api/needs-you
expect 200 "Needs you after the answer"
jq -e --arg id "approval:$approval_id" 'all(.[]; .id != $id)' "$tmp/body" >/dev/null \
  || fail "approval $approval_id is still under Needs you"
req GET /api/approvals
expect 200 "approvals after the answer"
jq -e --argjson id "$approval_id" 'all(.[]; .id != $id)' "$tmp/body" >/dev/null \
  || fail "approval $approval_id is still listed"
req POST "/api/needs-you/approval:$approval_id/action" '{"action":"deny"}'
expect 404 "a second answer to the same item"
echo "   approval:$approval_id listed, denied, and gone"

say "the webhook it proposed fires a turn once the owner turns it on"
req GET "/api/agents/$agent_one/triggers"
expect 200 "$agent_one's triggers"
trigger_id=$(jq -r --arg n "$nonce" \
  '[.[] | select(.kind == "webhook" and .state == "proposed" and (.reason | contains($n)))][0].id // empty' "$tmp/body")
[ -n "$trigger_id" ] || fail "$agent_one's propose_trigger left no proposed webhook: $(body | head -c 300)"
req POST "/api/triggers/$trigger_id" '{"action":"on"}'
expect 200 "turn the trigger on"
hook_path=$(jq -r '.webhook.path // empty' "$tmp/body")
hook_secret=$(jq -r '.webhook.secret // empty' "$tmp/body")
[ -n "$hook_path" ] && [ -n "$hook_secret" ] || fail "turning the webhook on minted no url and secret: $(body)"
settle "$agent_one"
# Plain curl, no cookie jar: the caller is another service with a secret, not the owner.
hook() { curl -sS -o "$tmp/body" -w '%{http_code}' -X POST "$@" --data "$hook_nonce" "$base$hook_path"; }
[ "$(hook)" = 401 ] || fail "a hook with no secret was not refused: $(body)"
[ "$(hook -H 'x-schermes-secret: wrong')" = 401 ] || fail "a hook with the wrong secret was not refused: $(body)"
[ "$(hook -H "x-schermes-secret: $hook_secret")" = 202 ] || fail "the hook with its secret did not fire: $(body)"
settle "$agent_one"
req GET "/api/agents/$agent_one/messages?after=$guarded_before"
expect 200 "the thread after the hook"
jq -e --arg p "Trigger $trigger_id fired:" --arg n "$hook_nonce" \
  'any(.[]; .sender == "Trigger" and (.content | startswith($p)) and (.content | contains($n)))' "$tmp/body" >/dev/null \
  || fail "no fired row carrying the request body in $agent_one's thread: $(body | head -c 400)"
req POST "/api/triggers/$trigger_id" '{"action":"delete"}'
expect 200 "delete the trigger"
[ "$(hook -H "x-schermes-secret: $hook_secret")" = 404 ] || fail "a deleted hook still answered: $(body)"
echo "   401 without the secret, 202 with it, and the fired row is in $agent_one's thread"
run_cmd "rm -f ~/$guarded_file"
expect 200 "clean up the guarded file"

printf '\nOK: health, setup, login, auth guard, an api-only surface on the one exposed port,\n'
printf '    settings, the model registry, rules, two agents with adopted desktops,\n'
printf '    a tool layer that screenshots, drives input, uses the clipboard and runs commands,\n'
printf '    an agent loop that reaches a model, calls both tools and answers durably,\n'
printf '    a message taken by a busy agent, one agent asking another across their threads and\n'
printf '    woken by the answer, a task worker that did its job as its parent\n'
printf '    and reported back, a turn queued at the loop cap and run by another daemon, a vnc stream proxied to the\n'
printf '    owner and an agent stood down while a human held its mouse, and a daemon killed mid\n'
printf '    tool call whose agent comes back repaired and answerable, and an agent that\n'
printf '    remembers a fact, survives a restart and is handed it back in its next prompt, and a\n'
printf '    scheduled task that fired on the clock the daemon keeps, into the owner thread\n'
printf '    and a web_fetch that refused the daemon its own address before making a request,\n'
printf '    a question answered by search, a delete refused by the rules, an approval answered\n'
printf '    from Needs you, and a webhook trigger that fired a turn\n'

