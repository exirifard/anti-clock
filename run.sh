#!/usr/bin/env bash
# run.sh - launch the anticlockwise watch screensaver fullscreen in Chrome
# kiosk mode and close it as soon as the user touches the keyboard or mouse.
#
# Environment:
#   CHROME_BIN            Chrome binary to use (default: google-chrome)
#   SCREENSAVER_DRY_RUN=1 print the exact command that would run and exit 0
#
# Exit codes: 0 on normal exit (user input, Chrome exited, dry run),
#             1 if another instance is already running or Chrome is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE_URL="file://${SCRIPT_DIR}/index.html"
CHROME_BIN="${CHROME_BIN:-google-chrome}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PROFILE_DIR="${RUNTIME_DIR}/anticlockwise-watch-profile"
# Distinct from idle-watcher.sh's lock: the watcher holds its own flock for its
# whole lifetime, so sharing one file would make every launch fail.
LOCK_FILE="${RUNTIME_DIR}/anticlockwise-watch-run.lock"

GRACE_SECONDS=2
POLL_SECONDS=0.5
IDLE_THRESHOLD_MS=1000

CHROME_ARGS=(
  --kiosk
  "--app=${PAGE_URL}"
  --no-first-run
  --no-default-browser-check
  --password-store=basic
  --disable-session-crashed-bubble
  --disable-infobars
  --start-fullscreen
  --class=anticlockwise-watch
  --disable-features=TranslateUI
  "--user-data-dir=${PROFILE_DIR}"
)

log() {
  printf '[%s] run.sh: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Print the GNOME idle time in milliseconds. If dbus-send fails for any
# reason, report a huge value so the caller treats the user as idle rather
# than crashing or killing the screensaver by mistake.
get_idle_ms() {
  local out last num
  if ! out="$(dbus-send --print-reply \
      --dest=org.gnome.Mutter.IdleMonitor \
      /org/gnome/Mutter/IdleMonitor/Core \
      org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null)"; then
    echo 999999999
    return 0
  fi
  last="$(printf '%s\n' "$out" | tail -n 1)"
  num="$(printf '%s\n' "$last" | sed -n 's/.*uint64[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  if [[ -z "$num" ]]; then
    echo 999999999
  else
    echo "$num"
  fi
}

CHROME_PID=""

# Kill the Chrome process tree: children first, then the parent, then
# SIGKILL anything that survived after one second. Errors are ignored.
kill_chrome() {
  local pid="${CHROME_PID}"
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    CHROME_PID=""
    return 0
  fi
  log "stopping Chrome (pid ${pid})"
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  CHROME_PID=""
}

on_signal() {
  log "caught signal, exiting"
  kill_chrome
  exit 0
}

cleanup() {
  kill_chrome
}

# --- Dry run: show what would happen and leave --------------------------------
if [[ "${SCREENSAVER_DRY_RUN:-0}" == "1" ]]; then
  printf 'DRY RUN: would launch:\n'
  printf '  %q' "$CHROME_BIN"
  for arg in "${CHROME_ARGS[@]}"; do
    printf ' %q' "$arg"
  done
  printf '\n'
  printf 'DRY RUN: profile dir %s, lock file %s\n' "$PROFILE_DIR" "$LOCK_FILE"
  printf 'DRY RUN: would poll GetIdletime every %ss after a %ss grace period and exit when idle < %s ms\n' \
    "$POLL_SECONDS" "$GRACE_SECONDS" "$IDLE_THRESHOLD_MS"
  exit 0
fi

# --- Single-instance guard -----------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another instance is already running (lock ${LOCK_FILE}); exiting"
  exit 1
fi
if pgrep -f -- "--user-data-dir=${PROFILE_DIR}" >/dev/null 2>&1; then
  log "a Chrome using ${PROFILE_DIR} is already running; exiting"
  exit 1
fi

if ! command -v "$CHROME_BIN" >/dev/null 2>&1; then
  log "Chrome binary not found: ${CHROME_BIN} (set CHROME_BIN)"
  exit 1
fi

mkdir -p "$PROFILE_DIR"

trap on_signal INT TERM
trap cleanup EXIT

# --- Launch ----------------------------------------------------------------------
log "launching ${CHROME_BIN} on ${PAGE_URL}"
"$CHROME_BIN" "${CHROME_ARGS[@]}" >/dev/null 2>&1 9>&- &
CHROME_PID=$!

# --- Grace period: ignore the input that may have triggered the launch -------
sleep "$GRACE_SECONDS"

# --- Watch for user input or Chrome exit --------------------------------------
while kill -0 "$CHROME_PID" 2>/dev/null; do
  idle_ms="$(get_idle_ms)"
  if (( idle_ms < IDLE_THRESHOLD_MS )); then
    log "user input detected (idle ${idle_ms} ms); closing screensaver"
    kill_chrome
    exit 0
  fi
  sleep "$POLL_SECONDS"
done

log "Chrome exited on its own"
CHROME_PID=""
exit 0
