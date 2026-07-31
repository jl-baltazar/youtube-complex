# YouTube + Plex Automated System

Automated YouTube channel archival system. Downloads videos hourly, stores them on a NAS, and serves them via Plex Media Server. Runs entirely in Docker — deploy it on any Windows/Linux server that has access to your NAS and Plex.

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │         Windows Server               │
                    │                                      │
                    │  ┌──────────────────────────────┐   │
                    │  │  Docker: yt-downloader       │   │
                    │  │  download.sh (loop, 1hr)     │   │
                    │  │  - reads config/channels.txt │   │
                    │  │  - yt-dlp H.264 + cookies    │   │
                    │  │  - enforces 90% disk limit   │   │
                    │  │  - triggers Plex scan        │   │
                    │  └──────────────┬───────────────┘   │
                    │                 │ writes to          │
                    │  ┌──────────────▼───────────────┐   │
                    │  │  NAS (Z:\youtube)            │   │
                    │  │  {Channel}/Season {YYYY}/    │   │
                    │  │  {Channel} - SxxxxEyyyy -   │   │
                    │  │  {Title} [{id}].mp4          │   │
                    │  └──────────────┬───────────────┘   │
                    │                 │ library path       │
                    │  ┌──────────────▼───────────────┐   │
                    │  │  Plex Media Server           │   │
                    │  │  Port 32400, Section 9       │   │
                    │  │  Z:\youtube → TV Shows       │   │
                    │  └──────────────────────────────┘   │
                    │                                      │
                    │  ┌──────────────────────────────┐   │
                    │  │  Docker: yt-stream-proxy     │   │
                    │  │  stream-proxy.py (port 9090) │   │
                    │  │  POST /webhook → on-demand   │   │
                    │  │  GET  /health  → status      │   │
                    │  └──────────────────────────────┘   │
                    └──────────────────────────────────────┘
```

### On-Demand Placeholder Flow
1. `generate-placeholders.sh <channel_url> [N]` creates short placeholder MP4s ("Descargando...") for the last N videos of a channel
2. A `.placeholder` sidecar stores the YouTube video ID
3. When played in Plex, the webhook (`POST /webhook`) fires → `stream-proxy.py` starts a background download of the real video
4. Once downloaded, the placeholder MP4 and `.placeholder` sidecar are removed; Plex rescans
5. Future plays serve from disk

---

## Prerequisites

- **Windows Server** (or any Linux host) with:
  - Direct access to the NAS share (mapped drive or UNC path)
  - Plex Media Server already installed and running
- **Docker Desktop** (Windows) — see [Installation](#1-install-docker-desktop-windows)
- **YouTube cookies** exported from Chrome — required for authenticated downloads

---

## Deployment

### 1. Install Docker Desktop (Windows)

1. Download from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
2. Run the installer — enable **WSL2** when prompted (recommended backend)
3. Restart the machine
4. Open Docker Desktop and wait for it to start (whale icon in taskbar)
5. Verify: open PowerShell and run `docker --version`

> **Note:** If Docker Desktop asks about WSL2 kernel update, follow the link it provides and install it before continuing.

---

### 2. Clone the Repository

Open **PowerShell** (or Windows Terminal) and run:

```powershell
git clone https://github.com/jl-baltazar/youtube-complex.git
cd youtube-complex
```

If git is not installed: download from [git-scm.com](https://git-scm.com/download/win).

---

### 3. Configure Environment Variables

Copy the example file and edit it:

```powershell
copy .env.example .env
notepad .env
```

Fill in every value:

```env
# Path to the youtube folder on the NAS, as Docker can see it.
# Use forward slashes. Examples:
#   Mapped drive:  MEDIA_PATH=Z:/youtube
#   UNC path:      MEDIA_PATH=//192.168.1.130/USB_TOSHIBA_EXTERNAL_USB_a_2/youtube
MEDIA_PATH=Z:/youtube

# Plex server URL and credentials
PLEX_URL=http://192.168.1.78:32400
PLEX_TOKEN=your_plex_token_here
PLEX_SECTION=9

# Path to the youtube folder as Plex sees it (Windows path, backslashes OK)
PLEX_MEDIA_PREFIX=Z:\youtube

# Port for the on-demand proxy (must match the Plex webhook URL)
PROXY_PORT=9090
```

**Finding your Plex token:** In Plex Web, open any item → click ··· → Get Info → View XML. The token appears in the URL as `X-Plex-Token=...`.

> **Mapped drive vs UNC path:** If `Z:\` is a network-mapped drive, Docker Desktop (WSL2) may not see it directly. If that happens, set `MEDIA_PATH` to the UNC path (`//server/share/youtube`) instead, and add that path to Docker Desktop → Settings → Resources → File Sharing.

---

### 4. Add YouTube Cookies

YouTube requires authentication cookies to avoid "Sign in to confirm you're not a bot" errors.

1. Install the Chrome extension **"Get cookies.txt LOCALLY"**
2. Go to [youtube.com](https://youtube.com) and make sure you are logged in
3. Click the extension → **Export** → save as `cookies.txt`
4. Copy the file to `youtube\config\cookies.txt`

```powershell
copy C:\Users\YourUser\Downloads\cookies.txt youtube\config\cookies.txt
```

> **Cookies expire** every few weeks. When downloads start failing with `LOGIN_REQUIRED`, re-export and overwrite this file.

---

### 5. Review Channel List

Open `youtube\config\channels.txt` — one YouTube channel URL per line. Lines starting with `#` are comments.

```
# Fútbol
https://www.youtube.com/@TUDN
https://www.youtube.com/@FoxSports

# Tech
https://www.youtube.com/@Fireship
```

---

### 6. Build and Start

```powershell
docker compose up -d --build
```

This builds the image and starts two containers:

| Container | What it does |
|---|---|
| `yt-downloader` | Download loop — runs every hour, processes all channels |
| `yt-stream-proxy` | Webhook proxy — listens on port 9090 for Plex play events |

Check that both are running:

```powershell
docker compose ps
```

Watch the download logs:

```powershell
docker compose logs -f downloader
```

---

### 7. Configure Plex Webhook (for on-demand placeholders)

In Plex Web:

1. Go to **Settings → Webhooks**
2. Add webhook URL: `http://localhost:9090/webhook`
3. Save

Now when you play a placeholder video, the real download starts automatically in the background.

---

## Directory Structure

```
youtube-complex/
├── Dockerfile                  # Image: python:3.12-slim + ffmpeg + yt-dlp + imagemagick
├── docker-compose.yml          # Services: downloader + stream-proxy
├── .env                        # Your secrets — gitignored, never commit this
├── .env.example                # Template for .env
├── youtube/
│   ├── config/
│   │   ├── channels.txt        # YouTube channel URLs (one per line, # for comments)
│   │   ├── playlists.txt       # YouTube playlists (URL | Custom Name, one per line)
│   │   ├── cookies.txt         # Netscape cookies — gitignored, add manually
│   │   ├── yt-dlp.conf         # yt-dlp options for channel downloads
│   │   └── yt-dlp-playlist.conf  # yt-dlp options for playlist downloads
│   ├── scripts/
│   │   ├── download.sh               # Main hourly loop
│   │   ├── download-playlists.sh     # Playlist downloader (called by download.sh)
│   │   ├── stream-proxy.py           # Webhook receiver + health endpoint
│   │   ├── generate-placeholders.sh  # Creates placeholder MP4s for on-demand
│   │   ├── fix-titles.sh             # Syncs episode titles to Plex via API
│   │   ├── fix-posters.sh            # Uploads channel avatars as show posters
│   │   └── redownload-h264.sh        # One-time: re-downloads AV1/VP9 as H.264
│   └── state/                        # Gitignored — created at runtime
│       ├── archive.txt               # yt-dlp download archive (already-downloaded IDs)
│       └── logs/                     # download.log, yt-dlp.log, stream-proxy.log, etc.
```

---

## Common Operations

```powershell
# Check service status
docker compose ps

# Follow download logs
docker compose logs -f downloader

# Follow proxy logs
docker compose logs -f stream-proxy

# Check disk usage and proxy health
docker compose exec stream-proxy curl -s http://localhost:9090/health

# Restart a service
docker compose restart downloader
docker compose restart stream-proxy

# Stop everything
docker compose down

# Start everything (after a reboot)
docker compose up -d

# Rebuild the image (after a git pull with script changes)
docker compose up -d --build
```

### Add a Channel

Edit `youtube\config\channels.txt` and add the channel URL. The downloader picks it up on the next cycle (no restart needed).

### Add a Playlist

Edit `youtube\config\playlists.txt`:

```
https://www.youtube.com/playlist?list=PLxxxxx | Nombre del Curso
```

Playlists are downloaded every cycle alongside channels, and their folder is protected from the disk-space cleanup.

### Generate Placeholders for On-Demand

```powershell
docker compose exec downloader bash /app/scripts/generate-placeholders.sh "https://www.youtube.com/@ChannelName" 10
```

Creates placeholder MP4s for the last 10 videos. Play one in Plex to trigger the real download.

### Force a Plex Scan

```powershell
# Replace with your values
curl -X POST "http://192.168.1.78:32400/library/sections/9/refresh?X-Plex-Token=YOUR_TOKEN"
```

### Update Cookies

1. Re-export `cookies.txt` from Chrome (see step 4 above)
2. Overwrite `youtube\config\cookies.txt`
3. No restart needed — the script reads the file on each download

### Pull Updates

```powershell
git pull
docker compose up -d --build
```

---

## File Naming Convention

```
{Channel} - S{YYYY}E{MMDD}{index} - {Title} [{video_id}].mp4
```

Example:
```
31 minutos - S2026E012601 - Objeción denegada [_dMhuinekUc].mp4
              │    │    └─ 01 = first video of that day
              │    └────── 0126 = Jan 26
              └─────────── 2026 = year (Plex season)
```

- **Season** = upload year → shows videos grouped by year in Plex
- **Episode** = MMDD + 2-digit index → unique even for same-day uploads
- **H.264 only** (`vcodec^=avc1`) — AV1/VP9 won't play on most TVs via Plex

---

## Storage Management

The downloader enforces a **90% disk usage limit** before each download cycle:

1. **Phase 1:** Deletes all watched videos (Plex `viewCount >= 1`) — always runs
2. **Phase 2:** Deletes oldest unwatched videos until usage drops below 90%
3. **Protected folders** (playlists): never deleted by the cleanup

Watched videos are deleted automatically, so mark things as watched in Plex when you're done with them.

---

## Known Issues

| Issue | Solution |
|---|---|
| Downloads fail with `LOGIN_REQUIRED` | Re-export `cookies.txt` from Chrome |
| `ERROR: giving up` in logs after 1 download | Normal — `--max-downloads 1` exits non-zero by design |
| Mapped drive `Z:\` not visible to Docker | Use UNC path `//server/share/youtube` in `MEDIA_PATH` instead |
| Videos don't play on TV (codec issue) | Run `redownload-h264.sh` to re-download as H.264 |
| Plex scan not triggering | Check `PLEX_URL`, `PLEX_TOKEN`, and `PLEX_SECTION` in `.env` |
