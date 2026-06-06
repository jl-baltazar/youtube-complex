#!/bin/bash
# Updates Plex episode titles from filenames
# Extracts the title part from: "Channel - YYYY-MM-DD - Title.mp4"

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

PLEX_URL="http://192.168.1.78:32400"
PLEX_TOKEN="PY1xBcA7QT9r6swusu1x"
PLEX_SECTION=9

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Fixing episode titles from filenames..."

updated=0

# Get all episodes with their file paths
curl -s --connect-timeout 10 -H "Accept: application/json" -H "X-Plex-Token: ${PLEX_TOKEN}" \
    "${PLEX_URL}/library/sections/${PLEX_SECTION}/all?type=4&X-Plex-Container-Size=1000" \
    -o /tmp/plex_all_eps.json 2>/dev/null

python3 << 'PYEOF'
import json
import subprocess
import re
import urllib.parse

PLEX_URL = "http://192.168.1.78:32400"
PLEX_TOKEN = "PY1xBcA7QT9r6swusu1x"

with open('/tmp/plex_all_eps.json') as f:
    data = json.load(f)

updated = 0
episodes = data.get('MediaContainer', {}).get('Metadata', [])

for ep in episodes:
    rating_key = ep.get('ratingKey')
    current_title = ep.get('title', '')

    # Get file path from media
    file_path = ''
    for media in ep.get('Media', []):
        for part in media.get('Part', []):
            file_path = part.get('file', '')
            if file_path:
                break

    if not file_path:
        continue

    # Extract title from filename: "Channel - SxxxxExxxxxxxx - Title.ext"
    import os, ntpath
    # Use ntpath to handle Windows backslash paths from remote Plex
    basename = os.path.splitext(ntpath.basename(file_path))[0]

    # Match pattern: "Channel - SxxxxExxxxxxxx - Title [id]" or "Channel - YYYY-MM-DD - Title"
    match = re.match(r'^.+ - S\d{4}E\d{4,8} - (.+?)(?:\s*\[[\w-]+\])?$', basename)
    if not match:
        match = re.match(r'^.+ - \d{4}-\d{2}-\d{2} - (.+)$', basename)
    if not match:
        continue

    new_title = match.group(1).strip()

    if new_title and new_title != current_title:
        # Update title via API
        encoded_title = urllib.parse.quote(new_title)
        result = subprocess.run([
            'curl', '-s', '-X', 'PUT',
            '-H', f'X-Plex-Token: {PLEX_TOKEN}',
            f'{PLEX_URL}/library/metadata/{rating_key}?title.value={encoded_title}',
            '-w', '%{http_code}'
        ], capture_output=True, text=True)

        if result.stdout.endswith('200'):
            updated += 1
        else:
            print(f"  FAILED: {new_title[:50]} (HTTP {result.stdout[-3:]})")

print(f"Updated {updated} episode titles out of {len(episodes)} total.")
PYEOF