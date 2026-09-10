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

printf '\nOK: health, setup, login, auth guard, settings, two agents with adopted desktops,\n'
printf '    and a tool layer that screenshots, drives input, uses the clipboard and runs commands\n'

