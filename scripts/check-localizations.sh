#!/bin/bash
# Fails when a string catalog has a missing, unreviewed, stale, or mismatched translation.
# Usage: scripts/check-localizations.sh [catalog.xcstrings ...]
# Without arguments it checks Localizable.xcstrings and InfoPlist.xcstrings.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -I scripts/check-localizations.py "$@"
