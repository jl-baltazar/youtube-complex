#!/bin/bash
# Ensures the NAS SMB share is mounted. Idempotent — safe to run on a timer.
# Uses AppleScript (Finder) which works in user session even when launchd-invoked.

set -u

# Load NAS credentials from gitignored env file (see config/nas.env.example)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_ENV="${SCRIPT_DIR}/../config/nas.env"
# shellcheck source=/dev/null
[[ -f "$NAS_ENV" ]] && source "$NAS_ENV"
NAS_USER="${NAS_USER:-jj}"
NAS_HOST="${NAS_HOST:-192.168.1.130}"
NAS_SHARE="${NAS_SHARE:-USB_TOSHIBA_EXTERNAL_USB_a_2}"
NAS_PASS="${NAS_PASS:?NAS_PASS not set — create youtube/config/nas.env from nas.env.example}"

MOUNT_POINT="/Volumes/${NAS_SHARE}"
SMB_URL="smb://${NAS_USER}:${NAS_PASS}@${NAS_HOST}/${NAS_SHARE}"
LOG_FILE="/Users/jlgarcia/youtube-complex/youtube/logs/nas-mount.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Mounted at the EXACT canonical mountpoint? Nothing to do.
if mount | awk '{print $3}' | grep -qx "$MOUNT_POINT"; then
    exit 0
fi

# Mounted at a variant (e.g. ...-1) because the canonical name was busy at mount time.
# The share IS reachable (scripts resolve MEDIA_DIR dynamically), so do NOT remount —
# that would stack a -2, -3, ... Leave it; it will land on the canonical name on the
# next natural reconnect (when this branch is no longer hit).
variant="$(mount | sed -nE 's|.* on (/Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2-[0-9]+) .*|\1|p' | head -1)"
if [[ -n "$variant" ]]; then
    log "NAS mounted at variant $variant (not canonical) — leaving active mount in place"
    exit 0
fi

# Not mounted at all. Remove any stale leftover dir squatting the canonical name,
# otherwise macOS would mount at a -1 variant again.
if [[ -d "$MOUNT_POINT" ]]; then
    rmdir "$MOUNT_POINT" 2>/dev/null && log "Removed stale leftover dir $MOUNT_POINT"
fi

log "NAS not mounted — attempting remount via Finder/AppleScript"

osascript -e "tell application \"Finder\" to mount volume \"$SMB_URL\"" >> "$LOG_FILE" 2>&1
sleep 3

if mount | awk '{print $3}' | grep -qx "$MOUNT_POINT"; then
    log "NAS mounted successfully at $MOUNT_POINT"
    exit 0
else
    log "ERROR: failed to mount NAS at canonical path"
    exit 1
fi
