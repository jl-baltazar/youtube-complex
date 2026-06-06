#!/bin/bash
# Transfer ~/Movies/youtube/ to NAS channel-by-channel via rsync daemon protocol.
# Avoids macOS rsync's slow full-list scan on large directories.
# Requires GNU rsync (brew install rsync) for UTF-8 handling. Filenames with
# emoji must be pre-stripped — the Samba daemon on the NAS rejects them.
# Usage: bash rsync-to-nas.sh

set -uo pipefail

# NAS credentials from gitignored env file (see config/nas.env.example)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${_SCRIPT_DIR}/../config/nas.env" ]] && source "${_SCRIPT_DIR}/../config/nas.env"
export RSYNC_PASSWORD="${NAS_PASS:?NAS_PASS not set — create youtube/config/nas.env from nas.env.example}"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

RSYNC_BIN="/usr/local/bin/rsync"  # GNU rsync; macOS /usr/bin/rsync is openrsync
SRC="/Users/jlgarcia/Movies/youtube"
DEST="rsync://jj@192.168.1.130/USB_TOSHIBA_EXTERNAL_USB_a_2/youtube"
LOG="/Users/jlgarcia/youtube-complex/youtube/state/logs/rsync-migration.log"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

: > "$LOG"
log "=== Starting channel-by-channel rsync ==="

total=0
ok=0
fail=0

for dir in "$SRC"/*/; do
    [ -d "$dir" ] || continue
    channel=$(basename "$dir")
    total=$((total + 1))

    log "[$total] Syncing: $channel"
    "$RSYNC_BIN" -av --partial --partial-dir=.rsync-partial --remove-source-files \
        "$dir" "$DEST/$channel/" >> "$LOG" 2>&1

    rc=$?
    if [ $rc -eq 0 ]; then
        ok=$((ok + 1))
        log "[$total] OK: $channel"
    else
        fail=$((fail + 1))
        log "[$total] FAILED (rc=$rc): $channel"
    fi
done

log "=== Done: $ok/$total OK, $fail failed ==="
