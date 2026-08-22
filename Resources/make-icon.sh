#!/bin/sh
# Regenerates Resources/app-icon.icns from make-icon.swift.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/make-icon" make-icon.swift
"$TMP/make-icon" "$TMP/icon-1024.png"
SET="$TMP/app-icon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o app-icon.icns
echo "wrote Resources/app-icon.icns"
