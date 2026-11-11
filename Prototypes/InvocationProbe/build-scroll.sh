#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output="$repo_root/build/InvocationProbe/scroll-probe"
mkdir -p "$(dirname "$output")" "$repo_root/build/InvocationProbe/ModuleCache"
CLANG_MODULE_CACHE_PATH="$repo_root/build/InvocationProbe/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$repo_root/build/InvocationProbe/ModuleCache" \
xcrun swiftc -O -target arm64-apple-macos27.0 "$repo_root/Prototypes/InvocationProbe/main.swift" -o "$output"
echo "$output"