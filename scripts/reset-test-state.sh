#!/bin/bash
# Remove RAMnotes data from the current macOS account before a manual test pass.
# Without --yes, the script only prints what it would remove.
set -euo pipefail

usage() {
  echo "Usage: bash scripts/reset-test-state.sh [--yes] [--builds]" >&2
  echo "  --yes     Remove the listed paths. Without it, only list them." >&2
  echo "  --builds  Also remove Xcode build products of RAMnotes." >&2
}

apply=false
builds=false
for arg in "$@"; do
  case "$arg" in
    --yes) apply=true ;;
    --builds) builds=true ;;
    *) usage; exit 1 ;;
  esac
done

# Current and old bundle IDs. Add an ID here when it changes.
bundle_ids=(
  com.ramnotes.RAMnotes
  com.ramnotes.RAMnotes.LoginHelper
  com.ramnotes.RAMnotes.uitests.xctrunner
  dev.ramnotes.app
)

paths=()
for id in "${bundle_ids[@]}"; do
  paths+=(
    "$HOME/Library/Containers/$id"
    "$HOME/Library/Application Scripts/$id"
    "$HOME/Library/Saved Application State/$id.savedState"
    "$HOME/Library/Preferences/$id.plist"
    "$HOME/Library/Caches/$id"
    "$HOME/Library/HTTPStorages/$id"
  )
done
paths+=("/Applications/RAMnotes.app" "$HOME/Applications/RAMnotes.app")

if $builds; then
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  paths+=("$repo_root/build/DerivedData")
  for dir in "$HOME"/Library/Developer/Xcode/DerivedData/ramnotes-*; do
    [[ -e "$dir" ]] && paths+=("$dir")
  done
fi

if pgrep -x RAMnotes >/dev/null; then
  if $apply; then
    echo "Quitting RAMnotes."
    osascript -e 'tell application id "com.ramnotes.RAMnotes" to quit' || true
    for _ in {1..10}; do pgrep -x RAMnotes >/dev/null || break; sleep 1; done
    if pgrep -x RAMnotes >/dev/null; then
      echo "RAMnotes is still running. Quit it, then run this script again." >&2
      exit 1
    fi
  else
    echo "RAMnotes is running. With --yes, the script quits it first."
  fi
fi

found=0
failed=()
for path in "${paths[@]}"; do
  [[ -e "$path" ]] || continue
  found=$((found + 1))
  if $apply; then
    echo "Remove: $path"
    rm -rf "$path" 2>/dev/null || failed+=("$path")
  else
    echo "Would remove: $path"
  fi
done

if [[ $found -eq 0 ]]; then
  echo "No RAMnotes data found."
elif ! $apply; then
  echo "Run again with --yes to remove these paths."
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "macOS did not allow removal of these paths:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  echo "macOS protects app containers. Give your terminal app Full Disk Access in" >&2
  echo "System Settings > Privacy & Security, then run this script again." >&2
  echo "Or drag each path to the Trash in Finder and empty the Trash." >&2
fi

cat <<'EOF'

The script does not change system settings. Do these steps yourself:
  1. Reset privacy permissions: tccutil reset All com.ramnotes.RAMnotes
  2. In System Settings > General > Login Items, check that RAMnotes is not listed.
EOF

[[ ${#failed[@]} -eq 0 ]] || exit 1
