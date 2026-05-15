#!/usr/bin/env bash
# Steady — One-Touch Install.
#
# Usage (from a terminal, no checkout required):
#
#   curl -fsSL https://raw.githubusercontent.com/FocusLane/steady-install/main/install.sh | bash
#
# Pin to a specific version:
#
#   curl -fsSL https://raw.githubusercontent.com/FocusLane/steady-install/main/install.sh | bash -s -- --version v0.1.0
#
# What this script does, in order:
#   1. Verifies macOS 14+ on Apple Silicon and that /usr/bin/python3 exists.
#   2. Downloads the latest (or pinned) Steady.app zip from
#      github.com/FocusLane/steady-install Releases.
#   3. Verifies the SHA-256 of the zip against the .sha256 sidecar from the
#      same release.
#   4. Stops and removes any prior Steady installation cleanly.
#   5. Unzips Steady.app into /Applications, strips Gatekeeper quarantine.
#   6. Installs a LaunchAgent at ~/Library/LaunchAgents/com.steady.poc.plist
#      so Steady starts at every login and respawns on crash.
#   7. Bootstraps the agent so Steady starts immediately.
#
# Source of this script lives in FocusLane/steady; the copy on the public
# steady-install repo is a mirror produced by scripts/release.sh.

set -euo pipefail

REPO_OWNER="FocusLane"
REPO_NAME="steady-install"
APP_NAME="Steady"
INSTALL_PATH="/Applications/${APP_NAME}.app"
AGENT_LABEL="com.steady.poc"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
STEADY_DIR="${HOME}/.steady"
RELEASES_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases"

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            if [[ -z "$VERSION" ]]; then
                echo "error: --version requires an argument (e.g. v0.1.0)" >&2
                exit 2
            fi
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# 1. Sanity checks. ----------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
    die "Steady installs on macOS only. Detected: $(uname -s)."
fi

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if (( OS_MAJOR < 14 )); then
    die "Steady requires macOS 14+ (Sonoma). Detected: ${OS_VERSION}."
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    die "Steady currently ships Apple Silicon (arm64) binaries only. Detected: ${ARCH}."
fi

if [[ ! -x /usr/bin/python3 ]]; then
    cat >&2 <<EOF
Steady's daemon runs on the system Python 3 that Xcode Command Line Tools
provides at /usr/bin/python3. It is missing on this Mac.

Run:    xcode-select --install

then re-run the Steady installer.
EOF
    exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
    warn "Claude Code CLI not found on PATH. Steady will install fine, but"
    warn "it has nothing to observe until you install Claude Code:"
    warn "  https://docs.claude.com/en/docs/claude-code/quickstart"
fi

# 2. Pick a release. ---------------------------------------------------------

api_get() {
    # GitHub anonymous API allows 60 requests/hour per IP — plenty for an
    # installer. -f returns non-zero on HTTP errors so set -e catches them.
    curl -fsSL -H "Accept: application/vnd.github+json" "$1"
}

if [[ -z "$VERSION" ]]; then
    say "Resolving latest release from ${REPO_OWNER}/${REPO_NAME}…"
    RELEASE_JSON="$(api_get "${RELEASES_API}/latest")"
else
    say "Resolving release ${VERSION} from ${REPO_OWNER}/${REPO_NAME}…"
    RELEASE_JSON="$(api_get "${RELEASES_API}/tags/${VERSION}")"
fi

# Parse with python3 — we already require it for the daemon, so it's
# guaranteed to be present at this point.
parse_release() {
    /usr/bin/python3 - "$1" <<'PY'
import json, sys
data = json.loads(sys.stdin.read())
field = sys.argv[1]
if field == "tag_name":
    print(data.get("tag_name", ""))
elif field == "zip_url":
    for a in data.get("assets", []):
        if a["name"].endswith(".zip"):
            print(a["browser_download_url"])
            break
elif field == "sha_url":
    for a in data.get("assets", []):
        if a["name"].endswith(".sha256"):
            print(a["browser_download_url"])
            break
PY
}

TAG="$(printf '%s' "$RELEASE_JSON" | parse_release tag_name)"
ZIP_URL="$(printf '%s' "$RELEASE_JSON" | parse_release zip_url)"
SHA_URL="$(printf '%s' "$RELEASE_JSON" | parse_release sha_url)"

if [[ -z "$TAG" || -z "$ZIP_URL" || -z "$SHA_URL" ]]; then
    die "Release JSON did not include a .zip + .sha256 asset pair. Check the release page on GitHub."
fi

say "Installing ${APP_NAME} ${TAG}."

# 3. Download + verify. ------------------------------------------------------

TMP="$(mktemp -d -t steady-install)"
trap 'rm -rf "$TMP"' EXIT

ZIP_NAME="$(basename "$ZIP_URL")"
SHA_NAME="$(basename "$SHA_URL")"

curl -fsSL -o "${TMP}/${ZIP_NAME}" "$ZIP_URL"
curl -fsSL -o "${TMP}/${SHA_NAME}" "$SHA_URL"

say "Verifying SHA-256…"
(
    cd "$TMP"
    if ! shasum -a 256 -c "$SHA_NAME" >/dev/null; then
        die "SHA-256 mismatch on ${ZIP_NAME}. Aborting before unzip."
    fi
)
say "Checksum OK."

# 4. Stop + remove prior installation. --------------------------------------

if [[ -f "$AGENT_PLIST" ]]; then
    say "Unloading existing LaunchAgent."
    # bootout returns non-zero if the agent isn't loaded — that's fine, we
    # just want it gone before swapping the binary underneath.
    launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
fi

if pgrep -f "${INSTALL_PATH}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    say "Stopping running Steady process."
    pkill -f "${INSTALL_PATH}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    # Give launchd / the app a beat to flush the socket cleanup.
    sleep 1
fi

if [[ -e "$INSTALL_PATH" ]]; then
    say "Removing existing ${INSTALL_PATH}."
    rm -rf "$INSTALL_PATH"
fi

# 5. Install the new bundle. -------------------------------------------------

say "Unpacking ${ZIP_NAME} into /Applications."
# `ditto -xk` is the symmetric reader for `ditto -c -k` (what release.sh uses)
# — it preserves bundle metadata and silently drops the __MACOSX
# resource-fork sidecars instead of leaving them as a sibling directory in
# /Applications the way plain `unzip` does.
ditto -xk "${TMP}/${ZIP_NAME}" /Applications

if [[ ! -d "$INSTALL_PATH" ]]; then
    die "Expected ${INSTALL_PATH} after unzip, not found. Zip layout may have changed."
fi

# Gatekeeper bypass for an unsigned build. We're not signed with a Developer
# ID (yet); without this, the first launch shows a "cannot be opened" dialog.
say "Stripping Gatekeeper quarantine attribute."
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

# 6. LaunchAgent. ------------------------------------------------------------

mkdir -p "$STEADY_DIR"
mkdir -p "$(dirname "$AGENT_PLIST")"

say "Writing LaunchAgent at ${AGENT_PLIST}."
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_PATH}/Contents/MacOS/${APP_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${STEADY_DIR}/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${STEADY_DIR}/launchd.err.log</string>
</dict>
</plist>
PLIST

chmod 644 "$AGENT_PLIST"

# 7. Boot the agent. ---------------------------------------------------------

say "Loading the LaunchAgent and starting Steady."
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
# kickstart is a no-op if the agent already started via RunAtLoad; it ensures
# we don't have to wait for the next login on a fresh install.
launchctl kickstart -k "gui/$(id -u)/${AGENT_LABEL}" >/dev/null 2>&1 || true

# 8. Done. -------------------------------------------------------------------

cat <<EOF

  Steady ${TAG} installed.

  • App:           ${INSTALL_PATH}
  • Auto-start:    ${AGENT_PLIST}
  • Logs:          ${STEADY_DIR}/launchd.{out,err}.log
  • Local data:    ${STEADY_DIR}/steady.db

  Next step: click the Steady icon in your menubar, then "Setup" to wire
  Steady's hooks into Claude Code (~/.claude/settings.json).

  To uninstall:
    curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/uninstall.sh | bash

EOF
