#!/usr/bin/env bash
# idle-watcher.sh - start the anticlockwise-watch screensaver once the user has been idle.
#
# Polls GNOME's Mutter IdleMonitor over D-Bus every 2 s. When the idle time reaches
# IDLE_SECONDS (env, default 120) it runs ./run.sh (blocking) and then resumes polling.
# Only one watcher runs at a time (flock on ${XDG_RUNTIME_DIR:-/tmp}/anticlockwise-watch-watcher.lock;
# run.sh has its own separate lock file),
# and it never launches run.sh while a run.sh / screensaver Chrome is already running.
#
# Usage:
#   ./idle-watcher.sh          loop forever (this is what the autostart entry runs)
#   ./idle-watcher.sh --once   single poll: print idle seconds and whether it would launch, then exit
#   ./idle-watcher.sh --help
#
# Env:
#   IDLE_SECONDS   idle threshold in seconds (default 120). Keep it below GNOME's own
#                  idle-delay (default 300 s), otherwise GNOME blanks the screen first.
#
# All log output goes to stderr with timestamps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="${SCRIPT_DIR}/run.sh"
IDLE_SECONDS="${IDLE_SECONDS:-120}"
POLL_SECONDS=2
DBUS_RETRY_SECONDS=10
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOCK_FILE="${RUNTIME_DIR}/anticlockwise-watch-watcher.lock"
PROFILE_DIR="${RUNTIME_DIR}/anticlockwise-watch-profile"

log() {
  printf '%s [idle-watcher] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Print the GNOME idle time in milliseconds (last line of the dbus reply, integer after "uint64").
# Returns non-zero if dbus-send fails or the reply cannot be parsed.
get_idle_ms() {
  local out last ms
  if ! out="$(dbus-send --print-reply --dest=org.gnome.Mutter.IdleMonitor \
      /org/gnome/Mutter/IdleMonitor/Core org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null)"; then
    return 1
  fi
  last="$(printf '%s\n' "$out" | tail -n 1)"
  ms="$(printf '%s\n' "$last" | sed -n 's/.*uint64[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p')"
  [[ "$ms" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ms"
}

# True if run.sh (by path) or the screensaver's Chrome (by its throwaway profile dir) is running.
run_sh_running() {
  pgrep -f -- "$RUN_SH" >/dev/null 2>&1 || pgrep -f -- "$PROFILE_DIR" >/dev/null 2>&1
}

# Interruptible sleep: a foreground "sleep" would delay trap handling until it finishes.
nap() {
  sleep "$1" &
  wait "$!" || true
}

if ! [[ "$IDLE_SECONDS" =~ ^[0-9]+$ ]]; then
  log "IDLE_SECONDS must be a non-negative integer (got '${IDLE_SECONDS}')"
  exit 2
fi
THRESHOLD_MS=$((IDLE_SECONDS * 1000))

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --once)
    if ! idle_ms="$(get_idle_ms)"; then
      log "could not read idle time from org.gnome.Mutter.IdleMonitor via dbus-send"
      printf 'idle_seconds=unknown threshold_seconds=%s run_sh_running=unknown would_launch=no error=dbus_failed\n' \
        "$IDLE_SECONDS"
      exit 1
    fi
    if run_sh_running; then running=yes; else running=no; fi
    would_launch=no
    if (( idle_ms >= THRESHOLD_MS )) && [[ "$running" == "no" ]]; then
      would_launch=yes
    fi
    printf 'idle_seconds=%s idle_ms=%s threshold_seconds=%s run_sh_running=%s would_launch=%s\n' \
      "$((idle_ms / 1000))" "$idle_ms" "$IDLE_SECONDS" "$running" "$would_launch"
    exit 0
    ;;
  "")
    ;;
  *)
    log "unknown argument: $1"
    usage >&2
    exit 2
    ;;
esac

# ---- loop mode -------------------------------------------------------------

if [[ ! -f "$RUN_SH" ]]; then
  log "run.sh not found at ${RUN_SH}"
  exit 1
fi

# Single instance of the watcher.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another idle-watcher.sh already holds ${LOCK_FILE}; exiting"
  exit 0
fi

child_pid=""
on_signal() {
  trap - INT TERM
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    log "signal received; stopping run.sh (pid ${child_pid})"
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  log "stopped"
  exit 0
}
trap on_signal INT TERM

log "started (pid $$); IDLE_SECONDS=${IDLE_SECONDS}; polling every ${POLL_SECONDS}s; run.sh=${RUN_SH}"

dbus_failed=0
while true; do
  if ! idle_ms="$(get_idle_ms)"; then
    if (( dbus_failed == 0 )); then
      log "could not read idle time from org.gnome.Mutter.IdleMonitor via dbus-send; retrying every ${DBUS_RETRY_SECONDS}s"
      dbus_failed=1
    fi
    nap "$DBUS_RETRY_SECONDS"
    continue
  fi
  if (( dbus_failed == 1 )); then
    log "idle time readable again"
    dbus_failed=0
  fi

  if (( idle_ms >= THRESHOLD_MS )); then
    if run_sh_running; then
      log "idle $((idle_ms / 1000))s >= ${IDLE_SECONDS}s but run.sh/screensaver already running; not launching"
    else
      log "idle $((idle_ms / 1000))s >= ${IDLE_SECONDS}s; launching ${RUN_SH}"
      bash "$RUN_SH" 9>&- &
      child_pid=$!
      rc=0
      wait "$child_pid" || rc=$?
      child_pid=""
      log "run.sh exited with status ${rc}"
      if (( rc != 0 )); then
        # Avoid a tight relaunch loop if run.sh keeps failing while the user stays idle.
        nap "$DBUS_RETRY_SECONDS"
      fi
    fi
  fi

  nap "$POLL_SECONDS"
done
