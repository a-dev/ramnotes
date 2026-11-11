#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app="$repo_root/build/FileMoveProbe/FileMoveProbe.app"
domain="$repo_root/build/FileMoveProbe/Domain"
generated="$repo_root/build/FileMoveProbe/Sources"
mkdir -p "$app/Contents/MacOS" "$repo_root/build/FileMoveProbe/ModuleCache" "$domain"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ramnotes.FileMoveProbe</string>
<key>CFBundleName</key><string>FileMoveProbe</string>
<key>CFBundleExecutable</key><string>FileMoveProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$repo_root/build/FileMoveProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/FileMoveProbe/ModuleCache" \
xcrun swiftc -D APP_STORE -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$repo_root/build/FileMoveProbe/ModuleCache" \
  -emit-library -static -emit-module -module-name ramnotesDomain \
  -emit-module-path "$domain/ramnotesDomain.swiftmodule" \
  "$repo_root/ramnotes/Domain/NoteValues.swift" \
  -o "$domain/libramnotesDomain.a"
rm -rf "$generated"
mkdir -p "$generated"
find "$repo_root/ramnotes" -name '*.swift' ! -path '*/Domain/*' -print | sort | while IFS= read -r source; do
  relative=${source#"$repo_root/ramnotes/"}
  destination="$generated/$relative"
  if [ "$relative" = "App/main.swift" ]; then destination="$generated/AppCoordinatorProbe.swift"; fi
  mkdir -p "$(dirname "$destination")"
  if [ "$relative" = "App/main.swift" ]; then
    sed '/^let application = NSApplication.shared/,$d' "$source" > "$destination"
  else
    cp "$source" "$destination"
  fi
done
app_sources=$(find "$generated" -name '*.swift' -print | sort)
CLANG_MODULE_CACHE_PATH="$repo_root/build/FileMoveProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/FileMoveProbe/ModuleCache" \
xcrun swiftc -D APP_STORE -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$repo_root/build/FileMoveProbe/ModuleCache" \
  -I "$domain" -L "$domain" -lramnotesDomain \
  $app_sources \
  "$repo_root/Prototypes/FileMoveProbe/main.swift" \
  -o "$app/Contents/MacOS/FileMoveProbe"
codesign --force --sign - --entitlements "$repo_root/Prototypes/StorageAccessProbe/entitlements.plist" "$app"
echo "$app"
