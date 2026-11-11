#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash scripts/package-dmg.sh APP_PATH [OUTPUT.dmg]" >&2
  exit 1
fi
command -v create-dmg >/dev/null || {
  echo "Install create-dmg first: brew install create-dmg" >&2
  exit 1
}
app_path="$1"
[[ -d "$app_path/Contents/MacOS" ]] || {
  echo "APP_PATH must point to a built macOS app bundle." >&2
  exit 1
}
output_path="${2:-build/RAMnotes.dmg}"
mkdir -p "$(dirname "$output_path")"
output_path="$(cd "$(dirname "$output_path")" && pwd)/$(basename "$output_path")"
[[ ! -e "$output_path" ]] || {
  echo "Output already exists. Remove it or choose another output path: $output_path" >&2
  exit 1
}
script_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ramnotes-dmg.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/source"
ditto "$app_path" "$work_dir/source/RAMnotes.app"
xcrun swift -module-cache-path "$work_dir/module-cache" "$script_dir/dmg/render-background.swift" "$work_dir/background.png"

create-dmg \
  --volname "RAMnotes" \
  --background "$work_dir/background.png" \
  --window-pos 200 120 \
  --window-size 640 360 \
  --icon-size 96 \
  --text-size 14 \
  --icon "RAMnotes.app" 170 170 \
  --hide-extension "RAMnotes.app" \
  --app-drop-link 470 170 \
  --format UDZO \
  "$output_path" "$work_dir/source"

echo "Created $output_path"
