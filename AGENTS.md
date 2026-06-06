# YouTube + Plex Automated System

Automated YouTube channel archival system with Plex Media Server integration and on-demand streaming.

---

## Rules

- **H.264 only:** Always use `vcodec^=avc1` — AV1/VP9 won't play on TVs.
- **SxxEyy naming:** New files must use `S{YYYY}E{MMDD}{index}` format. Never revert to `YYYY-MM-DD` naming.
- **Cookies are sensitive:** Never commit `cookies.txt`, `.env`, or Plex tokens.
- **Plex location:** Plex Media Server corre en server remoto Windows en `192.168.1.124:32400` (ya no en Docker local). Las descargas viven en el NAS (`//jj@192.168.1.130/USB_TOSHIBA_EXTERNAL_USB_a_2`, montado localmente en `/Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2`); el server Plex las ve como `Z:\youtube`.
- **Plex library:** Sección 7 (YouTube), Plex TV Series scanner, agent `tv.plex.agents.series`. Token: `PY1xBcA7QT9r6swusu1x`. Valores vigentes en `commands.sh` (`PLEX_URL`, `PLEX_TOKEN`, `PLEX_SECTION`).
- **Disk limit:** 90% threshold. Watched videos deleted first, then oldest unwatched.
- **`--max-downloads 1` exits non-zero:** This is expected — not a real error.
- **Video IDs starting with `-`:** Always use `grep -qF --` to avoid flag interpretation.
- **`set -euo pipefail` in bash:** Pipes with `grep -q` or `find|sort|head|cut` can break. Use temp files or process substitution.
- **Plex DB repair:** System `sqlite3` no puede leer la DB de Plex. Hay que usar `Plex SQLite` directamente en el server Windows remoto.

---

## Git Workflow

- **Branch strategy:** Feature branches → PR to `main` → merge when stable.
- **No direct pushes to `main`.**

---

## Commands

All recurring commands are centralized in `commands.sh` at the project root. Run `bash commands.sh help` for the full list. Key commands:

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

- Batch rename existing `YYYY-MM-DD` videos to SxxEyy format.
- iMessage/iCloud Drive watcher for downloading URLs sent from iPhone.
- OAuth2 for yt-dlp to replace manual cookie refresh.
