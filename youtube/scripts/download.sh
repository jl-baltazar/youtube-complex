#!/bin/bash
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"
MEDIA_DIR="/Users/jlgarcia/Movies/youtube"
CHANNELS_FILE="${CONFIG_DIR}/channels.txt"
ARCHIVE_FILE="${STATE_DIR}/archive.txt"
LOG_DIR="${STATE_DIR}/logs"
CONFIG_FILE="${CONFIG_DIR}/yt-dlp.conf"
SLEEP_SECONDS=3600       # 1 hour
MAX_DISK_USAGE_PCT=90    # Start cleanup when disk usage reaches this %
PLEX_TOKEN="GNEaLTTQ1t932g8LUT7G"
PLEX_URL="http://localhost:32400"
PLEX_SECTION=6
PLEX_MEDIA_PREFIX="/media/youtube"  # Path as seen by Plex container

# Detect valid cookies
COOKIE_OPTION=""
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
  COOKIE_OPTION=(--cookies "${CONFIG_DIR}/cookies.txt")
fi

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

# Deletes a video and its associated files (.info.json, thumbnails)
delete_video() {
    local video_file="$1"
    local base_name="${video_file%.*}"
    local video_dir
    video_dir=$(dirname "$video_file")

    log "Deleting: $(basename "$video_file")"

    rm -f "$video_file"
    rm -f "${base_name}.info.json"
    rm -f "${base_name}.jpg" "${base_name}.webp" "${base_name}.png"
    rm -f "${base_name}.description"

    # Remove channel directory if empty
    if [ -d "$video_dir" ] && [ -z "$(ls -A "$video_dir" 2>/dev/null)" ]; then
        rmdir "$video_dir"
        log "Removed empty channel directory: $(basename "$video_dir")"
    fi
}

# Gets list of watched video file paths (Plex container paths mapped to local paths)
get_watched_videos() {
    curl -s -H "Accept: application/json" -H "X-Plex-Token: ${PLEX_TOKEN}" \
        "${PLEX_URL}/library/sections/${PLEX_SECTION}/all?type=4&viewCount%3E=1&X-Plex-Container-Size=500" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for item in data.get('MediaContainer', {}).get('Metadata', []):
        for media in item.get('Media', []):
            for part in media.get('Part', []):
                f = part.get('file', '')
                if f:
                    print(f)
except:
    pass
" 2>/dev/null
}

# Two-phase cleanup:
#   Phase 1: Delete watched videos first (already seen, safe to remove)
#   Phase 2: Delete oldest unwatched videos if still over limit
enforce_storage_limit() {
    local usage_pct
    usage_pct=$(get_disk_usage_pct)

    if [ "$usage_pct" -lt "$MAX_DISK_USAGE_PCT" ]; then
        return
    fi

    log "Disk usage at ${usage_pct}% (limit: ${MAX_DISK_USAGE_PCT}%). Starting cleanup..."

    local deleted=0

    # Phase 1: Delete watched videos (oldest first)
    log "Phase 1: Removing watched videos..."
    local watched_local
    while IFS= read -r plex_path; do
        [ -z "$plex_path" ] && continue
        # Convert Plex container path to local path
        watched_local="${plex_path/#${PLEX_MEDIA_PREFIX}/${MEDIA_DIR}}"
        if [ -f "$watched_local" ] && ! is_protected "$watched_local"; then
            delete_video "$watched_local"
            deleted=$(( deleted + 1 ))
            usage_pct=$(get_disk_usage_pct)
            if [ "$usage_pct" -lt "$MAX_DISK_USAGE_PCT" ]; then
                log "Phase 1 complete: removed $deleted watched video(s). Disk at ${usage_pct}%."
                return
            fi
        fi
    done < <(get_watched_videos)

    # Phase 2: Delete oldest unwatched videos
    if [ "$usage_pct" -ge "$MAX_DISK_USAGE_PCT" ]; then
        log "Phase 2: Removing oldest unwatched videos..."
        while [ "$usage_pct" -ge "$MAX_DISK_USAGE_PCT" ]; do
            oldest_video=$(find_oldest_video)

            if [ -z "$oldest_video" ]; then
                log "WARNING: No more video files to delete but disk still at ${usage_pct}%."
                break
            fi

            delete_video "$oldest_video"
            deleted=$(( deleted + 1 ))
            usage_pct=$(get_disk_usage_pct)
        done
    fi

    log "Cleanup complete: removed $deleted video(s). Disk usage now at ${usage_pct}%."
}

log "Starting YouTube download service (cycle every $((SLEEP_SECONDS/60)) minutes, max disk usage: ${MAX_DISK_USAGE_PCT}%)"

while true; do
    log "Beginning download cycle"

    # Enforce storage limit before downloading new videos
    enforce_storage_limit

    if [ ! -s "${CHANNELS_FILE}" ]; then
        log "WARNING: ${CHANNELS_FILE} is missing or empty. Skipping download cycle."
        sleep "$SLEEP_SECONDS"
        continue
    fi

    ok_count=0 err_count=0

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        log "Processing channel: $line"

        # Run yt-dlp and capture exit code + output for error classification
        # Exit codes: 0=success, 101=max-downloads reached (expected)
        # Exit code 1 without ERROR: lines = no new videos (not a real error)
        ytdlp_tmp=$(mktemp)
        set +e
        yt-dlp --config-location "${CONFIG_FILE}" "${COOKIE_OPTION[@]}" "$line" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log" > "$ytdlp_tmp"
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
        rm -f "$ytdlp_tmp"

        # Check storage after each channel download
        enforce_storage_limit

    done < "${CHANNELS_FILE}"

    log "Channels done: ${ok_count} OK, ${err_count} errors."

    # Process playlists (series, courses — stored in same library, protected from cleanup)
    log "Processing playlists..."
    set +e
    "${BASE_DIR}/scripts/download-playlists.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"
    playlist_rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$playlist_rc" -eq 0 ]]; then
        log "Playlists processed."
    else
        log "WARNING: Playlist processing had errors (exit $playlist_rc)."
    fi

    # Trigger Plex library scan to pick up new videos
    if docker exec -e LD_LIBRARY_PATH=/usr/lib/plexmediaserver plex \
        "/usr/lib/plexmediaserver/Plex Media Scanner" --scan --section 6 2>&1 | tee -a "${LOG_DIR}/download.log"; then
        log "Plex library scan triggered."
        # Fix episode titles from filenames
        "${BASE_DIR}/scripts/fix-titles.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"
        # Upload channel avatars as show posters
        "${BASE_DIR}/scripts/fix-posters.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"
    else
        log "WARNING: Plex scan failed (is the container running?)"
    fi

    log "Download cycle complete. Sleeping for $SLEEP_SECONDS seconds..."
    sleep "$SLEEP_SECONDS"
done
