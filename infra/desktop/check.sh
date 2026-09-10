#!/usr/bin/env bash
# Runnable check for the schermes desktop foundation.
#
# Creates three agents, gives each its own Xvnc desktop and Chromium profile, drives them with
# xdotool, captures a screenshot per desktop, and verifies that a cookie survives a Chromium
# restart and that nothing listens outside loopback. Idempotent: safe to run repeatedly.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  exec sudo -u schermes -H env SCHERMES_PORT="${SCHERMES_PORT:-7777}" "$0" "$@"
fi

here=$(cd -- "$(dirname -- "$0")" && pwd)
agents=(alpha bravo charlie)
displays=(1 2 3)
port=${SCHERMES_CHECK_PORT:-8899}
out=/tmp/schermes-check
base="http://127.0.0.1:$port"

mkdir -p "$out"
chmod 1777 "$out"

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

agent_home() { getent passwd "agent-$1" | cut -d: -f6; }

on_agent() {
  local a=$1 d=$2; shift 2
  sudo -n -u "agent-$a" env \
    HOME="$(agent_home "$a")" USER="agent-$a" LOGNAME="agent-$a" \
    DISPLAY=":$d" XAUTHORITY="$(agent_home "$a")/.Xauthority" "$@"
}

window_title() {
  on_agent "$1" "$2" xdotool search --onlyvisible --class chromium getwindowname %@ 2>/dev/null | tail -1
}

wait_title() {
  local a=$1 d=$2 pat=$3 i t=
  for i in $(seq 90); do
    t=$(window_title "$a" "$d") || t=
    case "$t" in *"$pat"*) printf '%s' "$t"; return 0 ;; esac
    sleep 1
  done
  fail "agent $a: no window titled '*$pat*' after 90s (last seen: '${t:-none}')"
}

launch_chromium() {
  local a=$1 d=$2 url=$3 home
  home=$(agent_home "$a")
  on_agent "$a" "$d" setsid --fork chromium \
    --user-data-dir="$home/.chromium-profile" \
    --no-first-run --no-default-browser-check --disable-features=Translate \
    --window-size=1280,800 --window-position=0,0 \
    "$url" >>"$out/$a-chromium.log" 2>&1
}

# The browser process is the only chromium process without a --type= argument. Signalling it
# alone gives a graceful shutdown; signalling the whole tree loses uncommitted cookie writes.
chromium_main() {
  local a=$1 p
  for p in $(pgrep -u "agent-$a" -f '^/usr/lib/chromium/chromium ' 2>/dev/null || true); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--type=' || { printf '%s' "$p"; return 0; }
  done
  return 1
}

stop_chromium() {
  local a=$1 d=$2 i main
  main=$(chromium_main "$a") || return 0
  on_agent "$a" "$d" kill -TERM "$main"
  for i in $(seq 30); do
    chromium_main "$a" >/dev/null || return 0
    sleep 1
  done
  fail "agent $a: chromium did not exit after SIGTERM"
}

say "serving the test page on 127.0.0.1:$port"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$here/testpage" >/dev/null 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT
for _ in $(seq 20); do curl -fsS "$base/" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$base/" >/dev/null || fail "test page server did not start"

declare -A nonce
for i in "${!agents[@]}"; do
  a=${agents[$i]} d=${displays[$i]}
  say "agent $a on display :$d"
  sudo -n /opt/schermes/infra/desktop/create-agent-user.sh "$a"
  "$here/start-desktop.sh" "$a" "$d"
  nonce[$a]=$(mcookie | cut -c1-10)
done

for i in "${!agents[@]}"; do
  a=${agents[$i]} d=${displays[$i]}
  say "driving chromium for $a"
  stop_chromium "$a" "$d"
  launch_chromium "$a" "$d" "about:blank"
  wait_title "$a" "$d" "about:blank" >/dev/null

  on_agent "$a" "$d" xdotool search --onlyvisible --class chromium windowactivate --sync %1
  on_agent "$a" "$d" xdotool key --clearmodifiers ctrl+l
  sleep 1
  on_agent "$a" "$d" xdotool key --clearmodifiers ctrl+a
  on_agent "$a" "$d" xdotool type --clearmodifiers --delay 25 \
    "$base/?agent=$a&set=${nonce[$a]}"
  on_agent "$a" "$d" xdotool key --clearmodifiers Return

  title=$(wait_title "$a" "$d" "SCHERMES agent=$a")
  echo "   title: $title"
  on_agent "$a" "$d" scrot -o "$out/$a.png"
  echo "   screenshot: $out/$a.png"
done

say "screenshots are distinct and non-blank"
for a in "${agents[@]}"; do
  colors=$(identify -format '%k' "$out/$a.png")
  [ "$colors" -gt 10 ] || fail "$out/$a.png looks blank ($colors colors)"
  echo "   $out/$a.png  $colors colors"
done
distinct=$(md5sum "$out"/*.png | awk '{print $1}' | sort -u | wc -l)
[ "$distinct" -eq "${#agents[@]}" ] || fail "expected ${#agents[@]} distinct screenshots, got $distinct"

say "chromium commits the cookies to its profile"
# Chromium batches cookie writes on a timer and its SIGTERM path does not flush them, so wait
# for the write to reach the profile before restarting the browser.
for a in "${agents[@]}"; do
  cookies="$(agent_home "$a")/.chromium-profile/Default/Cookies"
  for i in $(seq 180); do
    on_agent "$a" 0 grep -qa "schermes_${nonce[$a]}" "$cookies" "$cookies-wal" 2>/dev/null && break
    sleep 1
  done
  on_agent "$a" 0 grep -qa "schermes_${nonce[$a]}" "$cookies" "$cookies-wal" 2>/dev/null \
    || fail "agent $a: cookie schermes_${nonce[$a]} never reached $cookies"
  echo "   $a: committed after ${i}s"
done

say "cookie survives a chromium restart"
for i in "${!agents[@]}"; do
  a=${agents[$i]} d=${displays[$i]}
  stop_chromium "$a" "$d"
  launch_chromium "$a" "$d" "$base/?agent=$a"
  title=$(wait_title "$a" "$d" "SCHERMES agent=$a cookie=[")
  case "$title" in
    *"schermes_${nonce[$a]}"*) echo "   $a: schermes_${nonce[$a]} survived the restart" ;;
    *) fail "agent $a: cookie gone after restart (title: $title)" ;;
  esac
done

say "only the schermes web port listens outside loopback"
# Compare the whole addr:port. Stripping the port would let a later slice bind something like
# 0.0.0.0:5900 and still pass, which is exactly what this assertion exists to catch.
web_port=${SCHERMES_PORT:-7777}
ss -ltnH | awk '{print $4}' | sort -u | while read -r sock; do
  case "${sock%:*}" in
    127.*|'[::1]'|::1|'[::ffff:127.0.0.1]')
      echo "   ok   $sock"
      ;;
    *)
      if [ "${sock##*:}" = "$web_port" ]; then
        echo "   ok   $sock (schermes web port)"
      else
        echo "   BAD  $sock"
        exit 1
      fi
      ;;
  esac
done || fail "a listening socket is bound outside loopback"

printf '\nOK: %d desktops, %d chromium profiles, cookies persisted, only :%s off loopback\n' \
  "${#agents[@]}" "${#agents[@]}" "$web_port"
