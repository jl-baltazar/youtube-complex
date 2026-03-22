#!/bin/bash
# One-time script: re-downloads former AV1 videos in H.264 format
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/config/yt-dlp.conf"
LOG_DIR="${BASE_DIR}/state/logs"
URL_FILE="/tmp/av1_redownload_urls.txt"

COOKIE_OPTION=""
if [[ -s "${BASE_DIR}/config/cookies.txt" ]] && grep -qE '^\.' "${BASE_DIR}/config/cookies.txt"; then
  COOKIE_OPTION=(--cookies "${BASE_DIR}/config/cookies.txt")
fi

total=$(wc -l < "$URL_FILE" | tr -d ' ')
current=0
success=0
failed=0

echo "[$(date)] Starting re-download of $total videos in H.264..."

while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    current=$((current + 1))
    echo "[$(date)] [$current/$total] Downloading: $url"

    if yt-dlp --config-location "$CONFIG_FILE" "${COOKIE_OPTION[@]}" \
        --no-playlist "$url" 2>&1 | tee -a "${LOG_DIR}/redownload.log"; then
        success=$((success + 1))
    else
        failed=$((failed + 1))
        echo "$url" >> /tmp/av1_redownload_failed.txt
    fi

    # Small delay to avoid rate limiting
    sleep 2
done < "$URL_FILE"

echo "[$(date)] Re-download complete: $success succeeded, $failed failed out of $total"

# Trigger Plex scan
echo "[$(date)] Triggering Plex scan..."
docker exec -e LD_LIBRARY_PATH=/usr/lib/plexmediaserver plex \
    "/usr/lib/plexmediaserver/Plex Media Scanner" --scan --section 6 2>/dev/null

"${BASE_DIR}/scripts/fix-titles.sh" 2>/dev/null
"${BASE_DIR}/scripts/fix-posters.sh" 2>/dev/null

echo "[$(date)] Done!"
