#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
MEDIA_DIR="${MEDIA_DIR:-/media/youtube}"
ARCHIVE_FILE="${BASE_DIR}/state/archive.txt"
COUNT="${2:-10}"
CHANNEL_URL="${1:?Usage: generate-placeholders.sh <channel_url> [count]}"

COOKIE_OPTION=""
if [[ -s "${CONFIG_DIR}/cookies.txt" ]] && grep -qE '^\.' "${CONFIG_DIR}/cookies.txt"; then
    COOKIE_OPTION="--cookies ${CONFIG_DIR}/cookies.txt"
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

generate_placeholder_mp4() {
    local output_file="$1"
    local channel="$2"
    local title="$3"

    local safe_channel safe_title_line
    safe_channel=$(echo "$channel" | sed "s/[':]/\\\\&/g")
    safe_title_line=$(echo "$title" | sed "s/[':]/\\\\&/g" | cut -c1-60)

    ffmpeg -y -loglevel error \
        -f lavfi -i "color=c=black:s=1280x720:d=10:r=24" \
        -f lavfi -i "anullsrc=r=44100:cl=stereo" \
        -vf "drawtext=text='Descargando...':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2-80, \
             drawtext=text='${safe_channel}':fontsize=32:fontcolor=#AAAAAA:x=(w-text_w)/2:y=(h-text_h)/2, \
             drawtext=text='${safe_title_line}':fontsize=24:fontcolor=#888888:x=(w-text_w)/2:y=(h-text_h)/2+50, \
             drawtext=text='Vuelve a reproducir en unos segundos':fontsize=20:fontcolor=#666666:x=(w-text_w)/2:y=(h-text_h)/2+120" \
        -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
        -c:a aac -shortest -t 10 \
        "$output_file"
}

log "Fetching last ${COUNT} videos from: ${CHANNEL_URL}"

flat_output=$(yt-dlp \
    --flat-playlist \
    --playlist-end "${COUNT}" \
    --print '{"id":"%(id)s","title":"%(title)s","upload_date":"%(upload_date)s","playlist_title":"%(playlist_title)s"}' \
    ${COOKIE_OPTION} \
    --no-warnings \
    "${CHANNEL_URL}/videos" 2>/dev/null) || true

if [ -z "$flat_output" ]; then
    log "ERROR: No videos found for ${CHANNEL_URL}"
    exit 1
fi

videos_json=$(echo "$flat_output" | python3 -c "
import sys, json
seen = set()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        vid = obj.get('id','')
        if vid and vid not in seen:
            seen.add(vid)
            print(line)
    except: pass
")

channel_name=$(echo "$flat_output" | head -1 | python3 -c "import sys,json; print(json.load(sys.stdin).get('playlist_title',''))" 2>/dev/null | sed 's/ - Videos$//' || true)

if [ -z "$channel_name" ] || [ "$channel_name" = "NA" ]; then
    channel_name=$(echo "$CHANNEL_URL" | sed 's|.*/@@\?||; s|/.*||')
fi

log "Channel: ${channel_name}"

channel_base="${MEDIA_DIR}/${channel_name}"
mkdir -p "${channel_base}"

created=0
skipped=0

while IFS= read -r line; do
    [ -z "$line" ] && continue

    video_id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
    title=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null)
    raw_date=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_date',''))" 2>/dev/null || true)

    [ -z "$video_id" ] && continue

    if grep -qF -- "$video_id" "$ARCHIVE_FILE" 2>/dev/null; then
        skipped=$((skipped + 1))
        continue
    fi

    already_exists=false
    while IFS= read -r info_file; do
        [ -z "$info_file" ] && continue
        if grep -q "\"id\": \"${video_id}\"" "$info_file" 2>/dev/null; then
            already_exists=true
            break
        fi
    done < <(find "${channel_base}" -name "*.info.json" 2>/dev/null)
    if $already_exists; then
        skipped=$((skipped + 1))
        continue
    fi

    placeholder_exists=false
    while IFS= read -r pf; do
        [ -z "$pf" ] && continue
        if grep -qF -- "$video_id" "$pf" 2>/dev/null; then
            placeholder_exists=true
            break
        fi
    done < <(find "${channel_base}" -name "*.placeholder" 2>/dev/null)
    if $placeholder_exists; then
        skipped=$((skipped + 1))
        continue
    fi

    safe_title=$(echo "$title" | sed 's/[\/\\:*?"<>|]//g' | head -c 180)

    if [ -n "$raw_date" ] && [ "$raw_date" != "NA" ] && [ ${#raw_date} -eq 8 ]; then
        year="${raw_date:0:4}"
        mmdd="${raw_date:4:4}"
    else
        year=$(date +%Y)
        mmdd=$(date +%m%d)
    fi
    season_dir="${channel_base}/Season ${year}"
    mkdir -p "${season_dir}"
    existing_count=$(find "${season_dir}" -maxdepth 1 -name "${channel_name} - S${year}E${mmdd}*" -name "*.mp4" 2>/dev/null | wc -l | tr -d ' ')
    ep_index=$(printf "%02d" $((existing_count + 1)))

    base_name="${channel_name} - S${year}E${mmdd}${ep_index} - ${safe_title} [${video_id}]"
    mp4_file="${season_dir}/${base_name}.mp4"
    placeholder_file="${season_dir}/${base_name}.placeholder"
    thumb_file="${season_dir}/${base_name}.jpg"

    log "Creating placeholder: ${safe_title}"
    if ! generate_placeholder_mp4 "$mp4_file" "$channel_name" "$safe_title"; then
        log "ERROR: ffmpeg failed for ${safe_title}, skipping"
        continue
    fi

    echo "$video_id" > "$placeholder_file"

    curl -s -o "$thumb_file" "https://i.ytimg.com/vi/${video_id}/maxresdefault.jpg" 2>/dev/null || \
    curl -s -o "$thumb_file" "https://i.ytimg.com/vi/${video_id}/hqdefault.jpg" 2>/dev/null || true

    created=$((created + 1))

done <<< "$videos_json"

log "Done: ${created} placeholders created, ${skipped} skipped (already exist or downloaded)"
