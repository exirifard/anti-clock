#!/usr/bin/env bash
# install.sh - register the anticlockwise watch idle-watcher as a GNOME autostart entry.
# Usage: ./install.sh            (installs)
#        DRY_RUN=1 ./install.sh  (prints what it would write, changes nothing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="${SCRIPT_DIR}/idle-watcher.sh"
AUTOSTART_DIR="${HOME}/.config/autostart"
DESKTOP_FILE="${AUTOSTART_DIR}/anticlockwise-watch.desktop"
DRY_RUN="${DRY_RUN:-0}"

# Quote the Exec path if it contains spaces (desktop-entry spec allows double quotes).
EXEC_PATH="${WATCHER}"
case "${EXEC_PATH}" in
  *" "*) EXEC_PATH="\"${EXEC_PATH}\"" ;;
esac

DESKTOP_CONTENT="[Desktop Entry]
Type=Application
Name=Anticlockwise Watch Screensaver
Comment=Launches the anticlockwise watch screensaver after the session has been idle
Exec=${EXEC_PATH}
Terminal=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=false"

SCRIPTS=("run.sh" "idle-watcher.sh" "install.sh" "uninstall.sh")

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY RUN - nothing will be written."
  echo "Would chmod +x:"
  for s in "${SCRIPTS[@]}"; do
    echo "  ${SCRIPT_DIR}/${s}"
  done
  echo "Would mkdir -p ${AUTOSTART_DIR}"
  echo "Would write ${DESKTOP_FILE} with contents:"
  echo "----------------------------------------"
  echo "${DESKTOP_CONTENT}"
  echo "----------------------------------------"
else
  for s in "${SCRIPTS[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${s}" ]]; then
      chmod +x "${SCRIPT_DIR}/${s}"
    else
      echo "warning: ${SCRIPT_DIR}/${s} not found, skipping chmod" >&2
    fi
  done
  mkdir -p "${AUTOSTART_DIR}"
  printf '%s\n' "${DESKTOP_CONTENT}" > "${DESKTOP_FILE}"
  echo "Wrote ${DESKTOP_FILE}"
fi

echo
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "Dry run complete (nothing installed). After installing, start now with: nohup ${WATCHER} >/dev/null 2>&1 &"
else
  echo "Installed. Start now: nohup ${WATCHER} >/dev/null 2>&1 &"
fi
echo
echo "NOTE: GNOME itself blanks the screen after 300 s (org.gnome.desktop.session idle-delay = 300)."
echo "      IDLE_SECONDS for idle-watcher.sh (default 120) must stay below that, or disable GNOME blanking with:"
echo "        gsettings set org.gnome.desktop.session idle-delay 0"
echo "      This installer does NOT change gsettings."
