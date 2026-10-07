#!/bin/bash
# Renders the icon and packs every size macOS needs into Resources/AppIcon.icns.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
swift "$root/scripts/make-icon.swift" "$work"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$root/Resources/AppIcon.icns"
cp "$work/AppIcon.png" "$root/Resources/AppIcon.png"
rm -rf "$work"
echo "$root/Resources/AppIcon.icns"
