# Build and release

Run commands from the repository root. See [Development](contribution.md) for Xcode setup and local signing.
Both products target Apple Silicon and macOS 27.0 or later.

## Products and updates

| Scheme | Product | Updates |
| --- | --- | --- |
| `ramnotes` | `RAMnotes.app` | Sparkle 2.10.0, pinned through Swift Package Manager. |
| `RAMnotesMAS` | `RAMnotes.app` | App Store. No Sparkle linkage, helpers, metadata, or entitlements. |

Both products display RAMnotes and use `com.ramnotes.RAMnotes`. Install one channel at a time because they share settings and note access.
The direct app embeds `com.ramnotes.RAMnotes.LoginHelper`.
The `ramnotes App Store` scheme is an alias for `RAMnotesMAS`.

Direct Release builds default to `https://a-dev.github.io/ramnotes/appcast.xml` and the RAMnotes public Ed25519 key in the target build settings.
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

## App Store archive

Configure `DEVELOPMENT_TEAM` in your shell or trusted CI, then archive:

```sh
bash scripts/archive-build.sh mas build/RAMnotesMAS.xcarchive
```

The script refuses existing output paths, checks the bundle with the `updater-free` mode, and checks that the app and login-helper dSYM files match their binaries.
It does not export or upload. Export through Xcode Organizer.

### Store listing texts

`docs/store/locales/<locale>.md` holds the listing for each App Store Connect locale: name, subtitle, promotional text, keywords, and description.
Keep the `##` headings in English, because the upload script finds the fields by heading.

Check the files without network access:

```sh
node scripts/upload-store-metadata.mjs --check-only
```

Upload them to the editable macOS version (`--dry-run` shows the changes first):

```sh
node scripts/upload-store-metadata.mjs --dry-run --key-path ~/keys/AuthKey_XXXX.p8 --key-id XXXX --issuer-id YYYY
```

The script finds the app by bundle ID `com.ramnotes.RAMnotes` unless you pass `--app-id`.
It accepts the same values in `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_APP_ID`.
`--locale de-DE` limits the upload to one language.
Before it writes, it saves the previous remote texts to `tmp/`, then it reads back each record to verify it.
It does not change URLs, screenshots, or release notes, and it does not submit the app for review.

## Direct release

Direct releases use GitHub. Release builds and `scripts/release.py` use these values by default:

| Item | Value |
| --- | --- |
| Update feed | `https://a-dev.github.io/ramnotes/appcast.xml`, from the `gh-pages` branch through GitHub Pages |
| ZIP and DMG | Assets of the GitHub Release with the tag `<VERSION>-<BUILD>` |
| Public EdDSA key | `PTnXhFSvIhMUagqM5mA3++Aemj0iLDfLFN77xty6RL8=` |
| Private EdDSA key | Login Keychain, Sparkle account `com.ramnotes.RAMnotes` |

Sparkle installs the ZIP. People download the DMG.

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project. Every target must use the same values. The build is a positive integer greater than all published builds, including withdrawn builds. Sparkle compares the build, not the marketing version. Never use a build number again.
2. Commit the change. The real run needs a clean working tree.
3. [Make a release candidate](#make-a-release-candidate). Do the dry run first.
4. [Publish](#publish) the candidate. Do the plan first.
5. Download the DMG through a browser and check installation, file access, editing, saving, recovery, and launch at login with disposable notes.
6. Install the previous release and check that it updates to the new one.

### Make a release candidate

Prepare these local inputs:

- A history file with all published builds, for example `{"published_builds": [1, 2]}`. Use `{"published_builds": []}` for the first release. The script checks the format, not completeness.
- The release notes in HTML. Sparkle shows them in the update window.
- A `notarytool` Keychain profile. Create it once with `xcrun notarytool store-credentials RAMnotes-notary`.
- `create-dmg`, installed with `brew install create-dmg`.

Do the dry run:

```sh
scripts/release.sh --dry-run \
  --history build/published-builds.json \
  --notes build/release-notes.html \
  --output build/candidate-1.0.0-1 \
  --identity 'Developer ID Application: NAME (TEAMID)' \
  --team TEAMID0000 --notary-profile RAMnotes-notary
```

The dry run reads the inputs and prints the commands. It does not run them, use Keychain, connect to a server, or write output.
It needs the Sparkle 2.10.0 tools. A previous archive puts them in `build/Archive/SourcePackages/artifacts/sparkle/Sparkle/bin`. For a different location, use `--sparkle-bin`.

Remove `--dry-run` for the real run. The script does these steps:

1. Archives with `scripts/archive-build.sh direct` and exports with Developer ID.
2. Checks the app version, feed, key, signature, Hardened Runtime, and bundle.
3. Notarizes the app, requires `Accepted`, keeps the notary logs, and staples the app.
4. Makes the update ZIP from the stapled app with `ditto --keepParent --sequesterRsrc`, and checks that it extracts to identical files.
5. Makes the DMG with `scripts/package-dmg.sh`. Signs, notarizes, and staples it. Packaging needs a logged-in, unlocked desktop. The terminal app needs permission to control Finder in System Settings > Privacy & Security > Automation. The script checks this before it archives.
6. Signs the ZIP with the Keychain key and makes a feed with one item and embedded release notes. Sparkle and a separate CryptoKit check both verify the signature. Delta updates are off.
7. Writes `publication.json` and `SHA256.json` with the hashes of the DMG, the ZIP, and the feed.

If a step fails, the script stops and keeps the partial output. Fix the cause and run again with a new output folder. Do not change files after signing.

`scripts/test_release.py` and `scripts/test_publish_github.py` test the scripts offline. `scripts/check-builds.sh` runs them.

### Publish

Publish only when the owner requests it. Before the first release, do this setup one time:

1. Create an empty `gh-pages` branch and push it.
2. In the repository settings, set Pages to deploy from the root of `gh-pages`.
3. Run `gh auth login` with an account that can create releases and push to `gh-pages`.

Make the plan. The plan sends no network requests:

```sh
scripts/publish-github.py --candidate build/candidate-1.0.0-1 --notes build/release-notes.md
```

To publish, add `--publish`. The script does these steps in this order:

1. Checks the candidate files against `SHA256.json`, and checks that the URLs are the GitHub hosting URLs.
2. Reads the live feed. Stops if the build is not greater than the live build.
3. Creates the GitHub Release `<VERSION>-<BUILD>` with the ZIP, the DMG, and `SHA256.json`.
4. Downloads the assets without credentials and compares the bytes.
5. Replaces `appcast.xml` on `gh-pages`. This step fails if the file changed after step 2.

The feed changes last, so a failure keeps the old feed.

- If step 3 or 4 fails, delete the incomplete release and its tag, then run the script again.
- If the candidate must change, make a new candidate with a greater build.
- GitHub Pages can need a few minutes to serve the new feed.
- To withdraw a release, put the previous `appcast.xml` back on `gh-pages`. Never use the withdrawn build number again.

Keep the private key out of the repository, build settings, and CI logs. Back it up securely. Losing it means installed apps cannot accept new updates.
