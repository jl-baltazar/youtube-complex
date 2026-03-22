# YouTube + Plex Automated System

Automated YouTube channel archival system that downloads videos and serves them via Plex Media Server, with on-demand streaming via placeholder system.

---

## Architecture

```
iPhone (future: iCloud Drive watcher)
        │
        ▼
┌─────────────────────────────────┐
│  download.sh (loop every 1hr)   │ ← launchd: com.jlgarcia.youtube-dl
│  - reads channels.txt           │
│  - yt-dlp with cookies + config │
│  - enforces 90% disk limit      │
│  - triggers Plex scan           │
│  - runs fix-titles + fix-posters│
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│  ~/Movies/youtube/{channel}/    │  ← H.264/AAC MP4 files
│  {Channel} - SxxxxEyyyyzz -    │    SxxEyy naming (Season=year, Episode=MMDD+index)
│  {Title} [{video_id}].mp4      │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│  Plex Media Server (Docker)     │ ← launchd: com.jlgarcia.plex-start
│  Port 32400, Section 6          │
│  Plex Series Scanner            │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│  stream-proxy.py (port 9090)    │ ← launchd: com.jlgarcia.youtube-webhook
│  - /stream/:id  → YouTube CDN  │   .strm files point here for streaming
│  - /webhook     → Plex events  │   background download after streaming
│  - /health      → status check │
└─────────────────────────────────┘
```

### Placeholder / Streaming Flow
1. `generate-placeholders.sh <channel_url> [count]` creates `.strm` files pointing to `http://host.docker.internal:9090/stream/{video_id}`
2. Plex sees `.strm` files as playable episodes (with thumbnails)
3. When played, Plex requests the stream URL → `stream-proxy.py` fetches the YouTube CDN URL via `yt-dlp --get-url` and proxies the stream
4. Simultaneously, the proxy triggers a background download (H.264, full quality) for future offline plays
5. Once downloaded, the `.strm` and `.placeholder` sidecar are removed; Plex scans and shows the local file
6. Future plays serve directly from disk

---

## Directory Structure

```
~/youtube-complex/
├── docker-compose.yml          # Plex container definition
├── youtube-service.yml         # YouTube ingest container (not currently used — runs natively)
├── start-plex.sh               # Detects local IP, starts Plex container
├── .env                        # TZ, PLEX_UID, PLEX_GID
├── youtube/
│   ├── config/
│   │   ├── channels.txt        # ~311 YouTube channel URLs (one per line, # for comments)
│   │   ├── cookies.txt         # Netscape-format cookies exported from Chrome (required for downloads)
│   │   └── yt-dlp.conf         # yt-dlp config: H.264 format, SxxEyy naming, archive, metadata
│   ├── scripts/
│   │   ├── download.sh         # Main loop: downloads latest video per channel every hour
│   │   ├── stream-proxy.py     # Streaming proxy + Plex webhook receiver (port 9090)
│   │   ├── generate-placeholders.sh  # Creates .strm placeholders for on-demand streaming
│   │   ├── redownload-h264.sh  # One-time: re-downloads AV1/VP9 videos as H.264
│   │   ├── fix-titles.sh       # Updates Plex episode titles from filenames via API
│   │   ├── fix-posters.sh      # Uploads channel avatars as Plex show posters via API
│   │   └── migrate-naming.sh   # One-time: migrates old naming to SxxEyy format
│   └── state/
│       ├── archive.txt         # yt-dlp download archive (video IDs already downloaded)
│       └── logs/               # download.log, yt-dlp.log, stream-proxy.log, etc.
├── plex/
│   ├── config/                 # Plex server persistent config (database, plugins, etc.)
│   └── transcode/              # Plex transcoding cache
```

---

## Key Configuration

### File Naming Convention (SxxEyy)
- **Format:** `{Channel} - S{YYYY}E{MMDD}{index} - {Title} [{video_id}].{ext}`
- **Example:** `31 minutos - S2026E012601 - Objeción denegada (demo) [_dMhuinekUc].mp4`
- **Season** = upload year (e.g., S2026)
- **Episode** = MMDD + 2-digit index (e.g., E012601 = Jan 26, 1st video of the day)
- **Why:** Prevents Plex from grouping same-day videos as "versions" of one episode (the old `YYYY-MM-DD` naming caused this)
- **Note:** Old videos still use `YYYY-MM-DD` naming; new downloads and placeholders use SxxEyy

### yt-dlp.conf
- **Format:** `bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]` — H.264 preferred (AV1/VP9 won't play on most TVs)
- **Output:** `~/Movies/youtube/%(uploader)s/%(uploader)s - S%(upload_date>%Y)sE%(upload_date>%m%d)s01 - %(title)s [%(id)s].%(ext)s`
- **Archive:** `state/archive.txt` prevents re-downloading
- **Per-channel limits:** `--playlist-end 2` (check 2 most recent), `--max-downloads 1` (stop after first new)
- **Metadata:** writes info.json, thumbnail (converted to jpg), embeds thumbnail + metadata

### Plex
- **Container:** `plexinc/pms-docker:latest`
- **Ports:** 32400 (Web UI/API), 32469 (DLNA), GDM discovery
- **Volumes:** `~/Movies` → `/media` (container path)
- **Library:** Section 6, Plex Series Scanner
- **Token:** `GNEaLTTQ1t932g8LUT7G`
- **Media prefix (container):** `/media/youtube`
- **Webhook URL:** `http://host.docker.internal:9090/webhook` (configured in Plex Settings → Webhooks)

### Cookies
- **Location:** `youtube/config/cookies.txt`
- **Format:** Netscape HTTP Cookie File (exported from Chrome via "Get cookies.txt LOCALLY" extension)
- **Required cookies:** HSID, SSID, SID, LOGIN_INFO, __Secure-1PSID, __Secure-3PSID, SAPISID, and others
- **Important:** Without valid cookies, ALL downloads fail with `Sign in to confirm you're not a bot`
- **Expiry:** Cookies expire periodically (weeks/months) — must be re-exported from browser when downloads start failing
- **Validation:** Scripts check for lines starting with `.` in the cookie file

---

## launchd Services

| Plist | Script | Behavior |
|---|---|---|
| `com.jlgarcia.youtube-dl` | `download.sh` | RunAtLoad + KeepAlive — starts on login, restarts if killed |
| `com.jlgarcia.plex-start` | `start-plex.sh` | RunAtLoad — starts Plex container on login |
| `com.jlgarcia.youtube-webhook` | `stream-proxy.py --port 9090` | RunAtLoad + KeepAlive — streaming proxy + webhook |

Logs go to `youtube/state/logs/` (launchd-stdout.log, plex-start.log, stream-proxy.log, webhook-stdout.log).

---

## Scripts Detail

### download.sh (main loop)
1. Enforces storage limit (90% disk usage)
   - Phase 1: deletes watched videos (via Plex API `viewCount>=1`)
   - Phase 2: deletes oldest unwatched videos (uses temp file to avoid pipefail issues)
2. Iterates `channels.txt`, runs yt-dlp per channel
3. Triggers Plex library scan via `Plex Media Scanner --scan --section 6`
4. Runs fix-titles.sh and fix-posters.sh
5. Sleeps 3600 seconds, repeats

**Note:** `--max-downloads 1` causes yt-dlp to exit with non-zero code (expected behavior). The script logs these as "ERROR" but they're normal — means it downloaded 1 video and stopped.

### stream-proxy.py (streaming proxy + webhook)
- **GET /stream/:id** — Streams YouTube video to Plex. Checks local disk first; if not found, fetches YouTube CDN URL via `yt-dlp --get-url` and proxies the stream. Triggers background download on first request.
- **POST /webhook** — Receives Plex webhook events (`media.play`). For placeholder items, triggers background download.
- **GET /health** — Returns JSON status with list of active downloads.
- Caches CDN URLs for 5 minutes (YouTube URLs expire).
- After background download completes, cleans up `.strm` and `.placeholder` files, triggers Plex scan.

### generate-placeholders.sh
- Creates `.strm` files for the last N videos of a YouTube channel
- Each `.strm` contains `http://host.docker.internal:9090/stream/{video_id}`
- Also creates `.placeholder` sidecar (contains video ID) and downloads thumbnail
- Skips videos already in archive, already downloaded, or with existing placeholders
- Usage: `bash generate-placeholders.sh "https://www.youtube.com/@Channel" 10`
- Does NOT affect download.sh or the regular hourly cycle

### redownload-h264.sh
- Reads URLs from `/tmp/av1_redownload_urls.txt`
- Re-downloads each in H.264 format using same yt-dlp.conf
- Tracks failures in `/tmp/av1_redownload_failed.txt`
- Run manually: `bash ~/youtube-complex/youtube/scripts/redownload-h264.sh`

### fix-titles.sh
- Queries Plex API for all episodes in section 6
- Extracts title from filename pattern
- Updates Plex episode title via `PUT /library/metadata/{id}?title.value=...`

### fix-posters.sh
- Finds shows without posters in Plex
- Looks for `NA - {channel}.jpg` avatar in channel folder
- Uploads as show poster via `POST /library/metadata/{id}/posters`

---

## Common Operations

```bash
# Check download progress
tail -5 ~/youtube-complex/youtube/state/logs/download.log

# Check streaming proxy logs
tail -20 ~/youtube-complex/youtube/state/logs/stream-proxy.log

# Check streaming proxy health
curl -s http://localhost:9090/health

# Generate placeholders for a channel (on-demand streaming)
bash ~/youtube-complex/youtube/scripts/generate-placeholders.sh "https://www.youtube.com/@Channel" 10

# Check disk usage
df -h ~/Movies/youtube

# Start Plex
bash ~/youtube-complex/start-plex.sh

# Fix titles/posters manually
bash ~/youtube-complex/youtube/scripts/fix-titles.sh
bash ~/youtube-complex/youtube/scripts/fix-posters.sh

# Check if services are running
ps aux | grep download.sh | grep -v grep
docker ps | grep plex
curl -s http://localhost:9090/health

# Restart streaming proxy
launchctl stop com.jlgarcia.youtube-webhook && launchctl start com.jlgarcia.youtube-webhook

# Reload launchd agents
launchctl load ~/Library/LaunchAgents/com.jlgarcia.youtube-dl.plist
launchctl load ~/Library/LaunchAgents/com.jlgarcia.plex-start.plist
launchctl load ~/Library/LaunchAgents/com.jlgarcia.youtube-webhook.plist

# View Plex Web UI
open http://localhost:32400/web

# Repair Plex database (if corrupted)
# Use Plex's own SQLite binary inside Docker:
# docker run --rm -v "DB_PATH:/databases" --entrypoint bash plexinc/pms-docker:latest -c '
#   export LD_LIBRARY_PATH=/usr/lib/plexmediaserver/lib
#   SQLITE="/usr/lib/plexmediaserver/Plex SQLite"
#   "$SQLITE" /databases/com.plexapp.plugins.library.db .dump > /tmp/dump.sql
#   sed "s/ROLLBACK; -- due to errors/COMMIT;/" /tmp/dump.sql > /tmp/fixed.sql
#   "$SQLITE" /databases/com.plexapp.plugins.library.db.repaired < /tmp/fixed.sql
# '
```

---

## Known Issues & Gotchas

- **Cookies expire:** When downloads start failing with `LOGIN_REQUIRED`, re-export cookies from Chrome using "Get cookies.txt LOCALLY" extension and overwrite `config/cookies.txt`
- **"ERROR" in download.log is often normal:** `--max-downloads 1` causes yt-dlp to exit non-zero after downloading 1 video. Check `yt-dlp.log` for actual errors.
- **AV1/VP9 playback:** Some older videos were downloaded in AV1/VP9 which don't play on TVs. Use `redownload-h264.sh` to convert them.
- **Disk cleanup:** Automatic at 90% — watched videos deleted first, then oldest unwatched. Managed by `download.sh`.
- **Plex container path vs local path:** Plex sees `/media/youtube/...`, local is `~/Movies/youtube/...`. Scripts handle the translation.
- **Plex webhook URL must use `host.docker.internal`:** Since Plex runs in Docker, `localhost` inside the container refers to the container itself. Webhook and .strm URLs must use `http://host.docker.internal:9090/...`.
- **docker-compose.yml only defines Plex.** `youtube-service.yml` exists but download.sh runs natively via launchd, not in Docker.
- **Plex DB repair:** System `sqlite3` cannot read Plex DB (missing `icu_root` collation). Must use Plex's own `Plex SQLite` binary from inside the Docker container.
- **Old naming coexists with new:** Existing videos use `YYYY-MM-DD` format; new downloads use `SxxEyy`. Both work in Plex but old format may group same-day videos as versions.
- **`set -euo pipefail` gotchas in bash scripts:** Pipes with `grep -q` or `find|sort|head|cut` can fail unexpectedly. Use temp files or process substitution instead.
- **Video IDs starting with `-`:** Use `grep -qF --` to prevent grep from interpreting them as flags.

---

## Pending / Future

- **Rename existing videos to SxxEyy:** Old videos (~300+ channels) still use `YYYY-MM-DD` naming. New downloads use SxxEyy via yt-dlp.conf. A batch rename script is needed for existing files.
- **iMessage/iCloud Drive watcher:** Planned feature to send YouTube URLs from iPhone → iCloud Drive file → Mac script detects and downloads.
- **OAuth2 for yt-dlp:** Would eliminate need for manual cookie refresh. Not yet configured.
