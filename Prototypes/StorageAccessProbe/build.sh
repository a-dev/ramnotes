#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app="$repo_root/build/StorageAccessProbe/CustomPathsAccessProbe.app"
domain="$repo_root/build/StorageAccessProbe/Domain"
mkdir -p "$app/Contents/MacOS" "$repo_root/build/StorageAccessProbe/ModuleCache"
mkdir -p "$domain"
rm -f "$app/Contents/MacOS/StorageAccessProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.ramnotes.CustomPathsAccessProbe</string>
  <key>CFBundleName</key><string>Custom Paths Access Probe</string>
  <key>CFBundleExecutable</key><string>CustomPathsAccessProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$repo_root/build/StorageAccessProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/StorageAccessProbe/ModuleCache" \
xcrun swiftc -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$repo_root/build/StorageAccessProbe/ModuleCache" \
  -emit-library -static -emit-module -module-name ramnotesDomain \
  -emit-module-path "$domain/ramnotesDomain.swiftmodule" \
  "$repo_root/ramnotes/Domain/NoteValues.swift" \
  -o "$domain/libramnotesDomain.a"
CLANG_MODULE_CACHE_PATH="$repo_root/build/StorageAccessProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/StorageAccessProbe/ModuleCache" \
xcrun swiftc -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$repo_root/build/StorageAccessProbe/ModuleCache" \
  -I "$domain" -L "$domain" -lramnotesDomain \
  "$repo_root/ramnotes/Infrastructure/Persistence/NoteRecords.swift" \
  "$repo_root/ramnotes/Application/NoteContracts.swift" \
  "$repo_root/ramnotes/Storage/StorageFiles.swift" \
  "$repo_root/Prototypes/StorageAccessProbe/main.swift" \
  -o "$app/Contents/MacOS/CustomPathsAccessProbe"
codesign --force --sign - --entitlements "$repo_root/Prototypes/StorageAccessProbe/entitlements.plist" "$app"
echo "$app"
