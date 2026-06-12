#!/bin/bash
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"
export MEDIA_DIR=""  # resolved dynamically in ensure_nas_mount; exported for subprocesses
# NAS credentials from gitignored env file (see config/nas.env.example)
# shellcheck source=/dev/null
[[ -f "${CONFIG_DIR}/nas.env" ]] && source "${CONFIG_DIR}/nas.env"
NAS_USER="${NAS_USER:-jj}"
NAS_HOST="${NAS_HOST:-192.168.1.130}"
NAS_SHARE="${NAS_SHARE:-USB_TOSHIBA_EXTERNAL_USB_a_2}"
CHANNELS_FILE="${CONFIG_DIR}/channels.txt"
ARCHIVE_FILE="${STATE_DIR}/archive.txt"
LOG_DIR="${STATE_DIR}/logs"
CONFIG_FILE="${CONFIG_DIR}/yt-dlp.conf"
SLEEP_SECONDS=3600       # 1 hour
MAX_DISK_USAGE_PCT=90    # Start cleanup when disk usage reaches this %
PLEX_TOKEN="PY1xBcA7QT9r6swusu1x"
PLEX_URL="http://192.168.1.78:32400"
PLEX_SECTION=9
PLEX_MEDIA_PREFIX="Z:\\youtube"  # Path as seen by remote Plex (Windows)

# Detect valid cookies
COOKIE_OPTION=""
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
  COOKIE_OPTION=(--cookies "${CONFIG_DIR}/cookies.txt")
fi

# Ensure NAS is mounted (SMB share must be available for MEDIA_DIR)
# Sets MEDIA_DIR to the actual mount point (handles macOS -1/-2 suffix drift)
ensure_nas_mount() {
    local actual_mount
    actual_mount=$(mount | grep "${NAS_SHARE}" | sed -E 's|.* on (/Volumes/[^ ]+) .*|\1|' | head -1)
    if [[ -n "$actual_mount" ]]; then
        MEDIA_DIR="${actual_mount}/youtube"
        return 0
    fi
    log "NAS not mounted — attempting mount..."
    open "smb://${NAS_USER}:${NAS_PASS:-}@${NAS_HOST}/${NAS_SHARE}" 2>/dev/null
    sleep 3
    actual_mount=$(mount | grep "${NAS_SHARE}" | sed -E 's|.* on (/Volumes/[^ ]+) .*|\1|' | head -1)
    if [[ -n "$actual_mount" ]]; then
        MEDIA_DIR="${actual_mount}/youtube"
        log "NAS mounted successfully at ${actual_mount}."
        return 0
    else
        log "ERROR: Failed to mount NAS. Skipping cycle."
        return 1
    fi
}

mkdir -p "${LOG_DIR}"

touch "${ARCHIVE_FILE}"

PROTECTED_FOLDERS_FILE="${STATE_DIR}/playlist-folders.txt"

# Check if a video file belongs to a protected playlist folder
is_protected() {
    local video_file="$1"
    [[ -s "${PROTECTED_FOLDERS_FILE}" ]] || return 1
    local folder_name
    folder_name=$(basename "$(dirname "$video_file")")
    grep -qxF -- "$folder_name" "${PROTECTED_FOLDERS_FILE}" 2>/dev/null
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_DIR}/download.log"
}

# Returns current disk usage percentage (integer) for the volume where MEDIA_DIR lives
get_disk_usage_pct() {
    df "${MEDIA_DIR}" | awk 'NR==2 {sub(/%/,"",$5); print $5}'
}

# Find the oldest video file (pipefail-safe), excluding protected playlist folders
find_oldest_video() {
    local tmpfile
    tmpfile=$(mktemp)
    find "${MEDIA_DIR}" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \) -exec stat -f '%m %N' {} \; > "$tmpfile" 2>/dev/null
    if [ -s "$tmpfile" ]; then
        while IFS= read -r line; do
            local file
            file=$(echo "$line" | cut -d' ' -f2-)
            if ! is_protected "$file"; then
                echo "$file"
                rm -f "$tmpfile"
                return
            fi
        done < <(sort -n "$tmpfile")
    fi
    rm -f "$tmpfile"
}

# Deletes a video and its associated files (.info.json, thumbnails).
# If a Plex ratingKey is passed as $2, also DELETEs the catalog entry to keep
# the catalog consistent without waiting for a scan.
delete_video() {
    local video_file="$1"
    local rating_key="${2:-}"
    local base_name="${video_file%.*}"
    local video_dir
    video_dir=$(dirname "$video_file")

    log "Deleting: $(basename "$video_file")"

    # rm can fail on NAS/SMB mounts — capture real error for diagnosis
    rm_err=$(rm -f "$video_file" 2>&1) || log "WARNING: Could not delete $video_file — ${rm_err:-unknown error}"
    rm -f "${base_name}.info.json" 2>/dev/null || true
    rm -f "${base_name}.jpg" "${base_name}.webp" "${base_name}.png" 2>/dev/null || true
    rm -f "${base_name}.description" 2>/dev/null || true

    if [ -n "$rating_key" ]; then
        plex_delete_metadata "$rating_key"
    fi

    # Remove channel directory if empty
    if [ -d "$video_dir" ] && [ -z "$(ls -A "$video_dir" 2>/dev/null)" ]; then
        rmdir "$video_dir" 2>/dev/null || true
        log "Removed empty channel directory: $(basename "$video_dir")"
    fi
}

# DELETE a Plex catalog entry by ratingKey (removes the item immediately,
# no scan required). Fails silently — the next scan would clean up anyway.
# --max-time bounds the whole request: if Plex is overloaded it would otherwise
# hang for minutes and block the entire cycle.
plex_delete_metadata() {
    local rk="$1"
    curl -s -o /dev/null --connect-timeout 5 --max-time 10 -X DELETE \
        "${PLEX_URL}/library/metadata/${rk}?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null || true
}

# Gets list of watched videos from Plex. Outputs "ratingKey<TAB>file_path"
# per line (the file path is the Plex container path; caller maps to local).
get_watched_videos() {
    curl -s --connect-timeout 5 --max-time 20 -H "Accept: application/json" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_URL}/library/sections/${PLEX_SECTION}/all?type=4&viewCount%3E=1&X-Plex-Container-Size=500" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for item in data.get('MediaContainer', {}).get('Metadata', []):
        rk = item.get('ratingKey', '')
        for media in item.get('Media', []):
            for part in media.get('Part', []):
                f = part.get('file', '')
                if f and rk:
                    print(f'{rk}\t{f}')
except:
    pass
" 2>/dev/null || true
}

# Trigger a Plex scan limited to a single channel folder (or full section if
# called with no arg). Targeted scans avoid re-walking 600+ channel folders
# every cycle.
plex_scan() {
    local channel_local="${1:-}"
    local url="${PLEX_URL}/library/sections/${PLEX_SECTION}/refresh?X-Plex-Token=${PLEX_TOKEN}"
    local label="full section"
    if [ -n "$channel_local" ]; then
        # Translate local channel folder to Plex's Windows path and URL-encode
        local channel_name
        channel_name=$(basename "$channel_local")
        local plex_path="${PLEX_MEDIA_PREFIX}\\${channel_name}"
        local encoded
        encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$plex_path")
        url="${PLEX_URL}/library/sections/${PLEX_SECTION}/refresh?path=${encoded}&X-Plex-Token=${PLEX_TOKEN}"
        label="$channel_name"
    fi
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
        -X POST "$url" 2>/dev/null) || true
    if [[ "$http_code" == "200" ]]; then
        log "Plex scan triggered ($label)."
    else
        log "WARNING: Plex scan failed for $label (HTTP $http_code)."
    fi
}

# Tell Plex to remove orphan catalog entries (items whose files no longer exist
# AND that Plex has already marked as missing during a scan). Safety net for
# Phase 2 deletions where we don't pre-fetch ratingKeys.
plex_empty_trash() {
    curl -s -o /dev/null --connect-timeout 5 --max-time 15 -X PUT \
        "${PLEX_URL}/library/sections/${PLEX_SECTION}/emptyTrash?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null || true
}

# Parse a yt-dlp output file and print one channel-folder path per touched
# video (deduplicated by the caller). yt-dlp logs absolute paths in
# `Destination:`, `Merging formats into`, and `[Final filepath]` lines.
get_touched_channels() {
    local ytdlp_output="$1"
    [ ! -f "$ytdlp_output" ] && return 0
    # Match any absolute path beginning with MEDIA_DIR and emit its first
    # subdirectory (the channel folder). Handles paths with spaces.
    grep -oE "${MEDIA_DIR}/[^/]+" "$ytdlp_output" 2>/dev/null | sort -u
}

# Three-phase cleanup:
#   Phase 1: Always delete ALL watched videos (already seen, no reason to keep)
#   Phase 2: Delete oldest unwatched videos if still over disk limit
#   Phase 3: Plex scan to remove deleted entries from the UI
enforce_storage_limit() {
    local usage_pct
    usage_pct=$(get_disk_usage_pct)
    local deleted=0

    # Phase 1: Always delete all watched, non-protected videos
    local watched_deleted=0
    while IFS=$'\t' read -r rk plex_path; do
        [ -z "$plex_path" ] && continue
        # Remote Plex (Windows) returns backslash paths — normalize to forward slashes
        local normalized="${plex_path//\\//}"
        local prefix_normalized="${PLEX_MEDIA_PREFIX//\\//}"
        local watched_local="${normalized/#${prefix_normalized}/${MEDIA_DIR}}"
        if [ -f "$watched_local" ] && ! is_protected "$watched_local"; then
            delete_video "$watched_local" "$rk"
            deleted=$(( deleted + 1 ))
            watched_deleted=$(( watched_deleted + 1 ))
        fi
    done < <(get_watched_videos)

    if [ "$watched_deleted" -gt 0 ]; then
        usage_pct=$(get_disk_usage_pct)
        log "Phase 1: removed $watched_deleted watched video(s). Disk at ${usage_pct}%."
    fi

    # Phase 2: Delete oldest unwatched videos if over disk limit.
    # We don't have ratingKeys here, so a section scan + emptyTrash is needed
    # afterwards to clean up orphan catalog entries.
    local unwatched_deleted=0
    if [ "$usage_pct" -ge "$MAX_DISK_USAGE_PCT" ]; then
        log "Disk usage at ${usage_pct}% (limit: ${MAX_DISK_USAGE_PCT}%). Removing oldest unwatched videos..."
        while [ "$usage_pct" -ge "$MAX_DISK_USAGE_PCT" ]; do
            oldest_video=$(find_oldest_video)

            if [ -z "$oldest_video" ]; then
                log "WARNING: No more video files to delete but disk still at ${usage_pct}%."
                break
            fi

            delete_video "$oldest_video"
            deleted=$(( deleted + 1 ))
            unwatched_deleted=$(( unwatched_deleted + 1 ))
            usage_pct=$(get_disk_usage_pct)
        done
    fi

    if [ "$deleted" -gt 0 ]; then
        log "Cleanup complete: removed $deleted video(s) ($watched_deleted watched). Disk at ${usage_pct}%."
    fi
    # Phase 1 deletes update the catalog inline via metadata DELETE — no scan
    # needed. Phase 2 deletes leave orphans, so trigger a full scan + trash.
    if [ "$unwatched_deleted" -gt 0 ]; then
        plex_scan
        plex_empty_trash
    fi
}

log "Starting YouTube download service (cycle every $((SLEEP_SECONDS/60)) minutes, max disk usage: ${MAX_DISK_USAGE_PCT}%)"

while true; do
    log "Beginning download cycle"

    # Ensure NAS is available before doing anything
    if ! ensure_nas_mount; then
        sleep 300  # retry in 5 min instead of waiting a full cycle
        continue
    fi

    # Enforce storage limit before downloading new videos
    enforce_storage_limit

    if [ ! -s "${CHANNELS_FILE}" ]; then
        log "WARNING: ${CHANNELS_FILE} is missing or empty. Skipping download cycle."
        sleep "$SLEEP_SECONDS"
        continue
    fi

    # Download latest video from each channel (randomized order each cycle)
    ok_count=0 err_count=0 total_count=0
    SHUFFLED_CHANNELS=$(grep -vE '^\s*#|^\s*$' "${CHANNELS_FILE}" | sort -R)

    # Accumulate touched channel folders for surgical post-cycle scans
    touched_tmp=$(mktemp)

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "${line// }" ]] && continue

        total_count=$((total_count + 1))
        log "Downloading: $line"

        ytdlp_tmp=$(mktemp)
        set +e
        yt-dlp --config-location "${CONFIG_FILE}" \
            --output "${MEDIA_DIR}/%(uploader)s/Season %(upload_date>%Y)s/%(uploader)s - S%(upload_date>%Y)sE%(upload_date>%m%d)s01 - %(title)s [%(id)s].%(ext)s" \
            "${COOKIE_OPTION[@]}" "$line" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log" > "$ytdlp_tmp"
        rc="${PIPESTATUS[0]}"
        set -e
        if [[ "$rc" -eq 0 || "$rc" -eq 101 ]]; then
            log "OK: $line"
            ok_count=$((ok_count + 1))
        elif [[ "$rc" -eq 1 ]] && ! grep -q "^ERROR:" "$ytdlp_tmp"; then
            log "OK (no new): $line"
            ok_count=$((ok_count + 1))
        else
            log "ERROR (exit $rc): $line"
            err_count=$((err_count + 1))
        fi
        get_touched_channels "$ytdlp_tmp" >> "$touched_tmp" || true
        rm -f "$ytdlp_tmp"

        enforce_storage_limit

    done <<< "$SHUFFLED_CHANNELS"

    log "Download done: ${total_count} channels, ${ok_count} OK, ${err_count} errors."

    # Process playlists (series, courses — stored in same library, protected from cleanup).
    # We pipe playlist script output through tee so we can also harvest touched folders.
    log "Processing playlists..."
    playlist_log=$(mktemp)
    set +e
    "${BASE_DIR}/scripts/download-playlists.sh" 2>&1 | tee -a "${LOG_DIR}/download.log" > "$playlist_log"
    playlist_rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$playlist_rc" -eq 0 ]]; then
        log "Playlists processed."
    else
        log "WARNING: Playlist processing had errors (exit $playlist_rc)."
    fi
    get_touched_channels "$playlist_log" >> "$touched_tmp" || true
    rm -f "$playlist_log"

    # Surgical Plex scan: only channels that actually got new files this cycle.
    touched_count=$(sort -u "$touched_tmp" | grep -c . || true)
    if [ "$touched_count" -gt 0 ]; then
        log "Triggering scan for $touched_count touched channel(s)."
        while IFS= read -r ch; do
            [ -n "$ch" ] && plex_scan "$ch"
        done < <(sort -u "$touched_tmp")
    fi
    rm -f "$touched_tmp"

    # Fix episode titles from filenames
    "${BASE_DIR}/scripts/fix-titles.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"
    # Upload channel avatars as show posters
    "${BASE_DIR}/scripts/fix-posters.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"

    log "Download cycle complete. Sleeping for $SLEEP_SECONDS seconds..."
    sleep "$SLEEP_SECONDS"
done
