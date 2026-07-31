#!/bin/bash
set -euo pipefail

PLEX_URL="${PLEX_URL:-}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
PLEX_SECTION="${PLEX_SECTION:-9}"
MEDIA_DIR="${MEDIA_DIR:-/media/youtube}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "Updating show posters from channel avatars..."

PLEX_URL="${PLEX_URL}" PLEX_TOKEN="${PLEX_TOKEN}" PLEX_SECTION="${PLEX_SECTION}" MEDIA_DIR="${MEDIA_DIR}" python3 << 'PYEOF'
import json, subprocess, os, glob, shutil
import os

PLEX_URL = os.environ["PLEX_URL"]
PLEX_TOKEN = os.environ["PLEX_TOKEN"]
PLEX_SECTION = int(os.environ.get("PLEX_SECTION", "9"))
MEDIA_DIR = os.environ.get("MEDIA_DIR", "/media/youtube")

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

    if has_thumb:
        skipped += 1
        continue

    r2 = subprocess.run(['curl', '-s', '-H', 'Accept: application/json', '-H', f'X-Plex-Token: {PLEX_TOKEN}',
        f'{PLEX_URL}/library/metadata/{rating_key}/allLeaves?X-Plex-Container-Size=1'],
        capture_output=True, text=True)
    eps = json.loads(r2.stdout)
    episodes = eps.get('MediaContainer', {}).get('Metadata', [])
    if not episodes:
        continue

    file_path = ''
    for media in episodes[0].get('Media', []):
        for part in media.get('Part', []):
            file_path = part.get('file', '')
            break

    if not file_path:
        continue

    norm_path = file_path.replace('\\', '/')
    parts = norm_path.split('/')
    try:
        yt_idx = parts.index('youtube')
        channel_folder = parts[yt_idx + 1]
    except (ValueError, IndexError):
        continue

    local_folder = os.path.join(MEDIA_DIR, channel_folder)
    season_na = os.path.join(local_folder, "Season NA")
    avatar = None

    if os.path.isdir(season_na):
        handle_candidates = glob.glob(os.path.join(season_na, "* [@*].jpg"))
        videos_candidates = glob.glob(os.path.join(season_na, "* - Videos *.jpg"))
        shorts_candidates = glob.glob(os.path.join(season_na, "* - Shorts *.jpg"))
        for pool in (handle_candidates, videos_candidates, shorts_candidates):
            if pool:
                avatar = pool[0]
                break

    if not avatar:
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

    tmp = f'/tmp/poster_{rating_key}.jpg'
    shutil.copyfile(avatar, tmp)
    # Convert to JPEG using ImageMagick (cross-platform, replaces macOS `sips`)
    subprocess.run(['convert', tmp, '-quality', '90', tmp], capture_output=True)

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
