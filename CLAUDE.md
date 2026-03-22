# YouTube + Plex Automated System

Automated YouTube channel archival system with Plex Media Server integration and on-demand streaming.

---

## Rules

- **H.264 only:** Always use `vcodec^=avc1` — AV1/VP9 won't play on TVs.
- **SxxEyy naming:** New files must use `S{YYYY}E{MMDD}{index}` format. Never revert to `YYYY-MM-DD` naming.
- **Cookies are sensitive:** Never commit `cookies.txt`, `.env`, or Plex tokens.
- **Plex paths:** Plex container sees `/media/youtube/...`, local is `~/Movies/youtube/...`. URLs inside Docker must use `host.docker.internal`, not `localhost`.
- **Plex library:** Section 6, Plex Series Scanner. Token: `GNEaLTTQ1t932g8LUT7G`.
- **Disk limit:** 90% threshold. Watched videos deleted first, then oldest unwatched.
- **`--max-downloads 1` exits non-zero:** This is expected — not a real error.
- **Video IDs starting with `-`:** Always use `grep -qF --` to avoid flag interpretation.
- **`set -euo pipefail` in bash:** Pipes with `grep -q` or `find|sort|head|cut` can break. Use temp files or process substitution.
- **Plex DB repair:** System `sqlite3` can't read Plex DB. Must use `Plex SQLite` from inside the Docker container.

---

## Git Workflow

- **Branch strategy:** Feature branches → PR to `main` → merge when stable.
- **No direct pushes to `main`.**

---

## Pending / Future

- Batch rename existing `YYYY-MM-DD` videos to SxxEyy format.
- iMessage/iCloud Drive watcher for downloading URLs sent from iPhone.
- OAuth2 for yt-dlp to replace manual cookie refresh.
