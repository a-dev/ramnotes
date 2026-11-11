#!/bin/bash
# Generate update entries from finished, notarized release archives only.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 || ! -d "$1" ]]; then
    echo 'usage: bash scripts/generate-appcast.sh RELEASE_ARCHIVES_DIRECTORY' >&2
    exit 2
fi
tools="${SPARKLE_TOOLS_DIR:-build/DerivedDataRelease/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[[ -x "$tools/generate_appcast" ]] || {
    echo 'Set SPARKLE_TOOLS_DIR to the pinned Sparkle 2.10.0 bin directory.' >&2
    exit 1
}
exec "$tools/generate_appcast" --account com.ramnotes.RAMnotes \
    --download-url-prefix https://ramnotes.com/updates/ \
    --release-notes-url-prefix https://ramnotes.com/updates/ \
    --link https://ramnotes.com/ "$1"
