#!/bin/sh
# Builds AppIcon.icns from the procedural source (App/Icon/make-icon.swift).
#   App/Icon/make-icon.sh [output-dir]     (default: build/icon)
# Uses only CoreGraphics and iconutil: nothing here talks to the window server.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/../../build/icon"}
mkdir -p "$out"
rm -rf "$out/AppIcon.iconset"
swiftc -O "$here/make-icon.swift" -o "$out/make-icon"
"$out/make-icon" "$out/AppIcon.iconset"
iconutil -c icns "$out/AppIcon.iconset" -o "$out/AppIcon.icns"
rm -f "$out/make-icon"
echo "$out/AppIcon.icns"
