#!/usr/bin/env bash
# ============================================================================
# YouTube + Plex — Comandos Recurrentes
# ============================================================================
#
# Ejecución directa:
#
#   bash commands.sh status              # Estado general del sistema
#   bash commands.sh cycle-status        # Detalle del ciclo actual
#   bash commands.sh restart-cycle       # Reiniciar descarga
#   bash commands.sh stop-cycle          # Detener descarga
#   bash commands.sh start-cycle         # Iniciar descarga
#   bash commands.sh restart-proxy       # Reiniciar streaming proxy
#   bash commands.sh stop-proxy          # Detener streaming proxy
#   bash commands.sh start-proxy         # Iniciar streaming proxy
#   bash commands.sh plex-status         # Estado del Plex remoto
#   bash commands.sh plex-sections       # Listar bibliotecas del Plex remoto
#   bash commands.sh plex-scan           # Escanear librería Plex
#   bash commands.sh fix-titles          # Corregir títulos en Plex
#   bash commands.sh fix-posters         # Subir avatares como posters
#   bash commands.sh logs                # Últimas 50 líneas del ciclo
#   bash commands.sh logs-proxy          # Logs del streaming proxy
#   bash commands.sh logs-plex           # Logs del contenedor Plex
#   bash commands.sh logs-follow         # Seguir logs en tiempo real
#   bash commands.sh disk                # Uso de disco
#   bash commands.sh channels            # Número de canales configurados
#   bash commands.sh archive-count       # Videos en el archivo
#   bash commands.sh health              # Health check del proxy
#   bash commands.sh last-download       # Último video descargado
#   bash commands.sh errors              # Errores recientes en logs
#   bash commands.sh playlists               # Listar playlists configuradas
#   bash commands.sh add-playlist <URL> [nombre]  # Agregar playlist
#   bash commands.sh download-playlist <URL> [nombre]  # Descargar playlist
#   bash commands.sh placeholders <URL> [N]  # Generar placeholders
#   bash commands.sh start-all           # Iniciar todos los servicios
#   bash commands.sh stop-all            # Detener todos los servicios
#   bash commands.sh restart-all         # Reiniciar todos los servicios
#   bash commands.sh help                # Mostrar esta ayuda
#
# ============================================================================

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/youtube/scripts"
LOGS_DIR="$BASE_DIR/youtube/state/logs"
CONFIG_DIR="$BASE_DIR/youtube/config"
STATE_DIR="$BASE_DIR/youtube/state"
MEDIA_DIR="/Volumes/TOSHIBA SSD/youtube"
PLEX_URL="http://localhost:32400"
PLEX_TOKEN="PY1xBcA7QT9r6swusu1x"
PLEX_SECTION=3

# Docker: el ciclo de descarga y el proxy corren como contenedores.
# Prender/apagar = docker compose up/down (ver docker-compose.yml).
_compose() { ( cd "$BASE_DIR" && docker compose "$@" ); }

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

_header() { echo -e "\n${BOLD}${BLUE}═══ $1 ═══${NC}"; }
_ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
_warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; }
_err()    { echo -e "  ${RED}✗${NC} $1"; }
_info()   { echo -e "  ${BLUE}→${NC} $1"; }

# ============================================================================
# STATUS — Estado general del sistema
# ============================================================================
yt_status() {
    _header "Estado del Sistema"

    # Servicios Docker
    echo -e "\n${BOLD}Servicios (Docker):${NC}"
    if docker info &>/dev/null; then
        if docker ps --filter "name=yt-downloader" --filter "status=running" --format '{{.Names}}' | grep -q yt-downloader; then
            _ok "yt-downloader — corriendo"
        else
            _err "yt-downloader — detenido (usa: commands.sh start-cycle)"
        fi
        if docker ps --filter "name=yt-stream-proxy" --filter "status=running" --format '{{.Names}}' | grep -q yt-stream-proxy; then
            _ok "yt-stream-proxy — corriendo"
        else
            _err "yt-stream-proxy — detenido (usa: commands.sh start-proxy)"
        fi
    else
        _err "Docker no está corriendo — abre Docker Desktop"
    fi

    if curl -s --connect-timeout 3 "${PLEX_URL}/identity?X-Plex-Token=${PLEX_TOKEN}" -H "Accept: application/json" &>/dev/null; then
        _ok "Plex remoto (192.168.1.78) — respondiendo"
    else
        _err "Plex remoto (192.168.1.78) — no responde"
    fi

    # Disco
    echo -e "\n${BOLD}Disco:${NC}"
    if [[ -d "$MEDIA_DIR" ]]; then
        local disk_usage
        disk_usage=$(df -h "$MEDIA_DIR" | awk 'NR==2{print $5}')
        local disk_avail
        disk_avail=$(df -h "$MEDIA_DIR" | awk 'NR==2{print $4}')
        local pct=${disk_usage//%/}
        if (( pct >= 90 )); then
            _err "Uso: $disk_usage (disponible: $disk_avail) — ¡SOBRE LÍMITE 90%!"
        elif (( pct >= 80 )); then
            _warn "Uso: $disk_usage (disponible: $disk_avail)"
        else
            _ok "Uso: $disk_usage (disponible: $disk_avail)"
        fi
    fi

    # Último ciclo
    echo -e "\n${BOLD}Ciclo de descarga:${NC}"
    if [[ -f "$LOGS_DIR/download.log" ]]; then
        local last_cycle
        last_cycle=$(grep -E "^(===|---|\[CYCLE\]|Sleeping|Starting download)" "$LOGS_DIR/download.log" | tail -1 2>/dev/null || echo "sin datos")
        _info "Última actividad: $last_cycle"
    fi

    # Contadores
    echo -e "\n${BOLD}Estadísticas:${NC}"
    local channel_count=0 archive_count=0 video_count=0
    [[ -f "$CONFIG_DIR/channels.txt" ]] && channel_count=$(grep -cv '^\s*#\|^\s*$' "$CONFIG_DIR/channels.txt" 2>/dev/null || echo 0)
    [[ -f "$STATE_DIR/archive.txt" ]] && archive_count=$(wc -l < "$STATE_DIR/archive.txt" | tr -d ' ')
    [[ -d "$MEDIA_DIR" ]] && video_count=$(find "$MEDIA_DIR" -name "*.mp4" -type f 2>/dev/null | wc -l | tr -d ' ')
    _info "Canales: $channel_count"
    _info "Videos en archivo: $archive_count"
    _info "Archivos MP4: $video_count"

    # Health del proxy
    echo -e "\n${BOLD}Streaming proxy:${NC}"
    local health
    if health=$(curl -s --connect-timeout 2 http://localhost:9090/health 2>/dev/null); then
        _ok "Health: $health"
    else
        _err "No responde en puerto 9090"
    fi
    echo ""
}

# ============================================================================
# CYCLE-STATUS — Estado detallado del ciclo actual
# ============================================================================
yt_cycle_status() {
    _header "Estado del Ciclo de Descarga"

    if [[ ! -f "$LOGS_DIR/download.log" ]]; then
        _err "No se encontró download.log"
        return 1
    fi

    # Último inicio de ciclo
    echo -e "\n${BOLD}Último ciclo:${NC}"
    grep -nE "(Starting download cycle|Cycle complete|Sleeping|channels processed)" "$LOGS_DIR/download.log" | tail -5 || _info "Sin marcas de ciclo encontradas"

    # Canal actual (si está descargando)
    echo -e "\n${BOLD}Actividad reciente:${NC}"
    tail -20 "$LOGS_DIR/download.log"

    # Errores recientes
    echo -e "\n${BOLD}Errores recientes (últimos 10):${NC}"
    grep -iE "(error|fail|warning)" "$LOGS_DIR/download.log" | grep -v "max-downloads" | tail -10 || _ok "Sin errores recientes"
    echo ""
}

# ============================================================================
# SERVICIOS — Iniciar / Detener / Reiniciar
# ============================================================================
yt_restart_cycle() {
    _header "Reiniciando ciclo de descarga (contenedor)"
    _compose restart downloader
    sleep 2
    if docker ps --filter "name=yt-downloader" --filter "status=running" --format '{{.Names}}' | grep -q yt-downloader; then
        _ok "Ciclo reiniciado"
    else
        _err "No se pudo reiniciar el ciclo"
    fi
}

yt_stop_cycle() {
    _header "Deteniendo ciclo de descarga (contenedor)"
    _compose stop downloader
    _ok "Ciclo detenido"
}

yt_start_cycle() {
    _header "Iniciando ciclo de descarga (contenedor)"
    _compose up -d downloader
    sleep 2
    if docker ps --filter "name=yt-downloader" --filter "status=running" --format '{{.Names}}' | grep -q yt-downloader; then
        _ok "Ciclo iniciado"
    else
        _err "No se pudo iniciar el ciclo"
    fi
}

yt_restart_proxy() {
    _header "Reiniciando streaming proxy (contenedor)"
    _compose restart stream-proxy
    sleep 2
    if curl -s --connect-timeout 2 http://localhost:9090/health &>/dev/null; then
        _ok "Proxy reiniciado y respondiendo"
    else
        _warn "Proxy reiniciado pero aún no responde"
    fi
}

yt_stop_proxy() {
    _header "Deteniendo streaming proxy (contenedor)"
    _compose stop stream-proxy
    _ok "Proxy detenido"
}

yt_start_proxy() {
    _header "Iniciando streaming proxy (contenedor)"
    _compose up -d stream-proxy
    sleep 2
    if curl -s --connect-timeout 2 http://localhost:9090/health &>/dev/null; then
        _ok "Proxy iniciado y respondiendo"
    else
        _warn "Proxy cargado pero aún no responde"
    fi
}

# ============================================================================
# PLEX — Contenedor Docker
# ============================================================================
yt_plex_status() {
    _header "Estado del Plex remoto"
    local resp
    if resp=$(curl -s --connect-timeout 5 "${PLEX_URL}/identity?X-Plex-Token=${PLEX_TOKEN}" -H "Accept: application/json" 2>/dev/null); then
        local name version
        name=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin).get('MediaContainer',{}); print(d.get('friendlyName','?'))" 2>/dev/null)
        version=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin).get('MediaContainer',{}); print(d.get('version','?'))" 2>/dev/null)
        _ok "Server: $name (v$version)"
    else
        _err "No se puede conectar a ${PLEX_URL}"
    fi
}

yt_plex_sections() {
    _header "Bibliotecas del Plex remoto"
    curl -s --connect-timeout 5 "${PLEX_URL}/library/sections?X-Plex-Token=${PLEX_TOKEN}" -H "Accept: application/json" 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data.get('MediaContainer', {}).get('Directory', []):
    locs = ', '.join(loc['path'] for loc in d.get('Location', []))
    print(f\"  Section {d['key']}: {d['title']} ({d['type']}) — {locs}\")
" 2>/dev/null || _err "No se pudo conectar"
}

yt_plex_scan() {
    _header "Escaneando librería Plex remoto (sección $PLEX_SECTION)"
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 \
        -X POST "${PLEX_URL}/library/sections/${PLEX_SECTION}/refresh?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null)
    if [[ "$http_code" == "200" ]]; then
        _ok "Escaneo disparado"
    else
        _err "Falló el escaneo (HTTP $http_code)"
    fi
}

# ============================================================================
# METADATA — Títulos y Posters
# ============================================================================
yt_fix_titles() {
    _header "Corrigiendo títulos en Plex"
    bash "$SCRIPTS_DIR/fix-titles.sh"
    _ok "Títulos actualizados"
}

yt_fix_posters() {
    _header "Subiendo posters de canales"
    bash "$SCRIPTS_DIR/fix-posters.sh"
    _ok "Posters actualizados"
}

# ============================================================================
# LOGS
# ============================================================================
yt_logs() {
    _header "Logs del ciclo de descarga (últimas 50 líneas)"
    tail -50 "$LOGS_DIR/download.log" 2>/dev/null || _err "No se encontró download.log"
}

yt_logs_proxy() {
    _header "Logs del streaming proxy (últimas 50 líneas)"
    tail -50 "$LOGS_DIR/webhook-stdout.log" 2>/dev/null || _err "No se encontró webhook-stdout.log"
    echo -e "\n${BOLD}Errores:${NC}"
    tail -20 "$LOGS_DIR/webhook-stderr.log" 2>/dev/null || _info "Sin errores"
}

yt_logs_plex() {
    _header "Logs de Plex remoto"
    _warn "Plex corre en un server remoto (192.168.1.78) — logs no accesibles desde aquí"
    _info "Usa la web UI: ${PLEX_URL}/web o accede al server directamente"
}

yt_logs_follow() {
    _header "Siguiendo logs del ciclo en tiempo real (Ctrl+C para salir)"
    tail -f "$LOGS_DIR/download.log" 2>/dev/null || tail -f "$LOGS_DIR/launchd-stdout.log" 2>/dev/null || _err "No se encontraron logs"
}

# ============================================================================
# INFO — Estadísticas y diagnóstico
# ============================================================================
yt_disk() {
    _header "Uso de disco"
    df -h "$MEDIA_DIR" 2>/dev/null || df -h /Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2
    echo ""
    du -sh "$MEDIA_DIR" 2>/dev/null || true
    echo ""
    _info "Límite configurado: 90%"
}

yt_channels() {
    _header "Canales configurados"
    local count
    count=$(grep -cv '^\s*#\|^\s*$' "$CONFIG_DIR/channels.txt" 2>/dev/null || echo 0)
    _info "Total: $count canales"
}

yt_archive_count() {
    _header "Videos en archivo"
    local count
    count=$(wc -l < "$STATE_DIR/archive.txt" 2>/dev/null | tr -d ' ' || echo 0)
    _info "Total: $count videos descargados"
}

yt_health() {
    _header "Health check del streaming proxy"
    curl -s http://localhost:9090/health 2>/dev/null | python3 -m json.tool 2>/dev/null || _err "Proxy no responde"
    echo ""
}

yt_last_download() {
    _header "Último video descargado"
    if [[ -d "$MEDIA_DIR" ]]; then
        local latest
        latest=$(find "$MEDIA_DIR" -name "*.mp4" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -n "$latest" ]]; then
            _info "Archivo: $(basename "$latest")"
            _info "Carpeta: $(dirname "$latest" | xargs basename)"
            _info "Fecha: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$latest")"
        else
            _warn "No se encontraron videos MP4"
        fi
    fi
}

yt_errors() {
    _header "Errores recientes"
    echo -e "\n${BOLD}download.log:${NC}"
    grep -iE "(error|fail|LOGIN_REQUIRED|HTTP Error|unable)" "$LOGS_DIR/download.log" 2>/dev/null | grep -v "max-downloads" | tail -15 || _ok "Sin errores"
    echo -e "\n${BOLD}webhook-stderr.log:${NC}"
    tail -10 "$LOGS_DIR/webhook-stderr.log" 2>/dev/null || _ok "Sin errores"
    echo ""
}

yt_playlists() {
    _header "Playlists configuradas"
    local playlists_file="$CONFIG_DIR/playlists.txt"
    if [[ ! -s "$playlists_file" ]]; then
        _warn "No hay playlists configuradas en $playlists_file"
        return 0
    fi
    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        count=$((count + 1))
        local url name
        if [[ "$line" == *"|"* ]]; then
            url=$(echo "$line" | cut -d'|' -f1 | xargs)
            name=$(echo "$line" | cut -d'|' -f2- | xargs)
            _info "$count. ${name} — ${url}"
        else
            url=$(echo "$line" | xargs)
            _info "$count. ${url}"
        fi
    done < "$playlists_file"
    echo ""
    _info "Total: $count playlist(s)"
    _info "Videos en: /Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2/youtube/ (protegidos del cleanup)"
}

yt_add_playlist() {
    local url="${1:-}"
    local name="${2:-}"
    if [[ -z "$url" ]]; then
        echo "Uso: commands.sh add-playlist <URL> [nombre]"
        echo "Ejemplo: commands.sh add-playlist 'https://www.youtube.com/playlist?list=PLxxxxx' 'Curso de Python'"
        return 1
    fi
    local playlists_file="$CONFIG_DIR/playlists.txt"
    # Check for duplicate URL
    if grep -qF "$url" "$playlists_file" 2>/dev/null; then
        _warn "Esa playlist ya está configurada"
        return 1
    fi
    if [[ -n "$name" ]]; then
        echo "${url} | ${name}" >> "$playlists_file"
        _ok "Playlist agregada: ${name} (${url})"
    else
        echo "$url" >> "$playlists_file"
        _ok "Playlist agregada: ${url}"
    fi
}

yt_download_playlist() {
    local url="${1:-}"
    local name="${2:-}"
    if [[ -z "$url" ]]; then
        echo "Uso: commands.sh download-playlist <URL> [nombre]"
        echo "Ejemplo: commands.sh download-playlist 'https://www.youtube.com/playlist?list=PLxxxxx' 'Curso de Python'"
        return 1
    fi
    _header "Descargando playlist: ${name:-$url}"
    bash "$SCRIPTS_DIR/download-playlists.sh" "$url" "$name"
}

yt_placeholders() {
    local url="${1:-}"
    local count="${2:-10}"
    if [[ -z "$url" ]]; then
        echo "Uso: commands.sh placeholders <URL_canal> [cantidad]"
        echo "Ejemplo: commands.sh placeholders 'https://www.youtube.com/@Canal' 20"
        return 1
    fi
    _header "Generando placeholders para: $url (últimos $count)"
    bash "$SCRIPTS_DIR/generate-placeholders.sh" "$url" "$count"
}

# ============================================================================
# STOP-ALL / START-ALL
# ============================================================================
yt_stop_all() {
    _header "Deteniendo todos los servicios (docker compose down)"
    _compose down
    _ok "Contenedores detenidos (Plex corre en server remoto)"
}

yt_start_all() {
    _header "Iniciando todos los servicios (docker compose up -d)"
    _compose up -d
    sleep 3
    _ok "Contenedores iniciados (Plex corre en server remoto)"
    yt_status
}

yt_restart_all() {
    _header "Reiniciando todos los servicios"
    yt_stop_all
    sleep 2
    yt_start_all
}

# ============================================================================
# CLI — Dispatcher
# ============================================================================
_usage() {
    echo -e "${BOLD}YouTube + Plex — Comandos${NC}"
    echo ""
    echo "Uso: bash commands.sh <comando> [args]"
    echo ""
    echo -e "${BOLD}Estado:${NC}"
    echo "  status          Estado general del sistema"
    echo "  cycle-status    Estado detallado del ciclo de descarga"
    echo "  health          Health check del streaming proxy"
    echo "  disk            Uso de disco"
    echo "  channels        Número de canales configurados"
    echo "  archive-count   Videos en el archivo"
    echo "  last-download   Último video descargado"
    echo "  errors          Errores recientes en logs"
    echo ""
    echo -e "${BOLD}Ciclo de descarga:${NC}"
    echo "  start-cycle     Iniciar ciclo"
    echo "  stop-cycle      Detener ciclo"
    echo "  restart-cycle   Reiniciar ciclo"
    echo ""
    echo -e "${BOLD}Streaming proxy:${NC}"
    echo "  start-proxy     Iniciar proxy"
    echo "  stop-proxy      Detener proxy"
    echo "  restart-proxy   Reiniciar proxy"
    echo ""
    echo -e "${BOLD}Plex:${NC}"
    echo "  plex-status     Estado del Plex remoto"
    echo "  plex-sections   Listar bibliotecas del Plex remoto"
    echo "  plex-scan       Escanear librería"
    echo "  fix-titles      Corregir títulos de episodios"
    echo "  fix-posters     Subir avatares como posters"
    echo ""
    echo -e "${BOLD}Logs:${NC}"
    echo "  logs            Últimas 50 líneas del ciclo"
    echo "  logs-proxy      Logs del streaming proxy"
    echo "  logs-plex       Logs de Plex"
    echo "  logs-follow     Seguir logs en tiempo real"
    echo ""
    echo -e "${BOLD}Servicios (todos):${NC}"
    echo "  start-all       Iniciar todos los servicios"
    echo "  stop-all        Detener todos los servicios"
    echo "  restart-all     Reiniciar todos los servicios"
    echo ""
    echo -e "${BOLD}Playlists:${NC}"
    echo "  playlists           Listar playlists configuradas"
    echo "  add-playlist        Agregar playlist (args: URL [nombre])"
    echo "  download-playlist   Descargar playlist manualmente (args: URL [nombre])"
    echo ""
    echo -e "${BOLD}Utilidades:${NC}"
    echo "  placeholders    Generar placeholders (args: URL [cantidad])"
}

# Si se ejecuta directamente (no sourceado)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        status)         yt_status ;;
        cycle-status)   yt_cycle_status ;;
        restart-cycle)  yt_restart_cycle ;;
        stop-cycle)     yt_stop_cycle ;;
        start-cycle)    yt_start_cycle ;;
        restart-proxy)  yt_restart_proxy ;;
        stop-proxy)     yt_stop_proxy ;;
        start-proxy)    yt_start_proxy ;;
        plex-status)    yt_plex_status ;;
        plex-sections)  yt_plex_sections ;;
        plex-scan)      yt_plex_scan ;;
        fix-titles)     yt_fix_titles ;;
        fix-posters)    yt_fix_posters ;;
        logs)           yt_logs ;;
        logs-proxy)     yt_logs_proxy ;;
        logs-plex)      yt_logs_plex ;;
        logs-follow)    yt_logs_follow ;;
        disk)           yt_disk ;;
        channels)       yt_channels ;;
        archive-count)  yt_archive_count ;;
        health)         yt_health ;;
        last-download)  yt_last_download ;;
        errors)         yt_errors ;;
        playlists)          yt_playlists ;;
        add-playlist)       yt_add_playlist "$@" ;;
        download-playlist)  yt_download_playlist "$@" ;;
        placeholders)       yt_placeholders "$@" ;;
        stop-all)       yt_stop_all ;;
        start-all)      yt_start_all ;;
        restart-all)    yt_restart_all ;;
        help|--help|-h) _usage ;;
        *)              _usage ;;
    esac
fi
