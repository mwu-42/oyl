#!/bin/bash
# Draws Oyl's app icon (Icon.swift, with the app's own Oyl, moyl and notch) into Icon/Oyl.icns,
# which build.sh puts in the app. Only needed when the icon changes.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.2" \
    $(ls Sources/*.swift | grep -v '/App.swift$') Icon/Icon.swift -o "$work/icon"
"$work/icon" "$work/Oyl.iconset"
iconutil -c icns "$work/Oyl.iconset" -o Icon/Oyl.icns
cp "$work/Oyl.iconset/icon_512x512@2x.png" Icon/Oyl.png
echo "Wrote Icon/Oyl.icns"
