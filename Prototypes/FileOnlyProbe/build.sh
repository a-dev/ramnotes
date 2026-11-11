#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# A new bundle ID gives every acquisition route a fresh sandbox session.
session=${1:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
case "$session" in *[!a-zA-Z0-9-]*|'') echo 'Use an alphanumeric session ID.' >&2; exit 1;; esac
app="$root/build/FileOnlyProbe/$session/FileOnlyProbe.app"
mkdir -p "$app/Contents/MacOS" "$root/build/FileOnlyProbe/ModuleCache"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ramnotes.FileOnlyProbe.$session</string>
<key>CFBundleExecutable</key><string>FileOnlyProbe</string>
<key>CFBundleName</key><string>FileOnlyProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macos27.0 -module-cache-path "$root/build/FileOnlyProbe/ModuleCache" "$root/Prototypes/FileOnlyProbe/main.swift" -o "$app/Contents/MacOS/FileOnlyProbe"
codesign --force --sign - --entitlements "$root/ramnotes/App/RAMnotesMAS.entitlements" "$app"
codesign --verify --strict "$app"
codesign -d --entitlements - "$app"
printf '%s\n' "$app"
