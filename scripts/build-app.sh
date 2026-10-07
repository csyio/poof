#!/bin/bash
# Builds Poof.app: the SwiftUI app with the poof CLI inside (Contents/Helpers/poof), which the
# app runs behind macOS's administrator prompt for files in system folders.
# Usage: scripts/build-app.sh [output-dir]      (default: dist)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
out="${1:-$root/dist}"
version="$(sed -n 's/^public let poofVersion = "\(.*\)"$/\1/p' Sources/PoofCore/Version.swift)"

build=(swift build -c release --arch arm64 --arch x86_64)
"${build[@]}" --product PoofApp
"${build[@]}" --product poof
bin="$("${build[@]}" --show-bin-path)"

app="$out/Poof.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/PoofApp" "$app/Contents/MacOS/Poof"
cp "$bin/poof" "$app/Contents/Helpers/poof"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.csyio.poof</string>
    <key>CFBundleName</key><string>Poof</string>
    <key>CFBundleDisplayName</key><string>Poof</string>
    <key>CFBundleExecutable</key><string>Poof</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# With SIGN_IDENTITY ("Developer ID Application: Name (TEAMID)") the app is signed for
# notarization: hardened runtime and a secure timestamp. Without it, an ad-hoc signature is
# enough to run locally, but a downloaded copy needs "Open Anyway" in System Settings once.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
  sign=(codesign --force --sign -)
fi
"${sign[@]}" "$app/Contents/Helpers/poof"
"${sign[@]}" "$app"
codesign --verify --strict "$app"
echo "$app"
