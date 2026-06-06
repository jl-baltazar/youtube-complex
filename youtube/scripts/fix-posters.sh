#!/bin/bash
# Uploads channel avatar images as Plex show posters
# Uses "NA - Channel.jpg" files from each channel folder

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

PLEX_URL="http://192.168.1.78:32400"
PLEX_TOKEN="PY1xBcA7QT9r6swusu1x"
PLEX_SECTION=9
MEDIA_DIR="/Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2/youtube"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Updating show posters from channel avatars..."

python3 << 'PYEOF'
import json, subprocess, os, glob, urllib.parse

PLEX_URL = "http://192.168.1.78:32400"
PLEX_TOKEN = "PY1xBcA7QT9r6swusu1x"
PLEX_SECTION = 9
MEDIA_DIR = "/Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2/youtube"

# Get all shows
r = subprocess.run(['curl', '-s', '-H', 'Accept: application/json', '-H', f'X-Plex-Token: {PLEX_TOKEN}',
    f'{PLEX_URL}/library/sections/{PLEX_SECTION}/all?X-Plex-Container-Size=500'],
    capture_output=True, text=True)
data = json.loads(r.stdout)
shows = data.get('MediaContainer', {}).get('Metadata', [])

updated = 0
skipped = 0

for show in shows:
    rating_key = show['ratingKey']
    title = show.get('title', '')
    has_thumb = bool(show.get('thumb'))

    # Skip if already has a poster
    if has_thumb:
        skipped += 1
        continue

    # Find channel folder - try to match by getting file path from first episode
    r2 = subprocess.run(['curl', '-s', '-H', 'Accept: application/json', '-H', f'X-Plex-Token: {PLEX_TOKEN}',
        f'{PLEX_URL}/library/metadata/{rating_key}/allLeaves?X-Plex-Container-Size=1'],
        capture_output=True, text=True)
    eps = json.loads(r2.stdout)
    episodes = eps.get('MediaContainer', {}).get('Metadata', [])
    if not episodes:
        continue

    # Get channel folder from episode file path
    file_path = ''
    for media in episodes[0].get('Media', []):
        for part in media.get('Part', []):
            file_path = part.get('file', '')
            break

    if not file_path:
        continue

    # Extract channel folder name from Z:\youtube\ChannelName\... (Windows Plex)
    # Normalize backslashes to forward slashes
    norm_path = file_path.replace('\\', '/')
    parts = norm_path.split('/')
    # Find "youtube" in path and take the next component as channel folder
    try:
        yt_idx = parts.index('youtube')
        channel_folder = parts[yt_idx + 1]
    except (ValueError, IndexError):
        continue

    # Find avatar image in local folder
    # New structure: "Season NA/ChannelName - SNAENA01 - ... [@handle].jpg"
    # Fallback: legacy "NA - ChannelName.jpg" at channel root
    local_folder = os.path.join(MEDIA_DIR, channel_folder)
    season_na = os.path.join(local_folder, "Season NA")
    avatar = None

    if os.path.isdir(season_na):
        # Preference: [@handle].jpg (channel itself) > - Videos > - Shorts
        handle_candidates = glob.glob(os.path.join(season_na, "* [@*].jpg"))
        videos_candidates = glob.glob(os.path.join(season_na, "* - Videos *.jpg"))
        shorts_candidates = glob.glob(os.path.join(season_na, "* - Shorts *.jpg"))
        for pool in (handle_candidates, videos_candidates, shorts_candidates):
            if pool:
                avatar = pool[0]
                break

    if not avatar:
        # Legacy layout fallback
        legacy = os.path.join(local_folder, f"NA - {channel_folder}.jpg")
        if os.path.exists(legacy):
            avatar = legacy
        else:
            legacy_candidates = glob.glob(os.path.join(local_folder, "NA - *.jpg"))
            legacy_candidates = [c for c in legacy_candidates if not c.endswith(' - Shorts.jpg')]
            if legacy_candidates:
                avatar = legacy_candidates[0]

    if not avatar:
        continue

    # Ensure avatar is real JPEG (yt-dlp sometimes saves PNG with .jpg extension)
    import shutil
    tmp = f'/tmp/poster_{rating_key}.jpg'
    shutil.copyfile(avatar, tmp)  # copyfile, not copy2 — NAS mount rejects chflags
    subprocess.run(['sips', '-s', 'format', 'jpeg', tmp, '--out', tmp],
                   capture_output=True)

    # Upload poster via API (raw binary, not multipart)
    result = subprocess.run([
        'curl', '-s', '-X', 'POST',
        '-H', f'X-Plex-Token: {PLEX_TOKEN}',
        '-H', 'Content-Type: image/jpeg',
        '--data-binary', f'@{tmp}',
        f'{PLEX_URL}/library/metadata/{rating_key}/posters',
        '-w', '%{http_code}',
        '--max-time', '15'
    ], capture_output=True, text=True)
    os.remove(tmp)

    if '200' in result.stdout[-3:]:
        updated += 1
    else:
        print(f"  FAILED: {title[:40]} (HTTP {result.stdout[-3:]})")

print(f"Updated {updated} show posters, {skipped} already had one.")
PYEOF