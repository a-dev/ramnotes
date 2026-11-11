# Build and release

Run commands from the repository root. See [Development](contribution.md) for Xcode setup and local signing.
Both products target Apple Silicon and macOS 27.0 or later.

## Products and updates

| Scheme | Product | Updates |
| --- | --- | --- |
| `ramnotes` | `RAMnotes.app` | Sparkle 2.10.0, pinned through Swift Package Manager. |
| `RAMnotesMAS` | `RAMnotesMAS.app` | App Store. No Sparkle linkage, helpers, metadata, or entitlements. |

Both products display RAMnotes and use `com.ramnotes.RAMnotes`. Install one channel at a time because they share settings and note access.
The direct app embeds `com.ramnotes.RAMnotes.LoginHelper`.
The `ramnotes App Store` scheme is an alias for `RAMnotesMAS`.

Direct Release builds default to `https://ramnotes.com/updates/appcast.xml` and the RAMnotes public Ed25519 key in the target build settings.
Command-line build settings can override `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`.
The private key is in the login Keychain, under Sparkle account `com.ramnotes.RAMnotes`. It is separate from the Developer ID identity.
Back up signing keys securely. Keep private keys outside build settings and source control.
`scripts/validate-direct-update-config.py` checks these values and generates the direct target's plist.
`ramnotes/App/Info.plist` contains shared metadata.

Ordinary Debug builds omit update metadata and never start the updater.
A local fixture requires `SPARKLE_TEST_FEED=YES`, a loopback feed URL, and its public key.
Only that Debug mode permits HTTP. Sparkle owns consent, downloads, and installation UI.
Sparkle does not install updates automatically. Update relaunch uses the app's save-and-quit workflow.

## Translations

Translators can work from Xcode localization catalogs. Export one `.xcloc` for each language:

```sh
xcodebuild -exportLocalizations -project RAMnotes.xcodeproj -localizationPath build/Localizations -exportLanguage es -exportLanguage pt -exportLanguage de -exportLanguage fr -exportLanguage ar -exportLanguage ja -exportLanguage zh-Hans
```

Import a translated file:

```sh
xcodebuild -importLocalizations -project RAMnotes.xcodeproj -localizationPath build/Localizations/es.xcloc
```

Use one `-exportLanguage` for each locale. Build the `ramnotes` scheme in Xcode first so the export sees all strings.
Give translators `docs/localization-terms.md`. Run `bash scripts/check-localizations.sh` after an import.
Do not commit `build/Localizations`.

## Check both channels

```sh
bash scripts/check-builds.sh
```

This checks direct Debug and Release, AppStore, hostless domain tests, and the update validator sequentially.
It inspects built bundles and signatures with ad-hoc signing. It does not run UI tests.
Its Release feed and key are dummy values. Do not distribute those artifacts.
`RAMNOTES_BUILD_ROOT` overrides `build/CI`.

`.github/workflows/ci.yml` uses this script on the `xcode-27` arm64 runner.
Jobs have read-only permissions and no distribution secrets. No workflow publishes on version tags.

## Create a local ZIP

```sh
just build dev
just build release
just build mas-release
```

Choose one command for the required channel and configuration.
Builds are incremental by default. Add `--force` to run `xcodebuild clean build` before creating the ZIP, for example `just build release --force`.
The direct Release command uses the production Sparkle settings.
Outputs are `RAMnotes-dev.zip`, `RAMnotes-release.zip`, or `RAMnotes-mas-release.zip` in `~/Downloads`.
`DERIVED_DATA_PATH` overrides the build directory. ZIPs always go to `~/Downloads`.
ZIP creation does not notarize the app.

On another Mac, extract the ZIP and move its app to `/Applications`.
A trusted local build can require Open Anyway in System Settings > Privacy & Security.
Choose the notes folder again. Folder authorization does not transfer between Macs.

## Archive and export

Verify the exported product and installation before publication.
Direct distribution requires Developer ID signing. Store certificates and credentials in Keychain.
Configure `DEVELOPMENT_TEAM` in your shell or trusted CI. Production Sparkle defaults are in the direct Release target.
Use one archive command:

```sh
bash scripts/archive-build.sh direct build/RAMnotes.xcarchive
bash scripts/archive-build.sh mas build/RAMnotesMAS.xcarchive
```

The script refuses existing output paths and checks the resulting bundle.
It does not export, notarize, generate an appcast, or publish.

1. Match app and helper versions to the intended tag without its `v` prefix.
2. Commit the release changes.
3. Check `git status --short` for a clean tree.
4. Record `git rev-parse HEAD` as the release commit.
5. Export the archive through Xcode Organizer with the appropriate distribution signing.

For direct distribution, choose Distribute App > Custom > Developer ID > Export.
Keep hardened runtime enabled for the app and helper.
The remaining commands assume `build/export/RAMnotes.app`.
Inspect the exported product:

```sh
python3 scripts/inspect-update-bundle.py release build/export/RAMnotes.app
```

For the App Store product, use the `updater-free` mode and its exported app path.

## Package and notarize the direct app

Install `create-dmg` before packaging:

```sh
brew install create-dmg
bash scripts/package-dmg.sh build/export/RAMnotes.app
```

The script creates `build/RAMnotes.dmg` and refuses to overwrite an existing DMG.
An optional second argument selects another output path.
Packaging requires a logged-in desktop and can request Finder automation permission.

Store notarization credentials in Keychain once:

```sh
xcrun notarytool store-credentials RAMnotes-notary
```

Submit the finished DMG:

```sh
xcrun notarytool submit build/RAMnotes.dmg --keychain-profile RAMnotes-notary --wait
```

Wait for Accepted status before stapling:

```sh
xcrun stapler staple build/RAMnotes.dmg
xcrun stapler validate build/RAMnotes.dmg
shasum -a 256 build/RAMnotes.dmg > build/RAMnotes.dmg.sha256
```

Download the published artifact through a browser and check installation, file access, editing, saving, recovery, and launch at login using disposable notes.
Generate the signed Sparkle appcast before publishing an update.

## Host updates

The source repository can stay private. No public Git branch is required.
`distribution/appcast.xml` is the initial feed with no releases. Copy it to the Astro website's `public/updates/appcast.xml` and deploy the website.
It advertises no download until a signed release archive exists.

After Developer ID export, notarization, stapling, and validation, put the versioned DMG (for example `RAMnotes-1.0.0.dmg`) in a local release archive directory under `build/`.
Generate its signed update entry with the pinned Sparkle tools:

```sh
bash scripts/generate-appcast.sh build/updates
```

`SPARKLE_TOOLS_DIR` overrides the tools directory. The command reads the private key from Keychain using account `com.ramnotes.RAMnotes`. It never exports the key.
Retain the generated feed and prior release archives between releases. Increment the direct app and login helper's `CURRENT_PROJECT_VERSION` together for every distributed build. Sparkle compares `CFBundleVersion`, not the marketing version.

Upload the DMG, generated release notes and delta files first, then replace `appcast.xml` last. All URLs use `https://ramnotes.com/updates/`.
For an Astro static-assets deployment, copy only those public artifacts into `public/updates/`. Large downloads may need separate storage behind that URL. Check the hosting provider's asset-size limit before uploading.
Keep private keys, source, archives containing development data, and Keychain exports out of the website.
Do not replace an existing live feed with the empty starter feed.

## Publish to GitHub

Publish only when the owner requests it. Authenticate GitHub CLI with `gh auth login` once.
Check that HEAD matches the recorded release commit.
Replace `v1.0.0` with the actual version:

```sh
git tag -a v1.0.0 -m "RAMnotes v1.0.0"
git push origin v1.0.0
gh release create v1.0.0 \
  build/RAMnotes.dmg \
  build/RAMnotes.dmg.sha256 \
  --verify-tag --draft --title "RAMnotes v1.0.0" --generate-notes
gh release view v1.0.0 --web
```

Review the draft's notes, tag, DMG, and checksum before publication:

```sh
gh release edit v1.0.0 --draft=false
```

For an existing draft, upload missing assets with `gh release upload`.
Keep DMGs and checksums out of Git commits.
