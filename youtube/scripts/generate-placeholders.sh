#!/bin/bash
# Generates .strm placeholder files for the last N videos of a YouTube channel.
# Each .strm points to the streaming proxy so Plex streams directly from YouTube.
# A .placeholder sidecar file maps back to the YouTube video ID.
# The proxy also downloads the video in the background for future offline plays.
#
# Usage: generate-placeholders.sh <channel_url> [count]
# Example: generate-placeholders.sh "https://www.youtube.com/@Platzi" 10
#
# Does NOT affect download.sh or the regular hourly cycle.

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
MEDIA_DIR="/Users/jlgarcia/Movies/youtube"
ARCHIVE_FILE="${BASE_DIR}/state/archive.txt"
COUNT="${2:-10}"
CHANNEL_URL="${1:?Usage: generate-placeholders.sh <channel_url> [count]}"
STREAM_BASE_URL="http://host.docker.internal:9090"

COOKIE_OPTION=""
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
    COOKIE_OPTION="--cookies ${CONFIG_DIR}/cookies.txt"
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Fetching last ${COUNT} videos from: ${CHANNEL_URL}"

# Get video IDs and titles via flat-playlist (fast)
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

    # Skip if already in archive (means download.sh already got it)
    if grep -qF -- "$video_id" "$ARCHIVE_FILE" 2>/dev/null; then
        skipped=$((skipped + 1))
        continue
    fi

    # Skip if a real mp4 already exists (check info.json for video ID)
    already_exists=false
    for info_file in "${channel_dir}"/*.info.json; do
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

    # Skip if placeholder already exists for this video ID
    placeholder_exists=false
    while IFS= read -r pf; do
        [ -z "$pf" ] && continue
        if grep -q "$video_id" "$pf" 2>/dev/null; then
            placeholder_exists=true
            break
        fi
    done < <(find "${channel_dir}" -name "*.placeholder" 2>/dev/null)
    if $placeholder_exists; then
        skipped=$((skipped + 1))
        continue
    fi

    # Sanitize filename
    safe_title=$(echo "$title" | sed 's/[\/\\:*?"<>|]//g' | head -c 180)

    # Get upload date for proper naming
    upload_date=$(yt-dlp --print "%(upload_date>%Y-%m-%d)s" --skip-download ${COOKIE_OPTION} \
        "https://www.youtube.com/watch?v=${video_id}" 2>/dev/null || echo "unknown")

    # SxxEyy format: Season=year, Episode=MMDD+index for unique episodes per day
    year=$(echo "$upload_date" | cut -d'-' -f1)
    mmdd=$(echo "$upload_date" | cut -d'-' -f2,3 | tr -d '-')
    existing_count=$(find "${channel_dir}" -maxdepth 1 -name "${channel_name} - S${year}E${mmdd}*" \( -name "*.mp4" -o -name "*.strm" \) 2>/dev/null | wc -l | tr -d ' ')
    ep_index=$(printf "%02d" $((existing_count + 1)))

    base_name="${channel_name} - S${year}E${mmdd}${ep_index} - ${safe_title} [${video_id}]"
    strm_file="${channel_dir}/${base_name}.strm"
    placeholder_file="${channel_dir}/${base_name}.placeholder"
    thumb_file="${channel_dir}/${base_name}.jpg"

    # Create .strm file pointing to streaming proxy
    log "Creating placeholder: ${safe_title}"
    echo "${STREAM_BASE_URL}/stream/${video_id}" > "$strm_file"

    # Write sidecar with video ID
    echo "$video_id" > "$placeholder_file"

    # Download thumbnail
    yt-dlp --skip-download --write-thumbnail --convert-thumbnails jpg \
        -o "${channel_dir}/${base_name}" \
        ${COOKIE_OPTION} \
        "https://www.youtube.com/watch?v=${video_id}" 2>/dev/null || true

    # Rename thumbnail if yt-dlp used a different name
    for f in "${channel_dir}/${base_name}".webp "${channel_dir}/${base_name}".png; do
        [ -f "$f" ] && mv "$f" "$thumb_file" 2>/dev/null
    done

    created=$((created + 1))

done <<< "$videos_json"

log "Done: ${created} placeholders created, ${skipped} skipped (already exist or downloaded)"
