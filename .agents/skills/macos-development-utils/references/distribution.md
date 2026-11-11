# Distribution preparation

Read `docs/build.md`, `docs/todo/release.md`, and the distribution sections of `docs/todo/manual-checks.md`. Check actual scripts before running them. Do not add a second release pipeline from the reference project.

## Choose the channel

| Channel | Scheme / configuration | Required distinction |
| --- | --- | --- |
| Direct download | `ramnotes` / `Release` | Developer ID export, notarized DMG, signed Sparkle appcast |
| Mac App Store | `RAMnotesMAS` / `AppStore` | Store distribution through Xcode Organizer; updater-free bundle |

Both use `com.ramnotes.RAMnotes` and share settings and note access. Install one channel at a time. The direct product embeds the login helper; inspect the selected product rather than assuming identical contents.

Before archiving, resolve the documented release blockers, including temporary measurement code and direct production feed/key configuration. Read the current versions and synchronize app/helper versions as required. Record the intended commit and identify unrelated work; do not commit it or clean it up implicitly.

Use `bash scripts/check-builds.sh` for a distribution-wide build check. Its dummy update configuration and ad-hoc signatures produce verification artifacts, not shippable builds. Follow project test scope; this task does not automatically require the full UI suite.

## Mac App Store

- Prepare with `bash scripts/archive-build.sh mas build/RAMnotesMAS.xcarchive`, using a fresh output path and the intended signing team. The script archives and inspects; it does not upload.
- Export using Organizer's current App Store Connect flow. Inspect the exported app with `scripts/inspect-update-bundle.py` in `updater-free` mode. Verify that Sparkle linkage, helpers, metadata, and entitlements are absent as required by `docs/build.md`.
- Before an authorized upload, verify the macOS App Store Connect record, bundle identifier, signing, version/build, and the exact artifact. Check current Apple requirements rather than copying iOS screenshot sizes, export methods, or assumed API-key roles.
- Draft listing, privacy, export-compliance, age-rating, and review answers from actual behavior and dependencies. `ramnotes/App/PrivacyInfo.xcprivacy` is evidence, not a substitute for the App Privacy questionnaire. Do not infer encryption or collection answers from Shipcat.
- Current product decisions live in the release docs: a paid one-time Store download, no subscription or in-app purchase; an English listing and English privacy/support URLs, with supported app languages from the bundle. Recheck these decisions rather than introducing StoreKit or a paywall.
- Plan TestFlight coverage of folder authorization, save/recovery, login launch, and installation using disposable notes. Report upload, processing, TestFlight testing, review submission, approval, and public release as separate states.

## Direct download

Use `bash scripts/archive-build.sh direct build/RAMnotes.xcarchive` with the documented production Sparkle variables and signing team. Export with Developer ID and retain hardened runtime. Inspect the export in `release` mode before packaging.

Follow the existing packaging/notarization commands in `docs/build.md`: package the signed export, submit the finished DMG, wait for Accepted, staple, validate, then compute its checksum. A rejected or failed notarization is a stopping point: inspect its log and fix the cause before another submission. Do not blindly retry uploads or overwrite existing artifacts.

Keep Sparkle's private key outside build settings. Verify the public key and feed correspond to the intended installed update chain; do not generate a replacement key as a release repair. Produce the signed appcast with the pinned Sparkle tools and complete clean-account install/update checks before publication.

Report artifact paths, source revision, channel, checks actually completed, and remaining account/manual steps. This skill does not handle repository hosting or GitHub publication.
