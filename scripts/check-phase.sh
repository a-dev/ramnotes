#!/bin/bash
# Fast pre-commit checks for a refactor phase. Reads files only: builds nothing, runs no tests, changes nothing.
# Usage: bash scripts/check-phase.sh [BASE]   (BASE defaults to HEAD; whitespace is checked from BASE to the working tree)
set -uo pipefail
cd "$(dirname "$0")/.."
base="${1:-HEAD}"
project=ramnotes.xcodeproj/project.pbxproj
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# 1. Whitespace errors in tracked changes, staged and unstaged.
if ! git diff --check "$base" -- . >/dev/null; then
    fail "git diff --check $base reports whitespace errors:"
    git diff --check "$base" -- . | head -20
fi

# 2. Every Swift source is in the Xcode project and compiled by a target, and every project reference exists on disk.
# References are either repository-relative (sourceTree = SOURCE_ROOT) or a bare name inside a group,
# so a source counts as built when a Sources entry names its full path or its file name.
while IFS= read -r file; do
    name=$(basename "$file")
    grep -qF "/* $file in Sources */" "$project" || grep -qF "/* $name in Sources */" "$project" \
        || fail "not compiled by any target: $file"
done < <(find ramnotes ramnotesTests ramnotesUITests ramnotesDomainTests ramnotesLoginHelper -name '*.swift' -not -path '*/.*')
while IFS= read -r file; do
    [ -e "$file" ] || fail "the Xcode project references a missing file: $file"
done < <(grep -E 'sourceTree = SOURCE_ROOT' "$project" | grep -oE 'path = "?[^;"]+\.swift"?;' \
    | sed -E 's/^path = "?([^"]*)"?;$/\1/' | sort -u)

# 3. Layer boundaries the compiler does not enforce (see AGENTS.md).
if hits=$(grep -rln '\bRecoveryRecord\b' ramnotes/Presentation 2>/dev/null); then
    fail "Presentation uses RecoveryRecord: $hits"
fi
if hits=$(grep -rlE '^import (AppKit|SwiftUI|Cocoa)' ramnotes/Domain 2>/dev/null); then
    fail "Domain imports a UI framework: $hits"
fi

# 4. Relative Markdown links in instruction files and docs resolve.
while IFS= read -r doc; do
    dir=$(dirname "$doc")
    while IFS= read -r target; do
        path="${target%%#*}"
        [ -z "$path" ] && continue
        [ -e "$dir/$path" ] || fail "broken link in $doc: $target"
    done < <(grep -oE '\]\([^)[:space:]]+\)' "$doc" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^(https?:|mailto:|#)')
done < <(find AGENTS.md README.md docs -name '*.md' 2>/dev/null)

if [ "$failures" -eq 0 ]; then
    echo "check-phase: all checks passed"
else
    echo "check-phase: $failures failure(s)"
    exit 1
fi
