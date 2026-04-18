#!/usr/bin/env bash
#
# Generates placeholder app icons for the iOS and macOS asset catalogs.
#
# One-time bootstrap step; re-run only if you want to regenerate the
# placeholder, or replace the output files with real artwork later.
#
# Requires: macOS with Swift (shipped with Xcode) and `sips` (built-in).
#
# Usage:
#   cd apple
#   scripts/generate-placeholder-icons.sh
#   git add Cabalmail/Assets.xcassets/AppIcon.appiconset \
#           CabalmailMac/Assets.xcassets/AppIcon.appiconset
#   git commit

set -euo pipefail

cd "$(dirname "$0")/.."

MASTER=$(mktemp -t cabalmail-icon).png
trap 'rm -f "$MASTER"' EXIT

swift scripts/generate-placeholder-icon.swift "$MASTER"

# ---- iOS / iPadOS / visionOS ------------------------------------------
# Single-size asset. Xcode 14+ derives every runtime size from one 1024x1024
# input when only a universal slot is declared.
IOS_DIR="Cabalmail/Assets.xcassets/AppIcon.appiconset"
rm -f "$IOS_DIR"/*.png
cp "$MASTER" "$IOS_DIR/icon.png"
cat > "$IOS_DIR/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "filename" : "icon.png",
      "idiom" : "vision",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
echo "Wrote $IOS_DIR"

# ---- macOS ------------------------------------------------------------
# macOS wants each size as a discrete file. Scale from the master.
MAC_DIR="CabalmailMac/Assets.xcassets/AppIcon.appiconset"
rm -f "$MAC_DIR"/*.png
for size in 16 32 64 128 256 512 1024; do
    sips -s format png -z "$size" "$size" "$MASTER" \
         --out "$MAC_DIR/icon-${size}.png" > /dev/null
done
cat > "$MAC_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16"   },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16"   },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32"   },
    { "filename" : "icon-64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32"   },
    { "filename" : "icon-128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
echo "Wrote $MAC_DIR"

echo
echo "Done. Review with 'git diff' and commit the changes."
