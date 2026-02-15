#!/usr/bin/env bash
set -euo pipefail

BUCKET="r2:adsb-recordings"
SAMPLES_DIR="$(cd "$(dirname "$0")/.." && pwd)/samples"
mkdir -p "$SAMPLES_DIR"

usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Fetch I/Q samples from R2 and decompress to samples/"
    echo "Format: unsigned 8-bit I/Q interleaved (cu8), 2.4 Msps, zstd-compressed"
    echo ""
    echo "Options:"
    echo "  -l, --list       List available recordings"
    echo "  -n N             Fetch the N most recent recordings (default: 1)"
    echo "  -f FILE          Fetch a specific file by name (e.g. adsb_20260214_130001)"
    echo "  --all            Fetch all recordings (warning: ~20GB+)"
    echo "  --keep-zst       Keep compressed files after decompression"
    echo "  -h, --help       Show this help"
}

cmd_list() {
    echo "Available recordings in $BUCKET:"
    echo ""
    rclone ls "$BUCKET" | awk '{
        size_mb = $1 / 1024 / 1024;
        name = $2;
        gsub(/.*\//, "", name);
        printf "  %-40s %7.0f MB\n", name, size_mb
    }'
}

fetch_and_decompress() {
    local remote_path="$1"
    local basename
    basename="$(echo "$remote_path" | sed 's|.*/||')"
    local out_iq="${basename%.zst}"

    if [ -f "$SAMPLES_DIR/$out_iq" ]; then
        echo "  skip: $out_iq (already exists)"
        return
    fi

    echo "  fetch: $basename"
    rclone copyto "$BUCKET/$remote_path" "$SAMPLES_DIR/$basename" --progress

    echo "  decompress: $basename → $out_iq"
    zstd -d "$SAMPLES_DIR/$basename" -o "$SAMPLES_DIR/$out_iq"

    if [ "${KEEP_ZST:-0}" != "1" ]; then
        rm "$SAMPLES_DIR/$basename"
    fi
}

N=1
MODE="recent"
SPECIFIC_FILE=""
KEEP_ZST=0

while [ $# -gt 0 ]; do
    case "$1" in
        -l|--list) MODE="list"; shift ;;
        -n) N="$2"; MODE="recent"; shift 2 ;;
        -f) SPECIFIC_FILE="$2"; MODE="specific"; shift 2 ;;
        --all) MODE="all"; shift ;;
        --keep-zst) KEEP_ZST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

export KEEP_ZST

if [ "$MODE" = "list" ]; then
    cmd_list
    exit 0
fi

files=$(rclone ls "$BUCKET" | sort -k2 | awk '{print $2}')

if [ "$MODE" = "specific" ]; then
    match=$(echo "$files" | grep "$SPECIFIC_FILE" || true)
    if [ -z "$match" ]; then
        echo "No recording matching '$SPECIFIC_FILE'"
        echo "Run with --list to see available files."
        exit 1
    fi
    files="$match"
elif [ "$MODE" = "recent" ]; then
    files=$(echo "$files" | tail -n "$N")
fi

count=$(echo "$files" | wc -l | tr -d ' ')
echo "Fetching $count recording(s) to $SAMPLES_DIR ..."
echo ""

while IFS= read -r f; do
    fetch_and_decompress "$f"
done <<< "$files"

echo ""
echo "Done."
ls -lh "$SAMPLES_DIR"/*.iq 2>/dev/null || true
