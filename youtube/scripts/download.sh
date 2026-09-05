#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"

# All tunables come from the environment (set via .env / docker-compose).
MEDIA_DIR="${MEDIA_DIR:-/media/youtube}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
PLEX_URL="${PLEX_URL:-}"
PLEX_SECTION="${PLEX_SECTION:-9}"
PLEX_MEDIA_PREFIX="${PLEX_MEDIA_PREFIX:-Z:\\youtube}"

CHANNELS_FILE="${CONFIG_DIR}/channels.txt"
ARCHIVE_FILE="${STATE_DIR}/archive.txt"
LOG_DIR="${STATE_DIR}/logs"
CONFIG_FILE="${CONFIG_DIR}/yt-dlp.conf"
SLEEP_SECONDS=3600
MAX_DISK_USAGE_PCT=90

COOKIE_OPTION=()
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
  COOKIE_OPTION=(--cookies "${CONFIG_DIR}/cookies.txt")
fi

mkdir -p "${LOG_DIR}"
touch "${ARCHIVE_FILE}"

PROTECTED_FOLDERS_FILE="${STATE_DIR}/playlist-folders.txt"

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

get_disk_usage_pct() {
    df "${MEDIA_DIR}" | awk 'NR==2 {sub(/%/,"",$5); print $5}'
}

# Linux stat format: '%Y %n' (modification time in seconds + filename)
find_oldest_video() {
    local tmpfile
    tmpfile=$(mktemp)
    find "${MEDIA_DIR}" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \) \
        -exec stat -c '%Y %n' {} \; > "$tmpfile" 2>/dev/null
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

delete_video() {
    local video_file="$1"
    local rating_key="${2:-}"
    local base_name="${video_file%.*}"
    local video_dir
    video_dir=$(dirname "$video_file")

    log "Deleting: $(basename "$video_file")"

    rm_err=$(rm -f "$video_file" 2>&1) || log "WARNING: Could not delete $video_file — ${rm_err:-unknown error}"
    rm -f "${base_name}.info.json" 2>/dev/null || true
    rm -f "${base_name}.jpg" "${base_name}.webp" "${base_name}.png" 2>/dev/null || true
    rm -f "${base_name}.description" 2>/dev/null || true

    if [ -n "$rating_key" ]; then
        plex_delete_metadata "$rating_key"
    fi

    if [ -d "$video_dir" ] && [ -z "$(ls -A "$video_dir" 2>/dev/null)" ]; then
        rmdir "$video_dir" 2>/dev/null || true
        log "Removed empty channel directory: $(basename "$video_dir")"
    fi
}

plex_delete_metadata() {
    local rk="$1"
    curl -s -o /dev/null --connect-timeout 5 --max-time 10 -X DELETE \
        "${PLEX_URL}/library/metadata/${rk}?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null || true
}

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

plex_scan() {
    local channel_local="${1:-}"
    local url="${PLEX_URL}/library/sections/${PLEX_SECTION}/refresh?X-Plex-Token=${PLEX_TOKEN}"
    local label="full section"
    if [ -n "$channel_local" ]; then
        local channel_name
        channel_name=$(basename "$channel_local")
        local plex_path="${PLEX_MEDIA_PREFIX}/${channel_name}"
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

plex_empty_trash() {
    curl -s -o /dev/null --connect-timeout 5 --max-time 15 -X PUT \
        "${PLEX_URL}/library/sections/${PLEX_SECTION}/emptyTrash?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null || true
}

get_touched_channels() {
    local ytdlp_output="$1"
    [ ! -f "$ytdlp_output" ] && return 0
    grep -oE "${MEDIA_DIR}/[^/]+" "$ytdlp_output" 2>/dev/null | sort -u
}

enforce_storage_limit() {
    local usage_pct
    usage_pct=$(get_disk_usage_pct)
    local deleted=0

    local watched_deleted=0
    while IFS=$'\t' read -r rk plex_path; do
        [ -z "$plex_path" ] && continue
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
    if [ "$unwatched_deleted" -gt 0 ]; then
        plex_scan
        plex_empty_trash
    fi
}

log "Starting YouTube download service (cycle every $((SLEEP_SECONDS/60)) minutes, max disk usage: ${MAX_DISK_USAGE_PCT}%)"

while true; do
    log "Beginning download cycle"

    enforce_storage_limit

    if [ ! -s "${CHANNELS_FILE}" ]; then
        log "WARNING: ${CHANNELS_FILE} is missing or empty. Skipping download cycle."
        sleep "$SLEEP_SECONDS"
        continue
    fi

    ok_count=0 err_count=0 total_count=0
    SHUFFLED_CHANNELS=$(grep -vE '^\s*#|^\s*$' "${CHANNELS_FILE}" | sort -R)

    touched_tmp=$(mktemp)

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "${line// }" ]] && continue

        total_count=$((total_count + 1))
        log "Downloading: $line"

        ytdlp_tmp=$(mktemp)
        set +e
        yt-dlp --config-location "${CONFIG_FILE}" \
            --download-archive "${ARCHIVE_FILE}" \
            --output "${MEDIA_DIR}/%(uploader)s/Season %(upload_date>%Y)s/%(uploader)s - S%(upload_date>%Y)sE%(upload_date>%m%d)s01 - %(title)s [%(id)s].%(ext)s" \
            "${COOKIE_OPTION[@]}" "$line" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log" > "$ytdlp_tmp"
        rc="${PIPESTATUS[0]}"
        set -e
        # Benign ERROR: lines that don't indicate a real failure
        _has_real_error=false
        if grep -q "^ERROR:" "$ytdlp_tmp"; then
            if grep "^ERROR:" "$ytdlp_tmp" | grep -qv "unavailable\|Private video\|members.only\|age.restricted\|This live event\|Premieres in"; then
                _has_real_error=true
            fi
        fi

        if [[ "$rc" -eq 0 || "$rc" -eq 101 ]]; then
            log "OK: $line"
            ok_count=$((ok_count + 1))
        elif [[ "$rc" -eq 1 && "$_has_real_error" == false ]]; then
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

    touched_count=$(sort -u "$touched_tmp" | grep -c . || true)
    if [ "$touched_count" -gt 0 ]; then
        log "Triggering scan for $touched_count touched channel(s)."
        while IFS= read -r ch; do
            [ -n "$ch" ] && plex_scan "$ch"
        done < <(sort -u "$touched_tmp")
    fi
    rm -f "$touched_tmp"

    "${BASE_DIR}/scripts/fix-titles.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"
    "${BASE_DIR}/scripts/fix-posters.sh" 2>&1 | tee -a "${LOG_DIR}/download.log"

    log "Download cycle complete. Sleeping for $SLEEP_SECONDS seconds..."
    sleep "$SLEEP_SECONDS"
done
