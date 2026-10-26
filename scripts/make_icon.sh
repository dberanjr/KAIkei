#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon-source.png (needs only the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" Resources

swift scripts/make_icon.swift Resources/AppIcon-source.png "$WORK/master.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/master.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$WORK/master.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
