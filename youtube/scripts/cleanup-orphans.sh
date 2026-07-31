#!/bin/bash
# ============================================================================
# cleanup-orphans.sh — Limpia archivos incompletos y sidecars huérfanos.
#
# Borra:
#   1. Descargas incompletas: *.part, *.part-Frag*, *.ytdl, *.temp.*
#   2. Sidecars huérfanos POR-VIDEO: *.info.json/.jpg/.webp/.png/.description
#      cuyo nombre es de un episodio ( - S####E#### - ) y ya NO tiene su video.
#
# NO toca:
#   - Videos (.mp4/.mkv/.webm)
#   - Avatares/metadata de canal (SNAENA01, "NA - *", "* [@handle]",
#     "* - Videos *", "* - Shorts *", "* - Live *") — los usa fix-posters.sh
#   - Archivos modificados hace < 30 min (descargas activas del ciclo)
#
# Uso:
#   cleanup-orphans.sh dry [DIR]   # solo reporta, no borra
#   cleanup-orphans.sh run [DIR]   # borra de verdad
#   DIR opcional: una carpeta de canal; por defecto todo MEDIA_DIR.
# ============================================================================
set -uo pipefail

MODE="${1:-dry}"
TARGET="${2:-}"

# Resolver MEDIA_DIR (mount SMB de macOS, tolera sufijo -1)
_nas="$(mount | sed -nE 's|.* on (/Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2[^ ]*) .*|\1|p' | head -1)"
MEDIA_DIR="${MEDIA_DIR:-${_nas:-/Volumes/USB_TOSHIBA_EXTERNAL_USB_a_2}/youtube}"
ROOT="${TARGET:-$MEDIA_DIR}"

REPORT="${MEDIA_REPORT:-/tmp/cleanup-report.tsv}"   # canal<TAB>videos_completos
LOG="${CLEANUP_LOG:-/tmp/cleanup-orphans.log}"
: > "$REPORT"

MIN_AGE_MIN="${MIN_AGE_MIN:-30}"   # no tocar archivos más nuevos que esto (descargas activas); 0 = sin filtro
if [[ "$MIN_AGE_MIN" -gt 0 ]]; then MMIN=(-mmin +$MIN_AGE_MIN); else MMIN=(); fi

del_part=0; del_orphan=0; kept_video=0; skipped_recent=0

_act() {  # $1=path  $2=categoria
    if [[ "$MODE" == "run" ]]; then
        rm -f -- "$1" 2>>"$LOG" && echo "DEL [$2] $1" >> "$LOG"
    else
        echo "WOULD-DEL [$2] $1" >> "$LOG"
    fi
}

echo "== cleanup-orphans ($MODE) root=$ROOT ==" | tee "$LOG"

# --- 1. Incompletos -----------------------------------------------------------
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    _act "$f" "incomplete"; del_part=$((del_part+1))
done < <(find "$ROOT" -type f \( -name '*.part' -o -name '*.part-Frag*' -o -name '*.ytdl' -o -name '*.temp.*' \) "${MMIN[@]}" 2>/dev/null)

# --- 2. Sidecars huérfanos por-video -----------------------------------------
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # base sin extensión sidecar
    case "$f" in
        *.info.json)   base="${f%.info.json}" ;;
        *)             base="${f%.*}" ;;
    esac
    bn="$(basename "$base")"
    # Solo episodios ( - S####E<digits> - ); excluye SNAENA01, "NA -", avatares
    if [[ ! "$bn" =~ \ -\ S[0-9]{4}E[0-9]+\ -\  ]]; then
        continue
    fi
    # ¿tiene video hermano?
    if [[ -e "$base.mp4" || -e "$base.mkv" || -e "$base.webm" ]]; then
        kept_video=$((kept_video+1))
        continue
    fi
    _act "$f" "orphan"; del_orphan=$((del_orphan+1))
done < <(find "$ROOT" -type f \( -name '*.info.json' -o -name '*.jpg' -o -name '*.webp' -o -name '*.png' -o -name '*.description' \) "${MMIN[@]}" 2>/dev/null)

# --- 3. Reporte de videos completos por canal (para comparar contra Plex) -----
if [[ -d "$ROOT" ]]; then
    while IFS= read -r ch; do
        [[ -z "$ch" ]] && continue
        name="$(basename "$ch")"
        n=$(find "$ch" -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.webm' \) ! -name '*.part' 2>/dev/null | wc -l | tr -d ' ')
        printf '%s\t%s\n' "$name" "$n" >> "$REPORT"
    done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

echo "----------------------------------------------"
echo "incompletos:      $del_part"
echo "huérfanos:        $del_orphan"
echo "videos c/sidecar: $kept_video (conservados)"
echo "modo:             $MODE"
echo "log:              $LOG"
echo "reporte canales:  $REPORT"
