#!/bin/bash
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"
PLAYLISTS_FILE="${CONFIG_DIR}/playlists.txt"
PLAYLIST_CONFIG="${CONFIG_DIR}/yt-dlp-playlist.conf"
MEDIA_DIR="/Users/jlgarcia/Movies/youtube"
PROTECTED_FILE="${STATE_DIR}/playlist-folders.txt"
LOG_DIR="${STATE_DIR}/logs"

# Detect valid cookies
COOKIE_OPTION=()
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
    COOKIE_OPTION=(--cookies "${CONFIG_DIR}/cookies.txt")
fi

mkdir -p "${LOG_DIR}" "${MEDIA_DIR}"
touch "${PROTECTED_FILE}"

# Register a folder name as protected from cleanup
register_protected_folder() {
    local name="$1"
    if ! grep -qxF -- "$name" "${PROTECTED_FILE}" 2>/dev/null; then
        echo "$name" >> "${PROTECTED_FILE}"
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [playlists] $*" | tee -a "${LOG_DIR}/download.log"
}

# Download a single playlist
# Args: $1 = URL, $2 = custom name (optional)
download_playlist() {
    local url="$1"
    local custom_name="${2:-}"

    if [[ -n "$custom_name" ]]; then
        # Override output template with custom name
        local output_template="${MEDIA_DIR}/${custom_name}/${custom_name} - S01E%(playlist_index&{:03d})s - %(title)s [%(id)s].%(ext)s"
        log "Downloading playlist: ${custom_name} (${url})"
        if yt-dlp --config-location "${PLAYLIST_CONFIG}" \
            -o "$output_template" \
            "${COOKIE_OPTION[@]}" \
            "$url" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log"; then
            log "Successfully processed playlist: ${custom_name}"
        else
            log "ERROR: Failed to process playlist: ${custom_name} (${url})"
        fi
        register_protected_folder "$custom_name"
    else
        # Get playlist title first to register the folder name
        local playlist_title
        playlist_title=$(yt-dlp --flat-playlist --print "%(playlist_title)s" --playlist-items 1 "${COOKIE_OPTION[@]}" "$url" 2>/dev/null | head -1)
        log "Downloading playlist: ${playlist_title:-$url}"
        if yt-dlp --config-location "${PLAYLIST_CONFIG}" \
            "${COOKIE_OPTION[@]}" \
            "$url" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log"; then
            log "Successfully processed playlist: ${playlist_title:-$url}"
        else
            log "ERROR: Failed to process playlist: ${playlist_title:-$url}"
        fi
        [[ -n "$playlist_title" ]] && register_protected_folder "$playlist_title"
    fi
}

# Process all playlists from config file
download_all_playlists() {
    if [[ ! -s "${PLAYLISTS_FILE}" ]]; then
        log "No playlists configured (${PLAYLISTS_FILE} is empty or missing). Skipping."
        return 0
    fi

    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Parse: URL | Custom Name
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

# Allow direct invocation: download-playlists.sh [URL] [custom_name]
if [[ $# -ge 1 ]]; then
    download_playlist "$1" "${2:-}"
else
    download_all_playlists
fi
