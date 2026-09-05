# YouTube + Plex Automated System

Automated YouTube channel archival system with Plex Media Server integration and on-demand streaming.

---

## Rules

- **H.264 only:** Always use `vcodec^=avc1` — AV1/VP9 won't play on TVs.
- **SxxEyy naming:** New files must use `S{YYYY}E{MMDD}{index}` format. Never revert to `YYYY-MM-DD` naming.
- **Cookies are sensitive:** Never commit `cookies.txt`, `.env`, or Plex tokens.
- **Plex location (2026-09-05):** Plex Media Server corre **NATIVO en macOS** (`Plex Media Server.app`), no en Docker ni en Windows. El container lo alcanza vía `PLEX_URL=http://host.docker.internal:32400`. Las descargas viven en el **TOSHIBA SSD por USB directo** al Mac; el container escribe en `/media/youtube` (bind rw a `/Volumes/TOSHIBA SSD/youtube`) y **Plex nativo las ve en `/Volumes/TOSHIBA SSD/youtube`** (por eso `PLEX_MEDIA_PREFIX=/Volumes/TOSHIBA SSD/youtube` con separador `/`, ya NO `Z:\youtube` con backslash). Ya no hay NAS/CIFS.
- **Plex library:** Sección **3** (YouTube), Plex TV Series scanner, agent `tv.plex.agents.series`. Token: `PY1xBcA7QT9r6swusu1x`. Valores vigentes en `.env`/`commands.sh` (`PLEX_URL`, `PLEX_TOKEN`, `PLEX_SECTION`, `PLEX_MEDIA_PREFIX`).
- **Disk limit:** 90% threshold. Watched videos deleted first, then oldest unwatched.
- **`--max-downloads 1` exits non-zero:** This is expected — not a real error.
- **Video IDs starting with `-`:** Always use `grep -qF --` to avoid flag interpretation.
- **`set -euo pipefail` in bash:** Pipes with `grep -q` or `find|sort|head|cut` can break. Use temp files or process substitution.
- **Plex DB repair:** System `sqlite3` no puede leer la DB de Plex. Hay que usar `Plex SQLite` directamente en el server Windows remoto.
- **Deployment = Docker (desde 2026-07-31):** El stack corre en Docker Compose, ya NO en launchd. Servicios: `downloader` (yt-downloader), `stream-proxy` (yt-stream-proxy, :9090) y `pot-provider` (yt-pot-provider, PO token). El NAS se monta DENTRO de Docker vía volumen CIFS (no depende del mount de macOS). Prender/apagar = `docker compose up -d` / `down`. Los LaunchAgents `com.jlgarcia.youtube-dl` y `com.jlgarcia.youtube-webhook` están deshabilitados.
- **yt-dlp anti-bot:** YouTube exige (1) runtime de JS → `deno` horneado en la imagen (challenge nsig) y (2) **PO Token** → contenedor `pot-provider` (bgutil) + plugin `bgutil-ytdlp-pot-provider` + `--extractor-args youtubepot-bgutilhttp:base_url=http://pot-provider:4416` en `yt-dlp.conf`. Sin esto → "Sign in to confirm you're not a bot". Además, demasiados requests desde la misma IP en poco tiempo la marcan (rate-limit temporal); no re-escanear los 334 canales de golpe.
- **NAS sirve nombres en Latin-1 (no UTF-8):** desde el Mac/CIFS los archivos con acentos NO se pueden borrar (`rm` y `find -delete` fallan con "No such file or directory"/"Operation not permitted"). La limpieza de `.part`/huérfanos y el borrado de vistos acentuados debe hacerse **desde el server Windows**. El NAS también limita sesiones SMB concurrentes (usar `docker exec yt-downloader`, no spawnear contenedores).

---

## Git Workflow

- **Branch strategy:** Feature branches → PR to `main` → merge when stable.
- **No direct pushes to `main`.**

---

## Commands

All recurring commands are centralized in `commands.sh` at the project root (ahora envuelven `docker compose`). Run `bash commands.sh help` for the full list. También puedes usar Docker directo: `docker compose up -d` / `docker compose down` desde la raíz. Key commands:

```bash
bash commands.sh status          # Estado general (servicios, disco, ciclo)
bash commands.sh cycle-status    # Detalle del ciclo de descarga actual
bash commands.sh restart-cycle   # Reiniciar ciclo de descarga
bash commands.sh stop-cycle      # Detener ciclo
bash commands.sh start-cycle     # Iniciar ciclo
bash commands.sh restart-proxy   # Reiniciar streaming proxy
bash commands.sh plex-scan       # Escanear librería Plex
bash commands.sh logs            # Últimas 50 líneas del ciclo
bash commands.sh logs-follow     # Seguir logs en tiempo real
bash commands.sh errors          # Errores recientes
bash commands.sh start-all       # Iniciar todos los servicios
bash commands.sh stop-all        # Detener todos los servicios
bash commands.sh restart-all     # Reiniciar todos los servicios
```

---

## Pending / Future

> 📋 Lista viva de pendientes en [`TODO.md`](TODO.md) — revisar al inicio de cada sesión.


- Batch rename existing `YYYY-MM-DD` videos to SxxEyy format.
- iMessage/iCloud Drive watcher for downloading URLs sent from iPhone.
- OAuth2 for yt-dlp to replace manual cookie refresh (cookies + PO token ya en su lugar; falta automatizar el refresh de cookies).
- Throttle (sleep entre canales) en `download.sh` para no disparar el rate-limit de IP en el catch-up.
- Limpieza de `.part`/huérfanos y borrado de vistos con nombres acentuados: correr desde Windows (el NAS Latin-1 no deja borrarlos desde el Mac).
