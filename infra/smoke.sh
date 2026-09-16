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
done

if [ "$harness" != true ]; then
  printf '\nOK: health, setup, login, auth guard, settings and the agents API all behave\n'
  printf '    (desktop assertions skipped: not running against a docker compose service)\n'
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

# Polls until an agent stops working and leaves the answer in $state. Not a subshell: `fail`
# has to be able to end the run from in here.
settle() {
  local agent=$1 _
  state=''
  for _ in $(seq 180); do
    req GET "/api/agents/$agent"
    state=$(jq -r '.state' "$tmp/body")
    case $state in
      waiting_for_user|waiting_for_agent) return 0 ;;
      failed)
        req GET "/api/agents/$agent/events"
        fail "$agent failed: $(jq -c '[.[] | select(.type == "failure")] | last' "$tmp/body")"
        ;;
    esac
    sleep 1
  done
  fail "$agent is $state and never settled"
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
            'tools=ask_owner,browser,cancel_schedule,computer,list_schedules,pause_schedule,remember,request_deletion,run_command,schedule_task,send_message,set_profile,spawn_task_worker,web_fetch,web_search' 'valid=yes'; do
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
# The container took the scripted endpoint down with it, and everything below needs one.
start_stub "echo $nonce; id -un" 30000

# ---------------------------------------------------------------- agents talking

say "the owner opens the thread the two agents share"
req GET "/api/agents/$agent_one/conversations"
expect 200 "list conversations"
jq -e --arg a "$agent_one" '[.[] | select(.participants == [$a])] | length == 1' "$tmp/body" \
  >/dev/null || fail "$agent_one has no owner thread of its own: $(body)"

req GET /api/agents/nobody/conversations
expect 404 "conversations for an unknown agent"
req POST /api/conversations "$(jq -nc --arg a "$agent_one" '{participants: [$a, "nobody"]}')"
expect 400 "a participant list naming an agent that does not exist"
req POST /api/conversations '{"participants":[]}'
expect 400 "an empty participant list"
req GET /api/conversations/999999/messages
expect 404 "an unknown conversation"

req POST /api/conversations \
  "$(jq -nc --arg a "$agent_one" --arg b "$agent_two" '{participants: [$a, $b]}')"
expect 201 "create the shared thread"
shared=$(jq -r '.id' "$tmp/body")
jq -e --arg a "$agent_one" --arg b "$agent_two" \
  '(.participants | sort) == ([$a, $b] | sort)' "$tmp/body" >/dev/null \
  || fail "the thread does not hold both agents: $(body)"
echo "   thread $shared holds $agent_one and $agent_two"

# A conversation is its participant set, so asking for the same pair again is the same row —
# which is what keeps this run repeatable and what send_message finds.
req POST /api/conversations \
  "$(jq -nc --arg a "$agent_two" --arg b "$agent_one" '{participants: [$a, $b]}')"
expect 201 "ask for the same pair again"
[ "$(jq -r '.id' "$tmp/body")" = "$shared" ] || fail "the same pair opened a second thread"

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

say "$agent_one writes to $agent_two, which answers and wakes it"
start_stub "echo $nonce; id -un" 30000 talk "$agent_one" "$agent_two"

req GET "/api/conversations/$shared/messages"
expect 200 "the shared thread before the exchange"
shared_last=$(jq -r '[.[].id] | max // 0' "$tmp/body")

req POST "/api/agents/$agent_one/messages" \
  "$(jq -nc --arg b "$agent_two" '{text: ("Ask " + $b + " for its hostname, then tell me.")}')"
expect 202 "the message that starts the exchange"

# The exchange crosses both agents and comes back: $agent_one ends its turn waiting, and the
# reply is what starts it again. Waiting for one agent to settle is not the end of it.
exchange() {
  jq -e --argjson since "$shared_last" --arg a "$agent_one" --arg b "$agent_two" '
    [.[] | select(.id > $since)] as $new
    | ([$new[] | select(.role == "assistant" and .sender == $a)] | length) >= 1
    and ([$new[] | select(.role == "assistant" and .sender == $b)] | length) >= 1
  ' "$tmp/body" >/dev/null
}
for _ in $(seq 120); do
  req GET "/api/conversations/$shared/messages"
  exchange && break
  sleep 1
done
req GET "/api/conversations/$shared/messages"
exchange || fail "the two agents never both spoke in the thread: $(body)"

jq -e --argjson since "$shared_last" --arg a "$agent_one" --arg n "$nonce" '
  [.[] | select(.id > $since)] as $new
  | ([$new[] | select(.role == "user" and .sender == $a and (.content | contains($n)))] | length)
      == 1
' "$tmp/body" >/dev/null || fail "the message $agent_one sent is not stored under its name: $(body)"

heard_by() {
  jq -r --argjson since "$shared_last" --arg who "$1" \
    '[.[] | select(.id > $since and .role == "assistant" and .sender == $who)] | last | .content' \
    "$tmp/body"
}
two_said=$(heard_by "$agent_two")
one_said=$(heard_by "$agent_one")
for want in "agent=$agent_two" "heard=$agent_one" 'valid=yes'; do
  case $two_said in *"$want"*) ;; *) fail "$agent_two never saw $want — it reported: $two_said" ;; esac
done
case $one_said in
  *"heard=$agent_two"*) ;;
  *) fail "$agent_one was never shown the reply as coming from $agent_two: $one_said" ;;
esac
echo "   $agent_two answered $agent_one, and $agent_one was woken by the reply"

req GET "/api/agents/$agent_one/events"
expect 200 "the events of the exchange"
jq -e --arg b "$agent_two" \
  '[.[] | select(.type == "tool_result" and .data.to == $b)] | length >= 1' "$tmp/body" \
  >/dev/null || fail "no send_message result is in the history: $(body)"

say "one message to the group thread is answered by both agents"
start_stub "echo $nonce; id -un" 30000 talk

req GET "/api/conversations/$shared/messages"
expect 200 "the group thread before the fan-out"
shared_last=$(jq -r '[.[].id] | max // 0' "$tmp/body")

req POST "/api/conversations/$shared/messages" '{"text":"Who is around? One line each."}'
expect 202 "post to the group thread"
jq -e '.message.role == "user" and (.message | has("sender") | not)' "$tmp/body" >/dev/null \
  || fail "the owner message was stored under an agent name: $(body)"

for _ in $(seq 120); do
  req GET "/api/conversations/$shared/messages"
  exchange && break
  sleep 1
done
req GET "/api/conversations/$shared/messages"
exchange || fail "one message to the group did not get a reply from each agent: $(body)"

for name in "$agent_one" "$agent_two"; do
  said=$(heard_by "$name")
  case $said in
    *"agent=$name"*heard=*the_owner*) ;;
    *) fail "$name did not answer the owner in the group thread: $said" ;;
  esac
done
settle "$agent_one"
settle "$agent_two"
echo "   both agents answered the owner in thread $shared"

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

say "a turn above the loop cap is refused with an error that names the cap"
refused=$(in_container curl -sS -w '\n%{http_code}' \
  -X POST -H 'content-type: application/json' -H "cookie: schermes_session=$sid" \
  -d '{"text":"And answer me too, please."}' \
  "http://127.0.0.1:$second_port/api/agents/$agent_one/messages" | tr -d '\r')
[ "$(printf '%s' "$refused" | tail -1)" = 429 ] \
  || fail "the second daemon took a turn above its cap of $second_max_loops: $refused"
case $refused in
  *"agent loops can run at once"*) ;;
  *) fail "the refusal does not say which cap was hit: $refused" ;;
esac
echo "   refused with 429 while its one loop was busy"

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

say "a search finds what was said, across every thread"
req GET "/api/search?q=$(printf '%s' "$nonce" | jq -sRr @uri)"
expect 200 "search"
jq -e --arg a "$agent_one" '[.[] | select(.participants == [$a])] | length > 0' "$tmp/body" >/dev/null \
  || fail "the nonce was said in $agent_one's thread and not found: $(body | head -c 300)"
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
for want in 'memory=yes' 'skills=deploy' 'tools=ask_owner,browser,cancel_schedule,computer,list_schedules,pause_schedule,remember,request_deletion,run_command,schedule_task,send_message,set_profile,spawn_task_worker,web_fetch,web_search'; do
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
    '[.[] | select(.role == "user" and .sender == null and (.content | contains($n)))] | first | .content // ""' \
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

printf '\nOK: health, setup, login, auth guard, an api-only surface on the one exposed port,\n'
printf '    settings, two agents with adopted desktops,\n'
printf '    a tool layer that screenshots, drives input, uses the clipboard and runs commands,\n'
printf '    an agent loop that reaches a model, calls both tools and answers durably,\n'
printf '    a message taken by a busy agent, two agents holding a conversation the owner can\n'
printf '    read, a group thread answered by both, a task worker that did its job as its parent\n'
printf '    and reported back, a loop cap that refuses with a 429, a vnc stream proxied to the\n'
printf '    owner and an agent stood down while a human held its mouse, and a daemon killed mid\n'
printf '    tool call whose agent comes back repaired and answerable, and an agent that\n'
printf '    remembers a fact, survives a restart and is handed it back in its next prompt, and a\n'
printf '    scheduled task that fired on the clock the daemon keeps, into the owner thread\n'
printf '    and a web_fetch that refused the daemon its own address before making a request\n'

