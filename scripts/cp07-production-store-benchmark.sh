#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
WORK=${1:-/private/tmp/ramnotes-cp07-production-store}
BIN=${CP07_BINARY:-/private/tmp/cp07-production-store-benchmark}
mkdir -p build/CP07/ModuleCache
STORAGE_SOURCES=""
for source in ramnotes/Storage/*.swift; do
  if [ "${CP07_NO_OBSERVERS:-0}" = "1" ] && [ "$source" = "ramnotes/Storage/NoteStore.swift" ]; then
    continue
  fi
  STORAGE_SOURCES="$STORAGE_SOURCES $source"
done
if [ "${CP07_NO_OBSERVERS:-0}" = "1" ]; then
  python3 scripts/cp07-noop-observers.py build/CP07/NoteStore-NoObservers.swift
  STORAGE_SOURCES="$STORAGE_SOURCES build/CP07/NoteStore-NoObservers.swift"
fi
printf '%s\n' '--- Swift compiler ---'
xcrun swiftc --version
printf '%s\n' '--- Host ---'
uname -a
sw_vers
printf '%s\n' '--- Building optimized production component harness ---'
CLANG_MODULE_CACHE_PATH=build/CP07/ModuleCache \
SWIFT_MODULE_CACHE_PATH=build/CP07/ModuleCache \
xcrun swiftc -O -parse-as-library \
  ramnotes/Domain/*.swift $STORAGE_SOURCES ramnotes/Infrastructure/Persistence/MetadataStore.swift \
  ramnotes/Invocation/ShortcutService.swift \
  scripts/cp07-production-store-benchmark.swift \
  -o "$BIN"
printf '%s\n' '--- Running benchmark ---'
"$BIN" "$WORK" "${2:-}"
