#!/usr/bin/env bash
# uninstall.sh - remove the GNOME autostart entry and stop a running idle-watcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_FILE="${HOME}/.config/autostart/anticlockwise-watch.desktop"
# idle-watcher.sh runs via "#!/usr/bin/env bash", so its command line is
# "bash /abs/path/idle-watcher.sh". Match only a bash process running THIS
# project's watcher, not editors/pagers/tails whose arguments mention the name.
WATCHER_RE_DIR="$(printf '%s' "${SCRIPT_DIR}" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
WATCHER_PATTERN="(^|/)bash .*${WATCHER_RE_DIR}/idle-watcher\\.sh( |$)"

if [[ -f "${DESKTOP_FILE}" ]]; then
  rm -f "${DESKTOP_FILE}"
  echo "Removed ${DESKTOP_FILE}"
else
  echo "No autostart entry at ${DESKTOP_FILE} (nothing to remove)"
fi

if pkill -f -- "${WATCHER_PATTERN}" 2>/dev/null; then
  echo "Stopped running idle-watcher.sh"
else
  echo "No running idle-watcher.sh found"
fi

echo "Uninstalled."
