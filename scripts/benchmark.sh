#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SAMPLES_DIR="$PROJECT_DIR/samples"
BIN="$PROJECT_DIR/zig-out/bin/whisper1090"

if [ ! -f "$BIN" ]; then
    echo "Build first: zig build -Doptimize=ReleaseFast"
    exit 1
fi

if [ ! -d "$SAMPLES_DIR" ] || [ -z "$(ls -A "$SAMPLES_DIR" 2>/dev/null | grep -v .gitignore)" ]; then
    echo "No samples found. Run scripts/fetch_samples.sh first."
    exit 1
fi

for sample in "$SAMPLES_DIR"/*.bin; do
    echo "=== $(basename "$sample") ==="
    time "$BIN" --ifile "$sample" --stats 2>&1
    echo ""
done
