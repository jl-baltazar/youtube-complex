#!/bin/bash
# Migrates existing files from:
#   Channel/YYYYMMDD - Title.ext
# To Plex date-based episode format:
#   Channel/Channel - YYYY-MM-DD - Title.ext

set -euo pipefail

MEDIA_DIR="/Users/jlgarcia/Movies/youtube"

renamed=0
skipped=0

for channel_dir in "$MEDIA_DIR"/*/; do
    [ ! -d "$channel_dir" ] && continue
    channel=$(basename "$channel_dir")

    for file in "$channel_dir"*; do
        [ ! -f "$file" ] && continue
        filename=$(basename "$file")

        # Match pattern: YYYYMMDD - Title.ext
        if [[ "$filename" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})\ -\ (.+)$ ]]; then
            year="${BASH_REMATCH[1]}"
            month="${BASH_REMATCH[2]}"
            day="${BASH_REMATCH[3]}"
            rest="${BASH_REMATCH[4]}"

            new_name="${channel} - ${year}-${month}-${day} - ${rest}"

            if [ "$filename" != "$new_name" ]; then
                mv "$file" "$channel_dir$new_name"
                renamed=$(( renamed + 1 ))
            fi
        else
            skipped=$(( skipped + 1 ))
        fi
    done
done

echo "Migration complete: $renamed files renamed, $skipped skipped."
