# TODO / Pendientes — YouTube + Plex

Lista viva de pendientes para revisar entre sesiones. Marca con `[x]` lo hecho.
Última actualización: 2026-07-31.

---

## 🔴 Alta prioridad

- [ ] **Throttle en `download.sh`** — meter un `sleep` entre canales para no disparar el
      rate-limit de IP de YouTube en el catch-up (334 canales de golpe lo marca). Requiere
      editar `download.sh` + rebuild de la imagen.
- [ ] **Estabilizar el NAS SMB** (192.168.1.130) — reiniciarlo: sirve listados incompletos/
      intermitentes y limita sesiones concurrentes. Es la causa raíz de varios problemas.
- [ ] **Reconectar `Z:` en el server Windows** (Plex) tras reiniciar el NAS, y "Scan Library
      Files" — para que Plex levante los stragglers (ej. EL RePortero E072701, 28-jul).

## 🟡 Media prioridad

- [ ] **Limpieza desde Windows** — `.part` incompletos + sidecars `.info.json`/`.jpg`
      huérfanos NO se pueden borrar desde el Mac (NAS Latin-1: `rm`/`find -delete` fallan en
      nombres acentuados). Correr un script (PowerShell) en el server Windows. Existe
      `youtube/scripts/cleanup-orphans.sh` como referencia de la lógica (sirve para ASCII).
- [ ] **Probar borrado de vistos (Fase 1)** — marcar un par de videos como vistos en Plex y
      confirmar que `enforce_storage_limit` los elimina (y ver si el NAS deja borrar ASCII).
      Nota: la Fase 2 (disco lleno) solo dispara a ≥90%; ahora está en ~71%.
- [ ] **Auto-refresh de cookies (OAuth2)** — reemplazar el refresh manual de `cookies.txt`.
      Ya están en su lugar cookies + PO token; falta automatizar.

## 🟢 Baja prioridad / futuro

- [ ] **Batch rename** de videos viejos `YYYY-MM-DD` → formato `SxxEyy`.
- [ ] **Watcher iMessage/iCloud Drive** para descargar URLs enviadas desde el iPhone.
- [ ] Evaluar si vale la pena hornear `yt-dlp` nightly (hoy stable 2026.7.4; nightly no
      ayudó con el anti-bot, así que quedó stable en la imagen).

## ✅ Hecho (2026-07-31)

- [x] Reactivar descargas: migración a Docker (downloader + stream-proxy + pot-provider).
- [x] NAS montado dentro de Docker vía volumen CIFS (sin depender del mount de macOS).
- [x] Fix anti-bot: deno (challenge nsig) + PO token provider (bgutil) en la imagen.
- [x] Cookies frescas instaladas (las viejas de jun-12 estaban vencidas).
- [x] `commands.sh` migrado a `docker compose`. PR #15 mergeado a `main`.
