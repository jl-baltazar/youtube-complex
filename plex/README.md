# Plex Media Server (YouTube Complex)

This README accompanies the `docker-compose.yml` Plex service definition and provides first-run guidance.

## Folder Layout

```
/Users/jlgarcia/youtube-complex
├── docker-compose.yml   # Project-level compose
└── plex/
    ├── config/          # Plex will populate at first run
    └── transcode/       # Plex will populate at first run
```

If `plex/config` or `plex/transcode` do not exist, create them:

```bash
mkdir -p plex/{config,transcode}
# match host UID/GID for correct permissions (example assumes macOS defaults)
chown -R $(id -u):$(id -g) plex/
```

## Environment variables

Add a `.env` file next to `docker-compose.yml` or export before compose-up:

```
TZ=America/Los_Angeles
PLEX_UID=$(id -u)
PLEX_GID=$(id -g)
```

## Running Plex

```bash
cd /Users/jlgarcia/youtube-complex
# start in detached mode
docker compose up -d plex
```

Docker Desktop on macOS does not support true `host` networking. The compose file exposes ports 32400 and 32469 by default. If ports 1900 or 5353 are occupied, leave them commented out as they are optional.

## First-time Setup Steps

1. **Wait 1-2 minutes** for Plex to fully initialize after container start.
2. Open `http://localhost:32400/web` in your browser.
3. **Sign in** to your existing Plex account (or create a new one).
4. **Claim the server** if prompted (click "Claim Server" or similar).
5. **Create your first library:**
   - Click ➕ next to "Libraries" in the sidebar
   - Choose **"Other Videos"** (recommended for YouTube downloads with folders)
   - Name it "YouTube" (or any name you prefer)
   - Click **"Add Folders"**
   - Navigate to and select **`/media/youtube`** (NOT `/Users/jlgarcia/Movies/youtube`)
   - Click **"Add Library"**
6. **Configure the scanner BEFORE finishing:**
   - Before clicking "Add Library", click **"Advanced"** tab
   - Set **Scanner**: `Plex Video Files Scanner`
   - Set **Agent**: `Personal Media`
   - Click **"Add Library"** to save
7. Plex will start scanning automatically. Videos should appear within minutes.

**Important:** For YouTube downloads with subfolders, use "Other Videos" with "Personal Media" agent. This ensures all files are indexed regardless of naming patterns.

## Validation Checklist

- Plex container is `running` (`docker compose ps`).
- Web UI loads at `http://localhost:32400`.
- In Plex, browse `Settings → Libraries` — the `YouTube` library shows items.
- Inside container, `/media` lists your host‟s `Movies` content:

  ```bash
  docker compose exec plex ls /media | head
  ```

- Logs show library scan, e.g. `/usr/lib/plexmediaserver/Plex Media Scanner` entries.

## Starting Fresh (Reset Plex Configuration)

If you need to completely reset Plex and start from scratch:

```bash
cd /Users/jlgarcia/youtube-complex

# Stop the container
docker compose down

# Backup and remove existing config (optional but recommended)
if [ -d "plex/config" ]; then
  mv plex/config plex/config.backup-$(date +%Y%m%d-%H%M%S)
  echo "Backup created"
fi

# Create fresh config directory
mkdir -p plex/{config,transcode}
chown -R $(id -u):$(id -g) plex/

# Start fresh
docker compose up -d plex
```

Wait 1-2 minutes, then follow the "First-time Setup Steps" above.

## Common Issues

| Symptom | Remedy |
|---------|--------|
| Cannot access UI | Ensure port 32400 free; wait 1-2 minutes after container start |
| Library empty | Verify videos exist at `/Users/jlgarcia/Movies/youtube`; check Scanner = "Plex Video Files Scanner" and Agent = "Personal Media" |
| Permission denied errors | Match `PLEX_UID/GID` to file ownership or relax permissions (`chmod -R 755`) |
| Folders show as empty | Use "Other Videos" library type, not "Movies" or "TV Shows" |
| Database corruption errors | Start fresh using the "Starting Fresh" section above |