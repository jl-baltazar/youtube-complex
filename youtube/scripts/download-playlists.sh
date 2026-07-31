#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"
PLAYLISTS_FILE="${CONFIG_DIR}/playlists.txt"
PLAYLIST_CONFIG="${CONFIG_DIR}/yt-dlp-playlist.conf"
ARCHIVE_FILE="${STATE_DIR}/archive.txt"
MEDIA_DIR="${MEDIA_DIR:-/media/youtube}"
PROTECTED_FILE="${STATE_DIR}/playlist-folders.txt"
LOG_DIR="${STATE_DIR}/logs"

COOKIE_OPTION=()
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
    COOKIE_OPTION=(--cookies "${CONFIG_DIR}/cookies.txt")
fi

mkdir -p "${LOG_DIR}" "${MEDIA_DIR}"
touch "${PROTECTED_FILE}"

register_protected_folder() {
    local name="$1"
    if ! grep -qxF -- "$name" "${PROTECTED_FILE}" 2>/dev/null; then
        echo "$name" >> "${PROTECTED_FILE}"
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [playlists] $*" | tee -a "${LOG_DIR}/download.log"
}

download_playlist() {
    local url="$1"
    local custom_name="${2:-}"

    local label rc
    local tmp_log
    tmp_log=$(mktemp)

    if [[ -n "$custom_name" ]]; then
        label="$custom_name"
        local output_template="${MEDIA_DIR}/${custom_name}/${custom_name} - S01E%(playlist_index&{:03d})s - %(title)s [%(id)s].%(ext)s"
        log "Downloading playlist: ${label} (${url})"
        set +e
        yt-dlp --config-location "${PLAYLIST_CONFIG}" \
            --download-archive "${ARCHIVE_FILE}" \
            -o "$output_template" \
            "${COOKIE_OPTION[@]}" \
            "$url" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log" "$tmp_log"
        rc="${PIPESTATUS[0]}"
        set -e
        register_protected_folder "$custom_name"
    else
        local playlist_title
        playlist_title=$(yt-dlp --flat-playlist --print "%(playlist_title)s" --playlist-items 1 "${COOKIE_OPTION[@]}" "$url" 2>/dev/null | head -1)
        label="${playlist_title:-$url}"
        log "Downloading playlist: ${label}"
        set +e
        yt-dlp --config-location "${PLAYLIST_CONFIG}" \
            --download-archive "${ARCHIVE_FILE}" \
            "${COOKIE_OPTION[@]}" \
            "$url" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log" "$tmp_log"
        rc="${PIPESTATUS[0]}"
        set -e
        [[ -n "$playlist_title" ]] && register_protected_folder "$playlist_title"
    fi

    if [[ "$rc" -eq 0 ]]; then
        log "OK: ${label}"
    elif grep -qiE 'has already been recorded in the archive' "$tmp_log"; then
        log "OK (already archived): ${label}"
    else
        log "ERROR (exit $rc): ${label}"
    fi
    rm -f "$tmp_log"
}

download_all_playlists() {
    if [[ ! -s "${PLAYLISTS_FILE}" ]]; then
        log "No playlists configured (${PLAYLISTS_FILE} is empty or missing). Skipping."
        return 0
    fi

    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        local url custom_name
        if [[ "$line" == *"|"* ]]; then
            url=$(echo "$line" | cut -d'|' -f1 | xargs)
            custom_name=$(echo "$line" | cut -d'|' -f2- | xargs)
        else
            url=$(echo "$line" | xargs)
            custom_name=""
        fi

        download_playlist "$url" "$custom_name"
        count=$((count + 1))
    done < "${PLAYLISTS_FILE}"

    log "Processed ${count} playlist(s)."
}

if [[ $# -ge 1 ]]; then
    download_playlist "$1" "${2:-}"
else
    download_all_playlists
fi
