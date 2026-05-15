#!/usr/bin/env bash
# Steady — uninstaller.
#
# Usage:
#
#   curl -fsSL https://raw.githubusercontent.com/FocusLane/steady-install/main/uninstall.sh | bash
#
# Default behaviour removes:
#   • /Applications/Steady.app
#   • ~/Library/LaunchAgents/com.steady.poc.plist (after launchctl bootout)
#
# Pass --purge to also wipe ~/.steady (the local SQLite database, logs, and
# telemetry token) and strip Steady's hook entries from
# ~/.claude/settings.json. Without --purge, the database and Claude Code
# hook entries are left in place — the hook entries are written so they
# silently no-op when Steady.app is missing, so it's safe to leave them.

set -euo pipefail

PURGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

INSTALL_PATH="/Applications/Steady.app"
AGENT_LABEL="com.steady.poc"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
STEADY_DIR="${HOME}/.steady"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }

# Unload the LaunchAgent first — otherwise launchd respawns Steady the moment
# we kill it, even after rm -rf on the bundle.
if [[ -f "$AGENT_PLIST" ]]; then
    say "Unloading LaunchAgent ${AGENT_LABEL}."
    launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
else
    say "No LaunchAgent at ${AGENT_PLIST}, skipping."
fi

if pgrep -f "${INSTALL_PATH}/Contents/MacOS/Steady" >/dev/null 2>&1; then
    say "Stopping running Steady process."
    pkill -f "${INSTALL_PATH}/Contents/MacOS/Steady" 2>/dev/null || true
    sleep 1
fi

if [[ -e "$INSTALL_PATH" ]]; then
    say "Removing ${INSTALL_PATH}."
    rm -rf "$INSTALL_PATH"
else
    say "No app bundle at ${INSTALL_PATH}, skipping."
fi

if (( PURGE )); then
    if [[ -d "$STEADY_DIR" ]]; then
        say "Removing ${STEADY_DIR} (local database, logs, config)."
        rm -rf "$STEADY_DIR"
    fi

    if [[ -f "$CLAUDE_SETTINGS" && -x /usr/bin/python3 ]]; then
        # Strip Steady hook entries — anything whose inner command mentions
        # steadyd.py. Matches HookInstaller.entryIsSteady on the Swift side.
        say "Stripping Steady hook entries from ${CLAUDE_SETTINGS}."
        /usr/bin/python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, sys, os, tempfile

path = sys.argv[1]
with open(path, "r") as f:
    try:
        root = json.load(f)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"settings.json is not valid JSON ({e}); not touching it.\n")
        sys.exit(0)

if not isinstance(root, dict):
    sys.stderr.write("settings.json top-level is not an object; not touching it.\n")
    sys.exit(0)

hooks = root.get("hooks")
if not isinstance(hooks, dict):
    sys.exit(0)


def entry_is_steady(entry):
    inner = entry.get("hooks") if isinstance(entry, dict) else None
    if not isinstance(inner, list):
        return False
    for item in inner:
        cmd = item.get("command") if isinstance(item, dict) else None
        if isinstance(cmd, str) and "steadyd.py" in cmd:
            return True
    return False


events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
for ev in events:
    arr = hooks.get(ev)
    if not isinstance(arr, list):
        continue
    arr = [e for e in arr if not entry_is_steady(e)]
    if arr:
        hooks[ev] = arr
    else:
        hooks.pop(ev, None)

if hooks:
    root["hooks"] = hooks
else:
    root.pop("hooks", None)

# Atomic write so a crashed editor doesn't corrupt the user's settings.
dir_ = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".settings-", suffix=".steady-tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(root, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
PY
    fi
fi

cat <<EOF

  Steady has been uninstalled.

EOF

if (( ! PURGE )); then
    cat <<EOF
  Left in place:
    • ${STEADY_DIR}/  — local database, logs, config
    • Claude Code hook entries (they silently no-op without Steady.app)

  To remove these too:
    curl -fsSL https://raw.githubusercontent.com/FocusLane/steady-install/main/uninstall.sh | bash -s -- --purge

EOF
fi
