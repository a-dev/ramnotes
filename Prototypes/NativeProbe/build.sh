#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
case "${1:-}" in
  --release) output_dir="$repo_root/build/NativeProbe-Release"; optimization=-O ;;
  "") output_dir="$repo_root/build/NativeProbe"; optimization=-Onone ;;
  *) echo "usage: sh Prototypes/NativeProbe/build.sh [--release]" >&2; exit 2 ;;
esac
app_dir="$output_dir/NativeProbe.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$output_dir/ModuleCache"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.ramnotes.NativeProbe</string>
  <key>CFBundleName</key><string>NativeProbe</string>
  <key>CFBundleExecutable</key><string>NativeProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$output_dir/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$output_dir/ModuleCache" \
xcrun swiftc -swift-version 6 "$optimization" -target arm64-apple-macos27.0 \
  -module-cache-path "$output_dir/ModuleCache" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$repo_root/Prototypes/NativeProbe/main.swift" \
  -o "$app_dir/Contents/MacOS/NativeProbe"
echo "$app_dir"
