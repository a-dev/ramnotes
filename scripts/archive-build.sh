#!/bin/bash
# Archive only. Signing, export, notarization, and publication remain explicit steps.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 || ( "$1" != direct && "$1" != mas ) ]]; then
    echo 'usage: archive-build.sh direct|mas OUTPUT.xcarchive' >&2
    exit 2
fi
channel="$1"
archive="$2"
if [[ -e "$archive" ]]; then
    echo "Archive already exists: $archive" >&2
    exit 1
fi
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your signing team}"
args=(-project RAMnotes.xcodeproj -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath build/Archive -onlyUsePackageVersionsFromResolvedFile "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
if [[ "$channel" == direct ]]; then
    args+=(-scheme ramnotes -configuration Release)
    # Production defaults live in the target. Xcode's build phase validates them.
    if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then args+=("SPARKLE_FEED_URL=$SPARKLE_FEED_URL"); fi
    if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then args+=("SPARKLE_PUBLIC_ED_KEY=$SPARKLE_PUBLIC_ED_KEY"); fi
else
    args+=(-scheme RAMnotesMAS -configuration AppStore)
fi
xcodebuild "${args[@]}" archive
mode=updater-free
product=RAMnotesMAS
if [[ "$channel" == direct ]]; then mode=release; product=RAMnotes; fi
python3 scripts/inspect-update-bundle.py "$mode" "$archive/Products/Applications/$product.app"
