#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app="$repo_root/build/LocationOperationProbe/CP03LocationProbe.app"
domain="$repo_root/build/LocationOperationProbe/Domain"
generated="$repo_root/build/LocationOperationProbe/Sources"
mkdir -p "$app/Contents/MacOS" "$repo_root/build/LocationOperationProbe/ModuleCache" "$domain"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ramnotes.CP03LocationProbe</string>
<key>CFBundleName</key><string>CP03LocationProbe</string>
<key>CFBundleExecutable</key><string>CP03LocationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$repo_root/build/LocationOperationProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/LocationOperationProbe/ModuleCache" \
xcrun swiftc -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$repo_root/build/LocationOperationProbe/ModuleCache" \
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
CLANG_MODULE_CACHE_PATH="$repo_root/build/LocationOperationProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/LocationOperationProbe/ModuleCache" \
xcrun swiftc -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$repo_root/build/LocationOperationProbe/ModuleCache" \
  -I "$domain" -L "$domain" -lramnotesDomain \
  $app_sources \
  "$repo_root/Prototypes/LocationOperationProbe/main.swift" \
  -o "$app/Contents/MacOS/CP03LocationProbe"
codesign --force --sign - --entitlements "$repo_root/Prototypes/StorageAccessProbe/entitlements.plist" "$app"
echo "$app"
