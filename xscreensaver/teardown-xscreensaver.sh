#!/usr/bin/env bash
# teardown-xscreensaver.sh - revert everything setup-xscreensaver.sh did.
#   DRY_RUN=1   print every action, change nothing
#   STATE_DIR   where setup stored its backup (default ~/.config/anticlockwise-watch)
set -euo pipefail

# Repository root (the directory above this script)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN="${DRY_RUN:-0}"
STATE_DIR="${STATE_DIR:-$HOME/.config/anticlockwise-watch}"
BACKUP_FILE="$STATE_DIR/gnome-settings.backup"
AUTOSTART_FILE="$HOME/.config/autostart/xscreensaver.desktop"
XSS_CONF="$HOME/.xscreensaver"
KB_NAME="Lock screen (XScreenSaver)"
KB_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
KB_SUBSCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# run <cmd...>: execute, or echo in dry-run mode
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] %s\n' "$(printf '%q ' "$@")"
  else
    "$@"
  fi
}

gset() {  # gset <schema[:path]> <key> <value>
  if [ "$DRY_RUN" = "1" ]; then
    note "[dry-run] gsettings set $1 $2 $3"
  else
    gsettings set "$1" "$2" "$3"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

if ! have gsettings; then
  echo "ERROR: gsettings not found" >&2; exit 1
fi
[ "$DRY_RUN" = "1" ] && say "DRY RUN: nothing will be changed"

# ---------------------------------------------------------------- 1. gsettings
say "Step 1: restore GNOME settings"
used_backup=0
restored_idle_act=0   # set when the backup itself restored idle-activation-enabled
if [ -f "$BACKUP_FILE" ]; then
  note "using backup $BACKUP_FILE"
  used_backup=1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    schema="${line%% *}"; rest="${line#* }"
    key="${rest%% *}"; value="${rest#* }"
    if [ -z "$schema" ] || [ -z "$key" ] || [ -z "$value" ] || [ "$rest" = "$key" ]; then
      note "skipping malformed backup line: $line"; continue
    fi
    # custom-keybindings is handled in step 2 (we only remove our own slot)
    if [ "$schema" = "$KB_SCHEMA" ] && [ "$key" = "custom-keybindings" ]; then
      note "custom-keybindings handled in step 2 (backup value: $value)"; continue
    fi
    if [ "$schema" = "org.gnome.desktop.screensaver" ] && [ "$key" = "idle-activation-enabled" ]; then
      restored_idle_act=1
    fi
    gset "$schema" "$key" "$value"
  done < "$BACKUP_FILE"
else
  note "no backup at $BACKUP_FILE; restoring Ubuntu defaults"
  gset org.gnome.desktop.screensaver lock-enabled true
  gset org.gnome.desktop.session idle-delay 300
  if gsettings list-keys org.gnome.desktop.screensaver 2>/dev/null | grep -qx ubuntu-lock-on-suspend; then
    gset org.gnome.desktop.screensaver ubuntu-lock-on-suspend true
  fi
  if gsettings list-keys org.gnome.desktop.lockdown 2>/dev/null | grep -qx disable-lock-screen; then
    gset org.gnome.desktop.lockdown disable-lock-screen false
  fi
  gset "$KB_SCHEMA" screensaver "['<Super>l']"
fi
# Default for idle-activation-enabled only when the backup did not cover it.
if [ "$restored_idle_act" = "0" ] \
   && gsettings list-keys org.gnome.desktop.screensaver 2>/dev/null | grep -qx idle-activation-enabled; then
  gset org.gnome.desktop.screensaver idle-activation-enabled true
fi

# ---------------------------------------------------- 2. custom keybinding slot
say "Step 2: remove custom keybinding \"$KB_NAME\""
current_list="$(gsettings get "$KB_SCHEMA" custom-keybindings 2>/dev/null || echo '@as []')"
mapfile -t paths < <(python3 -c '
import ast, sys
v = sys.argv[1].strip()
if v.startswith("@as"): v = v[3:].strip()
for p in ast.literal_eval(v or "[]"): print(p)
' "$current_list")
found=()
keep=()
for p in "${paths[@]}"; do
  n="$(gsettings get "$KB_SUBSCHEMA:$p" name 2>/dev/null || echo "''")"
  if [ "$n" = "'$KB_NAME'" ]; then found+=("$p"); else keep+=("$p"); fi
done
if [ "${#found[@]}" -eq 0 ]; then
  note "no slot named \"$KB_NAME\" found; nothing to remove"
else
  for p in "${found[@]}"; do
    note "removing slot $p"
    if [ "$DRY_RUN" = "1" ]; then
      note "[dry-run] gsettings reset $KB_SUBSCHEMA:$p name/command/binding"
    else
      gsettings reset "$KB_SUBSCHEMA:$p" name    || true
      gsettings reset "$KB_SUBSCHEMA:$p" command || true
      gsettings reset "$KB_SUBSCHEMA:$p" binding || true
    fi
  done
  new_list="$(python3 -c '
import sys; print(repr(sys.argv[1:]) if len(sys.argv) > 1 else "@as []")
' "${keep[@]}")"
  gset "$KB_SCHEMA" custom-keybindings "$new_list"
fi

# ------------------------------------------------------------- 3. autostart
say "Step 3: remove autostart entry $AUTOSTART_FILE"
if [ -f "$AUTOSTART_FILE" ]; then
  run rm -f "$AUTOSTART_FILE"
else
  note "not present"
fi

# ---------------------------------------------------------------- 4. daemon
say "Step 4: stop xscreensaver daemon"
if have xscreensaver-command && xscreensaver-command -time >/dev/null 2>&1; then
  run xscreensaver-command -exit
else
  note "daemon not running"
fi

# -------------------------------------------------------- 5. ~/.xscreensaver
say "Step 5: restore $XSS_CONF"
# Setup backs up ANY existing ~/.xscreensaver, including the one it wrote itself
# on an earlier run, so the newest .bak may be our own generated config. Pick the
# newest backup that does NOT carry setup's header; drop the ones that do.
SETUP_HEADER='^# Written by setup-xscreensaver.sh'
mapfile -t baks < <(ls -1t "$XSS_CONF".bak.* 2>/dev/null || true)
newest_bak=""
for f in "${baks[@]}"; do
  [ -f "$f" ] || continue
  if grep -q "$SETUP_HEADER" "$f"; then
    note "discarding setup-generated backup $f"
    run rm -f "$f"
  elif [ -z "$newest_bak" ]; then
    newest_bak="$f"
  fi
done
if [ -n "$newest_bak" ]; then
  note "restoring $newest_bak"
  run mv -f "$newest_bak" "$XSS_CONF"
elif [ -f "$XSS_CONF" ]; then
  note "no pre-setup backup; removing $XSS_CONF"
  run rm -f "$XSS_CONF"
else
  note "no $XSS_CONF and no backup; nothing to do"
fi

# -------------------------------------------------------------- 6. summary
if [ "$used_backup" = "1" ]; then
  # Move the consumed backup aside: setup only snapshots when no backup exists,
  # so leaving it live would make a later setup/teardown restore stale values.
  retired="$BACKUP_FILE.restored-$(date +%Y%m%d-%H%M%S)"
  run mv -f "$BACKUP_FILE" "$retired"
fi

say "Done."
note "GNOME lock screen / idle settings restored; xscreensaver autostart removed."
if [ "$used_backup" = "1" ]; then
  note "Consumed backup moved to $retired (kept for inspection; safe to delete)."
fi
note "To re-enable the old Chrome-kiosk watcher: $REPO_DIR/install.sh"
