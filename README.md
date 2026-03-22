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
- **Why:** Prevents Plex from grouping same-day videos as "versions" of one episode

### yt-dlp.conf
- **Format:** `bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]` — H.264 preferred
- **Output:** `~/Movies/youtube/%(uploader)s/%(uploader)s - S%(upload_date>%Y)sE%(upload_date>%m%d)s01 - %(title)s [%(id)s].%(ext)s`
- **Archive:** `state/archive.txt` prevents re-downloading
- **Per-channel limits:** `--playlist-end 2` (check 2 most recent), `--max-downloads 1` (stop after first new)
- **Metadata:** writes info.json, thumbnail (converted to jpg), embeds thumbnail + metadata

### Plex
- **Container:** `plexinc/pms-docker:latest`
- **Ports:** 32400 (Web UI/API), 32469 (DLNA), GDM discovery
- **Volumes:** `~/Movies` → `/media` (container path)
- **Library:** Section 6, Plex Series Scanner
- **Media prefix (container):** `/media/youtube`
- **Webhook URL:** `http://host.docker.internal:9090/webhook` (configured in Plex Settings → Webhooks)

### Cookies
- **Location:** `youtube/config/cookies.txt`
- **Format:** Netscape HTTP Cookie File (exported from Chrome via "Get cookies.txt LOCALLY" extension)
- **Important:** Without valid cookies, ALL downloads fail with `Sign in to confirm you're not a bot`
- **Expiry:** Cookies expire periodically — must be re-exported when downloads start failing

---

## launchd Services

| Plist | Script | Behavior |
|---|---|---|
| `com.jlgarcia.youtube-dl` | `download.sh` | RunAtLoad + KeepAlive — starts on login, restarts if killed |
| `com.jlgarcia.plex-start` | `start-plex.sh` | RunAtLoad — starts Plex container on login |
| `com.jlgarcia.youtube-webhook` | `stream-proxy.py --port 9090` | RunAtLoad + KeepAlive — streaming proxy + webhook |

Logs go to `youtube/state/logs/`.

---

## Scripts Detail

### download.sh (main loop)
1. Enforces storage limit (90% disk usage)
   - Phase 1: deletes watched videos (via Plex API `viewCount>=1`)
   - Phase 2: deletes oldest unwatched videos
2. Iterates `channels.txt`, runs yt-dlp per channel
3. Triggers Plex library scan
4. Runs fix-titles.sh and fix-posters.sh
5. Sleeps 3600 seconds, repeats

### stream-proxy.py (streaming proxy + webhook)
- **GET /stream/:id** — Streams YouTube video to Plex. Checks local disk first; if not found, fetches YouTube CDN URL via `yt-dlp --get-url` and proxies the stream. Triggers background download on first request.
- **POST /webhook** — Receives Plex webhook events (`media.play`). For placeholder items, triggers background download.
- **GET /health** — Returns JSON status with list of active downloads.

### generate-placeholders.sh
- Creates `.strm` files for the last N videos of a YouTube channel
- Usage: `bash generate-placeholders.sh "https://www.youtube.com/@Channel" 10`

### redownload-h264.sh
- Re-downloads AV1/VP9 videos as H.264
- Run manually: `bash ~/youtube-complex/youtube/scripts/redownload-h264.sh`

### fix-titles.sh
- Updates Plex episode titles from filenames via API

### fix-posters.sh
- Uploads channel avatars as Plex show posters

---

## Common Operations

```bash
# Check download progress
tail -5 ~/youtube-complex/youtube/state/logs/download.log

# Check streaming proxy
curl -s http://localhost:9090/health

# Generate placeholders for a channel
bash ~/youtube-complex/youtube/scripts/generate-placeholders.sh "https://www.youtube.com/@Channel" 10

# Check disk usage
df -h ~/Movies/youtube

# Start Plex
bash ~/youtube-complex/start-plex.sh

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
```

---

## Known Issues

- **Cookies expire:** Re-export from Chrome when downloads fail with `LOGIN_REQUIRED`
- **"ERROR" in download.log is often normal:** `--max-downloads 1` exits non-zero after 1 download
- **AV1/VP9 playback:** Some older videos don't play on TVs — use `redownload-h264.sh`
- **Old naming coexists with new:** Existing videos use `YYYY-MM-DD`; new use `SxxEyy`
- **Plex DB repair:** Must use Plex's own `Plex SQLite` binary from inside Docker
