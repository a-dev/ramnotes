#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app="$repo_root/build/LoginProbe/LoginProbe.app"
helper="$app/Contents/Library/LoginItems/LoginProbeHelper.app"
mkdir -p "$app/Contents/MacOS" "$helper/Contents/MacOS" "$repo_root/build/LoginProbe/ModuleCache"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.ramnotes.LoginProbe</string>
  <key>CFBundleName</key><string>LoginProbe</string>
  <key>CFBundleExecutable</key><string>LoginProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>dev.ramnotes.LoginProbe.login</string>
    <key>CFBundleURLSchemes</key><array><string>ramnotes-login-probe</string></array>
  </dict></array>
</dict></plist>
PLIST
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.ramnotes.LoginProbe.Helper</string>
  <key>CFBundleName</key><string>LoginProbeHelper</string>
  <key>CFBundleExecutable</key><string>LoginProbeHelper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
cat > "$repo_root/build/LoginProbe/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$repo_root/build/LoginProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/LoginProbe/ModuleCache" \
xcrun swiftc -O -target arm64-apple-macos27.0 -D LOGIN_HELPER "$repo_root/Prototypes/InvocationProbe/LoginProbe.swift" -o "$helper/Contents/MacOS/LoginProbeHelper"
CLANG_MODULE_CACHE_PATH="$repo_root/build/LoginProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/LoginProbe/ModuleCache" \
xcrun swiftc -O -target arm64-apple-macos27.0 "$repo_root/Prototypes/InvocationProbe/LoginProbe.swift" -o "$app/Contents/MacOS/LoginProbe"
codesign --force --sign - --entitlements "$repo_root/build/LoginProbe/entitlements.plist" "$helper"
codesign --force --sign - --entitlements "$repo_root/build/LoginProbe/entitlements.plist" "$app"
echo "$app"
