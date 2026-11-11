#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$ROOT_DIR/build/DerivedData/Build/Products/Debug/ramnotes.app"

if /usr/bin/pgrep -x ramnotes >/dev/null; then
  /usr/bin/pkill -x ramnotes || true

  # Give the app a moment to exit before replacing its bundle.
  for _ in {1..20}; do
    if ! /usr/bin/pgrep -x ramnotes >/dev/null; then
      break
    fi
    sleep 0.25
  done

  if /usr/bin/pgrep -x ramnotes >/dev/null; then
    echo "ramnotes is still running after SIGTERM; stopping it forcefully."
    /usr/bin/pkill -9 -x ramnotes || true
  fi
fi

cd "$ROOT_DIR"
xcodebuild \
  -project ramnotes.xcodeproj \
  -scheme ramnotes \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  build \
  >"$ROOT_DIR/build/dev-build.log" 2>&1 || {
    build_status=$?
    tail -n 80 "$ROOT_DIR/build/dev-build.log"
    exit "$build_status"
  }

open "$APP_PATH"
