#!/bin/bash
set -euo pipefail

# Pipeline hermano del de videos normales, pero SOLO para shorts.
# Fuentes:
#   1. Canales elegidos          -> tab /@canal/shorts   (con cookies)   tag [CH]
#   2. Mis Likes / Watch Later   -> playlists LL / WL     (con cookies)   tag [LIKE]/[WL]
#   3. Mi History                -> feed/history          (con cookies)   tag [HIST]
#   4. Random (romper algoritmo) -> ytsearch ANONIMO      (sin cookies)   tag [RND]
#
# Todo cae en el show unico "Shorts" (mismo Plex library, section 3).
# El origen se ve en el titulo del episodio via prefijo [TAG].

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"
ARCHIVE_FILE="${STATE_DIR}/archive.txt"
LOG_DIR="${STATE_DIR}/logs"
MEDIA_DIR="${MEDIA_DIR:-/media/youtube}"

SHORTS_CONF="${CONFIG_DIR}/yt-dlp-shorts.conf"
CHANNELS_FILE="${CONFIG_DIR}/shorts-channels.txt"
RANDOM_POOL_FILE="${CONFIG_DIR}/shorts-random-pool.txt"
# IDs del feed "For You" organico, generado en el HOST por capture-shorts-feed.mjs
# (Playwright). El download solo los consume; la captura corre fuera de Docker.
FEED_IDS_FILE="${CONFIG_DIR}/shorts-feed-ids.txt"
ENABLE_FEED="${ENABLE_FEED:-1}"

SHORTS_SHOW="Shorts"

# ---- Tunables (overridables por entorno) ----
CHANNEL_SHORTS_LIMIT="${CHANNEL_SHORTS_LIMIT:-5}"   # N shorts mas recientes por canal
FEED_SHORTS_LIMIT="${FEED_SHORTS_LIMIT:-50}"        # cuantos items recientes de LL/WL/history revisar
ENABLE_LIKES="${ENABLE_LIKES:-1}"
# Watch Later lo bloquea YouTube para acceso programatico (yt-dlp: "The playlist does
# not exist" aun logueado). Apagado por defecto; ponlo en 1 si algun dia lo habilitan.
ENABLE_WATCHLATER="${ENABLE_WATCHLATER:-0}"
ENABLE_HISTORY="${ENABLE_HISTORY:-1}"
# 10 terminos x 2 = ~20 verticales/ciclo, con mas diversidad de temas.
RANDOM_TERMS_PER_CYCLE="${RANDOM_TERMS_PER_CYCLE:-10}"
RANDOM_PER_TERM="${RANDOM_PER_TERM:-2}"
# Headroom: pide muchos mas candidatos por termino porque el filtro vertical
# (aspect_ratio<1) descarta ~75% de los resultados de busqueda (horizontales).
RANDOM_SEARCH_MULTIPLIER="${RANDOM_SEARCH_MULTIPLIER:-8}"
RANDOM_COUNTRIES=(US MX GB JP BR DE FR IN KR ES CA AU)

mkdir -p "${LOG_DIR}" "${MEDIA_DIR}/${SHORTS_SHOW}"
touch "${ARCHIVE_FILE}"

# Copia desechable de cookies (yt-dlp reescribe el archivo al terminar; no tocar el maestro).
MASTER_COOKIES="${CONFIG_DIR}/cookies.txt"
COOKIE_WORK="${STATE_DIR}/.cookies-shorts.txt"
have_cookies() { [[ -s "${MASTER_COOKIES}" ]] && grep -qE '^\.' "${MASTER_COOKIES}"; }
refresh_cookies() { have_cookies && cp -f "${MASTER_COOKIES}" "${COOKIE_WORK}" 2>/dev/null || true; }
COOKIE_OPTION=()
if have_cookies; then
    refresh_cookies
    COOKIE_OPTION=(--cookies "${COOKIE_WORK}")
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [shorts] $*" | tee -a "${LOG_DIR}/download.log"
}

# Plantilla de salida con el TAG de origen embebido en el titulo del episodio.
# Episodio = timestamp de subida (unico por video y ordenable cronologicamente).
out_template() {
    local tag="$1"
    printf '%s/%s/Season %%(upload_date>%%Y)s/%s - S%%(upload_date>%%Y)sE%%(timestamp,epoch)s - [%s] %%(uploader)s - %%(title).80s [%%(id)s].%%(ext)s' \
        "${MEDIA_DIR}" "${SHORTS_SHOW}" "${SHORTS_SHOW}" "${tag}"
}

# run_source TAG USE_COOKIES EXTRA_ARGS... URL
# USE_COOKIES=1 agrega --cookies; =0 corre anonimo.
run_source() {
    local tag="$1"; shift
    local use_cookies="$1"; shift

    local cookies=()
    if [[ "$use_cookies" == "1" ]]; then
        refresh_cookies
        cookies=("${COOKIE_OPTION[@]}")
    fi

    local tmp; tmp=$(mktemp)
    set +e
    yt-dlp --config-location "${SHORTS_CONF}" \
        --download-archive "${ARCHIVE_FILE}" \
        -o "$(out_template "$tag")" \
        "${cookies[@]}" "$@" 2>&1 | tee -a "${LOG_DIR}/yt-dlp.log" > "$tmp"
    local rc="${PIPESTATUS[0]}"
    set -e

    # rc 101 = --max-downloads alcanzado (exito). rc 1 sin ERROR real = "no nuevos".
    if [[ "$rc" -eq 0 || "$rc" -eq 101 ]]; then
        : # ok
    elif [[ "$rc" -eq 1 ]] && ! grep -qE '^ERROR:' "$tmp"; then
        : # no nuevos
    elif grep -qiE 'has already been recorded in the archive' "$tmp"; then
        : # ya archivado
    else
        log "WARNING: [$tag] yt-dlp exit $rc"
    fi
    rm -f "$tmp"
    return 0
}

# ---- 1. Canales elegidos ----
process_channels() {
    [[ -s "$CHANNELS_FILE" ]] || { log "Sin canales de shorts configurados."; return 0; }
    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        local url; url=$(echo "$line" | xargs)
        # Asegura el tab /shorts
        [[ "$url" == */shorts ]] || url="${url%/}/shorts"
        log "Canal: $url"
        run_source "CH" 1 --playlist-end "${CHANNEL_SHORTS_LIMIT}" "$url"
        count=$((count + 1))
    done < "$CHANNELS_FILE"
    log "Canales de shorts procesados: $count"
}

# ---- 2 y 3. Likes / Watch Later / History ----
process_feeds() {
    [[ ${#COOKIE_OPTION[@]} -gt 0 ]] || { log "Sin cookies: me salto Likes/WL/History."; return 0; }
    if [[ "$ENABLE_LIKES" == "1" ]]; then
        log "Likes (LL) -> shorts"
        run_source "LIKE" 1 --playlist-end "${FEED_SHORTS_LIMIT}" "https://www.youtube.com/playlist?list=LL"
    fi
    if [[ "$ENABLE_WATCHLATER" == "1" ]]; then
        log "Watch Later (WL) -> shorts"
        run_source "WL" 1 --playlist-end "${FEED_SHORTS_LIMIT}" "https://www.youtube.com/playlist?list=WL"
    fi
    if [[ "$ENABLE_HISTORY" == "1" ]]; then
        log "History -> shorts"
        run_source "HIST" 1 --playlist-end "${FEED_SHORTS_LIMIT}" "https://www.youtube.com/feed/history"
    fi
}

# ---- 4. Random anonimo (romper el algoritmo) ----
process_random() {
    [[ -s "$RANDOM_POOL_FILE" ]] || { log "Sin pool random configurado."; return 0; }

    mapfile -t terms < <(grep -vE '^\s*#|^\s*$' "$RANDOM_POOL_FILE" | sort -R | head -n "${RANDOM_TERMS_PER_CYCLE}")
    [[ ${#terms[@]} -gt 0 ]] || { log "Pool random vacio."; return 0; }

    # ytsearchN con holgura amplia para compensar horizontales + duracion descartados.
    local search_n=$(( RANDOM_PER_TERM * RANDOM_SEARCH_MULTIPLIER ))
    local got=0
    for term in "${terms[@]}"; do
        local country="${RANDOM_COUNTRIES[$RANDOM % ${#RANDOM_COUNTRIES[@]}]}"
        log "Random[$country]: \"${term}\" (hasta ${RANDOM_PER_TERM})"
        # Anonimo (sin cookies) + geo-bypass para sacarte de tu region/burbuja.
        run_source "RND" 0 \
            --geo-bypass-country "$country" \
            --max-downloads "${RANDOM_PER_TERM}" \
            "ytsearch${search_n}:${term} #shorts"
        got=$((got + RANDOM_PER_TERM))
    done
    log "Random: ~${got} shorts objetivo este ciclo."
}

# ---- Feed "For You" organico (IDs capturados en el host) ----
process_feed_ids() {
    [[ "$ENABLE_FEED" == "1" ]] || return 0
    [[ -s "$FEED_IDS_FILE" ]] || { log "Sin IDs de feed organico (corre capture-shorts-feed.mjs en el host)."; return 0; }
    [[ ${#COOKIE_OPTION[@]} -gt 0 ]] || { log "Sin cookies: me salto el feed organico."; return 0; }
    local n; n=$(grep -cE '^https?://' "$FEED_IDS_FILE" 2>/dev/null || echo 0)
    log "Feed organico (For You) -> ${n} IDs"
    run_source "FEED" 1 -a "$FEED_IDS_FILE"
}

log "=== Inicio ciclo de shorts ==="
process_feed_ids
process_channels
process_feeds
process_random
log "=== Fin ciclo de shorts ==="
