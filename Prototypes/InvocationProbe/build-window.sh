#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app="$repo_root/build/WindowProbe/WindowProbe.app"
mkdir -p "$app/Contents/MacOS" "$repo_root/build/WindowProbe/ModuleCache"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.ramnotes.WindowProbe</string>
  <key>CFBundleName</key><string>WindowProbe</string>
  <key>CFBundleExecutable</key><string>WindowProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$repo_root/build/WindowProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/WindowProbe/ModuleCache" \
xcrun swiftc -O -target arm64-apple-macos27.0 "$repo_root/Prototypes/InvocationProbe/WindowProbe.swift" -o "$app/Contents/MacOS/WindowProbe"
codesign --force --sign - "$app"
echo "$app"
