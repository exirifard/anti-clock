#!/usr/bin/env bash
# setup-xscreensaver.sh - run Anti-Clock as a real xscreensaver
# "hack" (so it also shows while the screen is LOCKED) and point GNOME at
# xscreensaver instead of its own lock screen.
#
# Usage:
#   ./setup-xscreensaver.sh              apply everything
#   DRY_RUN=1 ./setup-xscreensaver.sh    print every action and the exact files
#                                        that would be written; change NOTHING
#
# Environment:
#   DRY_RUN       1 = describe only, change nothing            (default 0)
#   IDLE_MINUTES  idle minutes before the saver starts         (default 2)
#   LOCK          True/False - lock when the saver starts      (default True)
#   LOCK_TIMEOUT  H:MM:SS grace period before locking          (default 0:00:00)
#   STATE_DIR     where the GNOME settings backup is kept
#                 (default ~/.config/anticlockwise-watch)
#
# Revert with: ./teardown-xscreensaver.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
HACK="${SCRIPT_DIR}/anticlock-watch.py"
HACK_NAME="Anti-Clock"
WRAPPER="/usr/share/xscreensaver/xscreensaver-wrapper.sh"
CHROME_UNINSTALL="${PROJECT_DIR}/uninstall.sh"
CHROME_DESKTOP="${HOME}/.config/autostart/anticlockwise-watch.desktop"
AUTOSTART_DIR="${HOME}/.config/autostart"
AUTOSTART_FILE="${AUTOSTART_DIR}/xscreensaver.desktop"
XSS_FILE="${HOME}/.xscreensaver"

DRY_RUN="${DRY_RUN:-0}"
IDLE_MINUTES="${IDLE_MINUTES:-2}"
LOCK="${LOCK:-True}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-0:00:00}"
STATE_DIR="${STATE_DIR:-${HOME}/.config/anticlockwise-watch}"
BACKUP_FILE="${STATE_DIR}/gnome-settings.backup"

MK_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
KB_SCHEMA="${MK_SCHEMA}.custom-keybinding"
KB_BASE="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
KB_NAME="Lock screen (XScreenSaver)"
KB_COMMAND="xscreensaver-command -lock"
KB_BINDING="<Super>l"

# ---------------------------------------------------------------- helpers ---
die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }
note() { echo "   $*"; }

# Shell-quote arguments for display: bare when safe, "double" when the value
# only contains single quotes/spaces/brackets, 'single' (escaped) otherwise.
fmt_cmd() {
  local out="" a q
  for a in "$@"; do
    if [[ "${a}" =~ ^[A-Za-z0-9_./:=@+-]+$ ]]; then
      out+="${a} "
    elif [[ "${a}" != *[\"\$\`\\]* ]]; then
      out+="\"${a}\" "
    else
      q="${a//\'/\'\\\'\'}"
      out+="'${q}' "
    fi
  done
  printf '%s' "${out% }"
}

# run CMD ARGS... - execute, or in DRY_RUN only print the exact command.
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   [dry-run] would run: $(fmt_cmd "$@")"
  else
    echo "   + $(fmt_cmd "$@")"
    "$@"
  fi
}

# gset SCHEMA[:PATH] KEY VALUE
gset() { run gsettings set "$1" "$2" "$3"; }

# has_key SCHEMA KEY - true when the installed schema defines KEY.
has_key() { gsettings list-keys "$1" 2>/dev/null | grep -qx -- "$2"; }

# write_file PATH CONTENT - write CONTENT (+ trailing newline), or print it.
write_file() {
  local path="$1" content="$2"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   [dry-run] would write ${path} with this exact content:"
    echo "----8<---- ${path} ----8<----"
    printf '%s\n' "${content}"
    echo "---->8---- end of ${path} ---->8----"
  else
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' "${content}" > "${path}"
    echo "   wrote ${path}"
  fi
}

# ------------------------------------------------------- validate options ---
[[ "${IDLE_MINUTES}" =~ ^[1-9][0-9]*$ ]] \
  || die "IDLE_MINUTES must be a positive integer (got '${IDLE_MINUTES}')"
case "${LOCK}" in
  [Tt]rue)  LOCK="True"  ;;
  [Ff]alse) LOCK="False" ;;
  *) die "LOCK must be True or False (got '${LOCK}')" ;;
esac
[[ "${LOCK_TIMEOUT}" =~ ^[0-9]+:[0-5][0-9]:[0-5][0-9]$ ]] \
  || die "LOCK_TIMEOUT must look like H:MM:SS (got '${LOCK_TIMEOUT}')"
TIMEOUT="$(printf '%d:%02d:00' "$((IDLE_MINUTES / 60))" "$((IDLE_MINUTES % 60))")"

echo "Anti-Clock - xscreensaver setup"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY RUN - nothing will be changed; every action is only printed."
fi
note "idle timeout : ${TIMEOUT}  (IDLE_MINUTES=${IDLE_MINUTES})"
note "lock         : ${LOCK}  (LOCK_TIMEOUT=${LOCK_TIMEOUT})"
note "state dir    : ${STATE_DIR}"
note "hack         : ${HACK}"

# ------------------------------------------------------ 1. preconditions ---
step "1/8 Checking preconditions"
for cmd in xscreensaver xscreensaver-command gsettings python3; do
  command -v "${cmd}" >/dev/null 2>&1 \
    || die "'${cmd}' not found in PATH (install it, e.g. sudo apt install xscreensaver)."
  note "found $(command -v "${cmd}")"
done
[[ -x "${WRAPPER}" ]] \
  || die "${WRAPPER} is missing or not executable (it ships with the Debian xscreensaver package)."
[[ -f "${HACK}" ]] || die "hack not found: ${HACK}"
[[ -x "${HACK}" ]] || die "hack is not executable: ${HACK}   (fix: chmod +x '${HACK}')"
note "hack is executable: ${HACK}"
python3 -c "import gi, cairo" 2>/dev/null \
  || die "python3 cannot 'import gi, cairo' (install python3-gi python3-gi-cairo python3-cairo)."
note "python3 can import gi and cairo"
if [[ -z "${DISPLAY:-}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "WARNING: DISPLAY is not set; the real run must happen inside the graphical session."
  else
    die "DISPLAY is not set; run this from a terminal inside your graphical session."
  fi
fi
note "preconditions ok"

# ---------------------------------------- 2. back up + change GNOME keys ---
step "2/8 Backing up and changing GNOME settings"
BACKUP_KEYS=(
  "org.gnome.desktop.screensaver lock-enabled"
  "org.gnome.desktop.session idle-delay"
  "${MK_SCHEMA} screensaver"
  "${MK_SCHEMA} custom-keybindings"
)
HAVE_IDLE_ACT=0
if has_key org.gnome.desktop.screensaver idle-activation-enabled; then
  HAVE_IDLE_ACT=1
  BACKUP_KEYS+=("org.gnome.desktop.screensaver idle-activation-enabled")
fi
# Ubuntu's gnome-shell locks on suspend when this key is true, regardless of
# lock-enabled; it would race xscreensaver-systemd for the input grab.
HAVE_LOCK_ON_SUSPEND=0
if has_key org.gnome.desktop.screensaver ubuntu-lock-on-suspend; then
  HAVE_LOCK_ON_SUSPEND=1
  BACKUP_KEYS+=("org.gnome.desktop.screensaver ubuntu-lock-on-suspend")
fi
# gnome-shell's screenShield.lock() honours only this lockdown key (lock-enabled
# governs automatic locking only), so it is what keeps the top-bar Lock button,
# "loginctl lock-session" and the ScreenSaver D-Bus Lock() off GNOME's shield.
HAVE_LOCKDOWN=0
if has_key org.gnome.desktop.lockdown disable-lock-screen; then
  HAVE_LOCKDOWN=1
  BACKUP_KEYS+=("org.gnome.desktop.lockdown disable-lock-screen")
fi

note "current values:"
for entry in "${BACKUP_KEYS[@]}"; do
  schema="${entry% *}"; key="${entry#* }"
  note "  ${schema} ${key} = $(gsettings get "${schema}" "${key}")"
done

if [[ -f "${BACKUP_FILE}" ]]; then
  note "backup already exists, keeping the ORIGINAL values in ${BACKUP_FILE}"
  # A key missing from an older backup has never been changed by this script,
  # so its current value is still the original one: record it before changing it.
  for entry in "${BACKUP_KEYS[@]}"; do
    schema="${entry% *}"; key="${entry#* }"
    if ! grep -q -- "^${schema} ${key} " "${BACKUP_FILE}"; then
      line="${schema} ${key} $(gsettings get "${schema}" "${key}")"
      if [[ "${DRY_RUN}" == "1" ]]; then
        echo "   [dry-run] would append to ${BACKUP_FILE}: ${line}"
      else
        printf '%s\n' "${line}" >> "${BACKUP_FILE}"
        note "appended to ${BACKUP_FILE}: ${line}"
      fi
    fi
  done
else
  backup_content=""
  for entry in "${BACKUP_KEYS[@]}"; do
    schema="${entry% *}"; key="${entry#* }"
    backup_content+="${schema} ${key} $(gsettings get "${schema}" "${key}")"$'\n'
  done
  write_file "${BACKUP_FILE}" "${backup_content%$'\n'}"
fi

gset org.gnome.desktop.screensaver lock-enabled false
gset org.gnome.desktop.session idle-delay 0
gset "${MK_SCHEMA}" screensaver "['']"
if (( HAVE_IDLE_ACT )); then
  gset org.gnome.desktop.screensaver idle-activation-enabled false
else
  note "org.gnome.desktop.screensaver has no idle-activation-enabled key here; skipping"
fi
if (( HAVE_LOCK_ON_SUSPEND )); then
  # only xscreensaver-systemd (xscreensaver-command -suspend) should lock on suspend
  gset org.gnome.desktop.screensaver ubuntu-lock-on-suspend false
else
  note "org.gnome.desktop.screensaver has no ubuntu-lock-on-suspend key here; skipping"
fi
if (( HAVE_LOCKDOWN )); then
  # hides the top-bar Lock button; login1 Lock -> xscreensaver-systemd -> xscreensaver-command -lock
  gset org.gnome.desktop.lockdown disable-lock-screen true
else
  note "org.gnome.desktop.lockdown has no disable-lock-screen key here; skipping"
fi
note "NOTE: power settings are NOT touched. If the machine should not suspend while the"
note "      watch is showing, check Settings > Power > Automatic Suspend (currently"
note "      sleep-inactive-ac-type = $(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo '?'))."

# ------------------------------------------- 3. Super+L custom keybinding ---
step "3/8 Binding ${KB_BINDING} to '${KB_COMMAND}'"
current_list="$(gsettings get "${MK_SCHEMA}" custom-keybindings)"
note "current custom-keybindings: ${current_list}"
kb_lines="$(python3 -c '
import ast, sys
raw = sys.argv[1].strip()
if raw.startswith("@as"):
    raw = raw[3:].strip()
for p in ast.literal_eval(raw or "[]"):
    print(p)
' "${current_list}")"
kb_paths=()
if [[ -n "${kb_lines}" ]]; then
  mapfile -t kb_paths <<< "${kb_lines}"
fi

KB_PATH=""
for p in "${kb_paths[@]}"; do
  existing_name="$(gsettings get "${KB_SCHEMA}:${p}" name 2>/dev/null || true)"
  if [[ "${existing_name}" == "'${KB_NAME}'" ]]; then
    KB_PATH="${p}"
    break
  fi
done

NEED_APPEND=0
if [[ -n "${KB_PATH}" ]]; then
  note "reusing existing slot named '${KB_NAME}': ${KB_PATH}"
else
  n=0
  while :; do
    candidate="${KB_BASE}/custom${n}/"
    used=0
    for p in "${kb_paths[@]}"; do
      if [[ "${p}" == "${candidate}" ]]; then used=1; fi
    done
    if (( used == 0 )); then break; fi
    n=$((n + 1))
  done
  KB_PATH="${candidate}"
  NEED_APPEND=1
  note "using new slot ${KB_PATH}"
fi

gset "${KB_SCHEMA}:${KB_PATH}" name    "'${KB_NAME}'"
gset "${KB_SCHEMA}:${KB_PATH}" command "'${KB_COMMAND}'"
gset "${KB_SCHEMA}:${KB_PATH}" binding "'${KB_BINDING}'"
if (( NEED_APPEND )); then
  new_list="$(python3 -c '
import ast, sys
raw = sys.argv[1].strip()
if raw.startswith("@as"):
    raw = raw[3:].strip()
lst = list(ast.literal_eval(raw or "[]"))
if sys.argv[2] not in lst:
    lst.append(sys.argv[2])
print(repr(lst))
' "${current_list}" "${KB_PATH}")"
  gset "${MK_SCHEMA}" custom-keybindings "${new_list}"
else
  note "slot already listed in custom-keybindings; list unchanged"
fi

# ------------------------------------------------- 4. ~/.xscreensaver file ---
step "4/8 Writing ${XSS_FILE}"
# Same "first run only" rule as the GNOME backup: only a file that is NOT our own
# output gets a .bak copy (teardown restores the newest non-setup .bak).
SETUP_HEADER='^# Written by setup-xscreensaver.sh'
if [[ -f "${XSS_FILE}" ]] && ! grep -q "${SETUP_HEADER}" "${XSS_FILE}"; then
  xss_backup="${XSS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  note "existing ${XSS_FILE} (not written by this script) found; backing it up first"
  run cp -p "${XSS_FILE}" "${xss_backup}"
elif [[ -f "${XSS_FILE}" ]]; then
  note "existing ${XSS_FILE} was written by this script; overwriting without a new backup"
else
  note "no existing ${XSS_FILE}"
fi

# Real TAB characters follow the colons (same layout as the app-defaults file).
# Placeholders are substituted below; the heredoc is quoted so the backslashes
# of the programs block are written literally (each entry ends in: \n\ ).
xss_content="$(cat <<'XSS_EOF'
# XScreenSaver Preferences File
# Written by setup-xscreensaver.sh (Anti-Clock). Edit with xscreensaver-settings.

mode:				one
selected:			0
timeout:			@TIMEOUT@
cycle:				0:00:00
lock:				@LOCK@
lockTimeout:			@LOCK_TIMEOUT@
passwdTimeout:			0:00:30
dpmsEnabled:			True
dpmsStandby:			0:30:00
dpmsSuspend:			0:45:00
dpmsOff:			1:00:00
fade:				True
unfade:				True
splash:				False
grabDesktopImages:		False
chooseRandomImages:		False
ignoreUninstalledPrograms:	True

programs:								      \
				"@HACK_NAME@" @HACK@   \n\

XSS_EOF
)"
# The replacements are quoted: with bash 5.2's patsub_replacement an unquoted
# replacement would turn an '&' in a path into the matched placeholder text.
xss_content="${xss_content//@TIMEOUT@/"${TIMEOUT}"}"
xss_content="${xss_content//@LOCK_TIMEOUT@/"${LOCK_TIMEOUT}"}"
xss_content="${xss_content//@LOCK@/"${LOCK}"}"
xss_content="${xss_content//@HACK_NAME@/"${HACK_NAME}"}"
xss_content="${xss_content//@HACK@/"${HACK}"}"
xss_content+=$'\n'   # blank line terminates the programs continuation block
write_file "${XSS_FILE}" "${xss_content}"

# ---------------------------------------------------- 5. GNOME autostart ---
step "5/8 Autostart entry ${AUTOSTART_FILE}"
note "(the stock /etc/xdg/autostart/xscreensaver.desktop has OnlyShowIn=XFCE, so GNOME needs its own)"
autostart_content="[Desktop Entry]
Type=Application
Name=XScreenSaver
Comment=Start the XScreenSaver daemon (Anti-Clock screensaver and screen locker)
Exec=${WRAPPER} -no-splash
Terminal=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=false"
write_file "${AUTOSTART_FILE}" "${autostart_content}"

# ------------------------------------------ 6. retire the Chrome watcher ---
step "6/8 Retiring the old Chrome idle watcher (two screensavers would fight)"
# Same process pattern as uninstall.sh: a bash running THIS project's watcher.
WATCHER_RE_DIR="$(printf '%s' "${PROJECT_DIR}" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
WATCHER_PATTERN="(^|/)bash .*${WATCHER_RE_DIR}/idle-watcher\\.sh( |$)"
watcher_pids="$(pgrep -f -- "${WATCHER_PATTERN}" 2>/dev/null | tr '\n' ' ' || true)"
retire=0
if [[ -f "${CHROME_DESKTOP}" ]]; then
  note "found autostart entry ${CHROME_DESKTOP}"
  retire=1
fi
if [[ -n "${watcher_pids// /}" ]]; then
  note "found running idle-watcher.sh (pid ${watcher_pids% })"
  retire=1
fi
if (( retire )); then
  [[ -x "${CHROME_UNINSTALL}" ]] \
    || die "${CHROME_UNINSTALL} is missing or not executable; cannot retire the Chrome watcher."
  run "${CHROME_UNINSTALL}"
else
  note "no Chrome watcher autostart entry and no watcher process; nothing to retire"
fi

# ------------------------------------------- 7. start / reload the daemon ---
step "7/8 Starting (or reloading) the xscreensaver daemon"
if xscreensaver-command -time >/dev/null 2>&1; then
  note "daemon is already running; restarting it so it re-reads ${XSS_FILE}"
  run xscreensaver-command -restart
else
  note "daemon is not running; starting it detached"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   [dry-run] would run: nohup ${WRAPPER} -no-splash >/dev/null 2>&1 & disown"
  else
    echo "   + nohup ${WRAPPER} -no-splash >/dev/null 2>&1 & disown"
    nohup "${WRAPPER}" -no-splash >/dev/null 2>&1 &
    disown
  fi
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "   [dry-run] would run: sleep 2; xscreensaver-command -time"
else
  sleep 2
  echo "   + xscreensaver-command -time"
  if ! xscreensaver-command -time; then
    echo "WARNING: xscreensaver-command -time failed; the daemon may not have started." >&2
    echo "         Try by hand: ${WRAPPER} -no-splash   (then xscreensaver-command -time)" >&2
  fi
fi

# ---------------------------------------------------------- 8. summary ---
step "8/8 Summary"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY RUN complete - nothing was changed. Re-run without DRY_RUN=1 to apply."
  echo
fi
# What happened to GNOME's own lock screen (it cannot show the watch and competes
# with xscreensaver for the X input grab, so it must stay out of the way).
gnome_lock_note="GNOME's own lock screen cannot show the watch and competes with xscreensaver for the
      input grab, so it is kept out of the way: no automatic lock (lock-enabled=false)"
if (( HAVE_LOCK_ON_SUSPEND )); then
  gnome_lock_note+=",
      no GNOME lock on suspend (ubuntu-lock-on-suspend=false; xscreensaver-systemd locks instead)"
fi
if (( HAVE_LOCKDOWN )); then
  gnome_lock_note+=",
      and the top-bar Lock button is hidden (lockdown disable-lock-screen=true)."
else
  gnome_lock_note+=".
      The top-bar Lock button and 'loginctl lock-session' still raise GNOME's shield (no watch)."
fi
if [[ "${LOCK}" == "True" ]]; then
  deactivate_note='when locked it only brings up the password dialog'
else
  deactivate_note='ends the saver (LOCK=False: nothing is locked)'
fi
cat <<SUMMARY
Saver starts after : ${IDLE_MINUTES} minute(s) idle  (timeout: ${TIMEOUT})
Lock               : ${LOCK}  (lockTimeout: ${LOCK_TIMEOUT}$( [[ "${LOCK}" == "True" && "${LOCK_TIMEOUT}" == "0:00:00" ]] && echo " = locked as soon as the saver starts" ))
Hack               : "${HACK_NAME}" ${HACK}
Config             : ${XSS_FILE}
Autostart          : ${AUTOSTART_FILE}
GNOME backup       : ${BACKUP_FILE}

Test it NOW (safely):
  xscreensaver-command -activate      shows the saver immediately
                                      (with LOCK=True you need your password to get back)
  xscreensaver-command -deactivate    ${deactivate_note}
  xscreensaver-command -lock          lock right away (same as Super+L now)
  xscreensaver-settings               GUI: preview, timing, hack list
  ${HACK} --window
                                      the hack standalone in a normal window (Esc/q quits)

If you cannot unlock (e.g. PAM trouble), from another VT (Ctrl+Alt+F3) or an ssh session run:
  pkill -TERM -x xscreensaver         plain SIGTERM: the daemon unblanks and exits gracefully.
                                      NEVER use kill -9 on it. Note that while the screen is
                                      locked "xscreensaver-command -exit" is refused and
                                      "-deactivate" only shows the password dialog.
  Afterwards restart it with:         ${WRAPPER} -no-splash &

Keyboard: Super+L now runs "${KB_COMMAND}" (GNOME's own Super+L lock was unbound).
NOTE: ${gnome_lock_note}
      Lock with Super+L or xscreensaver-command -lock.
Revert everything with: ${SCRIPT_DIR}/teardown-xscreensaver.sh
SUMMARY
