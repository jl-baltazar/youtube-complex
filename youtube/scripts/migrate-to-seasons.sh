#!/bin/bash
# Migrate existing files from Channel/file.mp4 to Channel/Season YYYY/file.mp4
# Extracts year from SxxxxEyyyy pattern in filename, or from file modification date as fallback.
set -euo pipefail

MEDIA_DIR="/Users/jlgarcia/Movies/youtube"
moved=0
skipped=0
errors=0

for channel_dir in "$MEDIA_DIR"/*/; do
    channel_name=$(basename "$channel_dir")

    # Skip playlist folders (they use S01Exxx, not Season subdirs)
    if [[ "$channel_name" == "Soy Tu Fan"* ]]; then
        continue
    fi

    # Skip if directory already only contains Season subdirs
    for file in "$channel_dir"*.mp4 "$channel_dir"*.info.json "$channel_dir"*.jpg "$channel_dir"*.png "$channel_dir"*.webp "$channel_dir"*.placeholder; do
        [ -f "$file" ] || continue

        basename_file=$(basename "$file")

        # Extract year from S{YYYY}E pattern
        if [[ "$basename_file" =~ -\ S([0-9]{4})E ]]; then
            year="${BASH_REMATCH[1]}"
        elif [[ "$basename_file" =~ ^.*([0-9]{4})-[0-9]{2}-[0-9]{2} ]]; then
            # Old YYYY-MM-DD naming
            year="${BASH_REMATCH[1]}"
        else
            # Fallback: use file modification year
            year=$(stat -f '%Sm' -t '%Y' "$file" 2>/dev/null || date +%Y)
        fi

        season_dir="${channel_dir}Season ${year}"
        mkdir -p "$season_dir"

        dest="${season_dir}/${basename_file}"
        if [ -f "$dest" ]; then
            echo "SKIP (exists): $basename_file"
            skipped=$((skipped + 1))
            continue
        fi

        if mv "$file" "$dest" 2>/dev/null; then
            moved=$((moved + 1))
        else
            echo "ERROR: $file"
            errors=$((errors + 1))
        fi
    done
done

echo ""
echo "Migration complete: ${moved} files moved, ${skipped} skipped, ${errors} errors"
