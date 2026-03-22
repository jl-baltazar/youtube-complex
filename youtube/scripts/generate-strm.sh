#!/bin/bash
# Generates .strm files for the last N videos of a YouTube channel
# These appear in Plex as playable items that trigger the stream proxy
#
# Usage: generate-strm.sh <channel_url> [count]
# Example: generate-strm.sh "https://www.youtube.com/@Platzi" 10

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
MEDIA_DIR="/Users/jlgarcia/Movies/youtube"
PROXY_PORT=9090
PROXY_HOST="192.168.1.163"  # Plex runs in Docker, needs host reference
COUNT="${2:-10}"
CHANNEL_URL="${1:?Usage: generate-strm.sh <channel_url> [count]}"

COOKIE_OPTION=""
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
    COOKIE_OPTION="--cookies ${CONFIG_DIR}/cookies.txt"
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Fetching last ${COUNT} videos from: ${CHANNEL_URL}"

# Get video IDs and titles via flat-playlist (fast, no full metadata)
videos_json=$(yt-dlp \
    --flat-playlist \
    --playlist-end "${COUNT}" \
    --print '{"id":"%(id)s","title":"%(title)s"}' \
    ${COOKIE_OPTION} \
    --no-warnings \
    "${CHANNEL_URL}/videos" 2>/dev/null) || true

if [ -z "$videos_json" ]; then
    log "ERROR: No videos found for ${CHANNEL_URL}"
    exit 1
fi

# Resolve channel name from the first video
first_id=$(echo "$videos_json" | head -1 | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
channel_name=$(yt-dlp --print "%(uploader)s" --skip-download ${COOKIE_OPTION} "https://www.youtube.com/watch?v=${first_id}" 2>/dev/null)

if [ -z "$channel_name" ] || [ "$channel_name" = "NA" ]; then
    # Fallback: extract from URL
    channel_name=$(echo "$CHANNEL_URL" | sed 's|.*/@@\?||; s|/.*||')
fi

log "Channel: ${channel_name}"

channel_dir="${MEDIA_DIR}/${channel_name}"
mkdir -p "${channel_dir}"

created=0
skipped=0

while IFS= read -r line; do
    [ -z "$line" ] && continue

    video_id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
    title=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null)

    [ -z "$video_id" ] && continue

    # Check if video already exists as mp4 (search by video ID in info.json)
    already_exists=false
    for info_file in "${MEDIA_DIR}"/*/*.info.json; do
        [ -f "$info_file" ] || continue
        if grep -q "\"id\": \"${video_id}\"" "$info_file" 2>/dev/null; then
            already_exists=true
            break
        fi
    done

    if $already_exists; then
        skipped=$((skipped + 1))
        continue
    fi

    # Also check if .strm already exists for this video ID
    if grep -rl "${video_id}" "${channel_dir}"/*.strm 2>/dev/null | grep -q .; then
        skipped=$((skipped + 1))
        continue
    fi

    # Sanitize filename
    safe_title=$(echo "$title" | sed 's/[\/\\:*?"<>|]//g' | head -c 200)

    strm_file="${channel_dir}/${channel_name} - ${safe_title}.strm"

    echo "http://${PROXY_HOST}:${PROXY_PORT}/play/${video_id}" > "$strm_file"
    log "Created: $(basename "$strm_file")"
    created=$((created + 1))

done <<< "$videos_json"

log "Done: ${created} .strm files created, ${skipped} skipped (already exist)"
