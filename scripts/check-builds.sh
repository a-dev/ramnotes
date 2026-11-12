#!/bin/bash
# Local and CI verification. Creates no distribution artifacts and never publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
derived="${RAMNOTES_BUILD_ROOT:-build/CI}"
common=(-onlyUsePackageVersionsFromResolvedFile -project RAMnotes.xcodeproj -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
python3 -m unittest discover -s scripts -p 'test_validate_direct_update_config.py'
xcodebuild "${common[@]}" -scheme ramnotes -configuration Debug build
python3 scripts/inspect-update-bundle.py disabled "$derived/Build/Products/Debug/RAMnotes.app"
# Compile the release-only path with public test metadata. Never launch this artifact.
xcodebuild "${common[@]}" -scheme ramnotes -configuration Release \
    SPARKLE_FEED_URL=https://example.invalid/ramnotes/appcast.xml \
    SPARKLE_PUBLIC_ED_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= build
python3 scripts/inspect-update-bundle.py release "$derived/Build/Products/Release/RAMnotes.app"
xcodebuild "${common[@]}" -scheme RAMnotesMAS -configuration AppStore build
python3 scripts/inspect-update-bundle.py updater-free "$derived/Build/Products/AppStore/RAMnotes.app"
xcodebuild "${common[@]}" -scheme ramnotesDomain -configuration Debug -parallel-testing-enabled NO test
