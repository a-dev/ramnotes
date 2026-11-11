# Development

See the [documentation index](README.md) for the spec, UI, and architecture.
See [Build and release](build.md) for local ZIPs, signed archives, DMGs, and publication.
RAMnotes uses the [MIT License](../LICENSE).

## Requirements

Use an Apple Silicon Mac with macOS 27.0 or later and Xcode with the macOS 27 SDK or later.
Open Xcode once to accept its license and install components.
Select the full toolchain if necessary:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

## Build and run

Run commands from the repository root.
Common tasks use the [just](https://just.systems/man/en/) command runner (`brew install just`). Run `just` to list the recipes.

`just run` builds and opens the app. `just build` makes a ZIP to transfer the app to another Mac.

| Command | Result |
| --- | --- |
| `just run` | Builds `build/DerivedData/Build/Products/Debug/RAMnotes.app`, quits a running Debug instance, and opens the new app. |
| `just build dev` | Builds Debug and writes `RAMnotes-dev.zip` to `~/Downloads`. |
| `just build release` | Builds Release and writes `RAMnotes-release.zip` to `~/Downloads`. Uses production Sparkle settings. |
| `just build mas-release` | Builds the App Store configuration and writes `RAMnotes-mas-release.zip` to `~/Downloads`. |

The three ZIP recipes build incrementally by default. Add `--force` to rebuild the selected configuration from scratch, for example `just build dev --force`.
Every ZIP goes to `~/Downloads`. Set `DERIVED_DATA_PATH` to change the build folder.
All recipes are in `justfile`. Without just, build with `xcodebuild` directly:

```sh
xcodebuild -project RAMnotes.xcodeproj -scheme ramnotes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/RAMnotes.app
```

In Xcode, open `RAMnotes.xcodeproj`. Select My Mac. Press Command-R to run or Command-U to test.
The app has no Dock icon. Use Quit in Settings or stop it in Xcode.

| Scheme | Purpose |
| --- | --- |
| `ramnotes` | Direct app with the embedded login helper. |
| `ramnotesDomain` | Independent domain library and hostless tests. |
| `RAMnotesMAS` | App Store build without Sparkle. |

Without the team's certificate, append `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` for local ad-hoc signing.
Do not use `CODE_SIGNING_ALLOWED=NO`. Keep sandbox entitlements enabled.
The app needs no Full Disk Access, Accessibility, or Input Monitoring permission.
Keep bundle identity and signing stable to preserve folder access and login registration.

## Test scope and isolation

After a small code change, build and run focused tests. Reserve the full UI suite for large changes or an explicit request.
Run domain, hosted, and UI tests sequentially. Hosted and UI tests can stop each other's app process.
After suite-wide unit-test changes, run the full hosted target twice with a fresh session each time.

Never point tests at personal notes. Hosted tests need a disposable app-host session.
Build test products first:

```sh
xcodebuild -project RAMnotes.xcodeproj -scheme ramnotes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build-for-testing
```

Prepare a fresh configuration for each hosted run:

```sh
session_run=$(python3 scripts/prepare-test-session.py build/DerivedData/Build/Products/ramnotes_Default_macosx27.0-arm64.xctestrun)
xcodebuild -destination 'platform=macOS,arch=arm64' -xctestrun "$session_run" -parallel-testing-enabled NO -only-testing:ramnotesTests/StorageTests test-without-building
```

Use the generated `.xctestrun` filename if the SDK changes.
Replace the suite selector with the affected suites. Select `ramnotesTests` for all hosted tests.
Run `ramnotesUITests` separately when required. UI tests create their own disposable sessions.
A focused rerun does not establish a full-suite pass.

UI tests require an unlocked, logged-in desktop and can request automation permission.
A locked session can prevent focus or report `System authentication is running`.
Check `ioreg -n Root -d1` for `CGSSessionScreenIsLocked` when diagnosing that failure.
Unlock the desktop before repeating affected scenarios. Keep focus assertions intact.

### Check project structure

```sh
bash scripts/check-phase.sh [BASE]
```

The script checks whitespace since `BASE`, which defaults to `HEAD`. It checks Xcode source membership, layer boundaries, and relative documentation links.


### Domain tests

The domain target compiles only the sources in `ramnotes/Domain/` and has no target dependencies.
Its tests use the public API without an app host.

```sh
xcodebuild -project RAMnotes.xcodeproj -scheme ramnotesDomain -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Domain -parallel-testing-enabled NO test
```

Keep domain sources out of the app's Sources phase.
Independent compilation must reject application, infrastructure, and AppKit dependencies.

### Choose focused coverage

| Change | Relevant suites |
| --- | --- |
| Save, persistence, or recovery | `StorageTests`, `SavingTests`, `FoundationPersistenceTests`, `RecoverySaveStateTests` |
| Identity, access, locations, or Trash | `LocationTests`, `FolderTests`, `ExternalTests`, `TrashTests` |
| Editor positions, external notices, or focus | `EditorTests`, `WindowTests`, `TransitionTests`, `ExternalTests` |
| Search or collection discovery | `SearchTests`, `DiscoveryLifecycleTests` |
| File panels or keyboard routing | Relevant `WorkflowTests`, `LaunchTests`, and `SettingsIntegrationTests` UI scenarios |

Tests are in `ramnotesDomainTests/`, `ramnotesTests/`, and `ramnotesUITests/`.
Compatibility tests use literal version-one catalog and journal bytes.
Location and recovery fault tests reopen durable stages against temporary files.
Preserve coverage for retained text, revision guards, partial migration, checkpoint ordering, and file identity.

Standalone sandbox probes are in `Prototypes/FileOnlyProbe/` and `Prototypes/FileMoveProbe/`.
Use them to isolate file-grant behavior outside XCTest's filesystem exceptions.
Verify production sandbox behavior with a signed app outside XCTest.

### Debug-only launch flags

| Flag | Purpose |
| --- | --- |
| `--test-session UUID` | Store all app data in a temporary session. Required for destructive Debug checks. |
| `--login-launch` | Simulate hidden login startup. |
| `--no-volume-mount` | Do not mount ejected volumes when resolving bookmarks. Required for disconnected-volume checks. |
| `--test-folder-access-fixture` | Seed a damaged access bookmark. Requires a valid test session. |
| `--test-damage-file-bookmarks` | Replace the bookmark of every file-only note in the test session with damaged data. Requires a valid test session. |
| `--test-pause-export` | Pause the first Finder export before verification. Reconciliation continues until you click Continue. Requires a test session. |
| `--test-pause-at STAGE` | Pause at the first matching `StorageStage` until force quit. The fixture writes `paused-at-STAGE` in the test session folder. |

Release ignores test-session isolation. Use a disposable account and disposable notes for Release checks. To preview which app data the reset script removes, run `bash scripts/reset-test-state.sh`. Add `--yes` to remove it.

### Screenshots

The default test plan excludes screenshot generation. Run the dedicated plan:

```sh
xcodebuild -project RAMnotes.xcodeproj -scheme ramnotes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -parallel-testing-enabled NO test -testPlan Screenshots
```

Both About screenshots appear as attachments in the result bundle.

## Compare note-path performance

```sh
python3 scripts/measure-ddd-acceptance.py --baseline COMMIT --current HEAD --runs 5
```

Replace `COMMIT` with the revision to compare. Use `--current WORKTREE` to include uncommitted changes.
The script compiles optimized, unsigned components and runs each revision in alternating fresh processes on one generated corpus.
Each run measures discovery, 30 verified saves, and 30 searches. The report has raw timings and source hashes.
Run it after builds and tests finish. The results do not prove Release latency, idle CPU, or memory.
Measure the signed app separately before release.

### Compare window and editor components

```sh
python3 scripts/measure-ui-performance.py --run --output /private/tmp/ramnotes-ui-performance
```

Use a new or empty output directory and an unlocked desktop. Omit `--run` to compile without opening windows.
The probe runs its own window and editor components with a temporary corpus. It does not use personal notes.
It measures 30 reveals with 1, 10, and 50 open notes. It times 100 insertions in 10 KB and 1 MB editors. It records resident memory over ten hide and reveal cycles.
Insertion timings exclude hardware events, link detection, and list refresh. Resident memory is not the physical footprint that the budget uses.

Record the source revision, signing mode, corpus path, trace files, sample count, and raw samples with each result.
Use disposable notes for signed-app measurements.

## Localization

The app text lives in `ramnotes/App/Localizable.xcstrings`. `InfoPlist.xcstrings` holds the Info.plist strings.
The supported languages are listed in the [spec](SPEC.md#languages). `docs/localization-terms.md` lists one translation per term for each language. Use it for every new translation.
Localize display text only. Never localize persisted values, file formats, metadata keys, or raw values.

### Add a string

Wrap each user-visible string in `String(localized:comment:)`. The English text is the key.

```swift
String(localized: "Move to Trash…", comment: "Menu item. Moves the selected note to the Trash.")
```

Use an explicit key with `defaultValue:` only when one English word has two meanings, such as "Open" as a verb and "Open" as a state.
Add a translator comment to every string that is ambiguous, short, or has a placeholder. Say what the placeholder holds. Say when `RAMnotes` must stay unchanged.
Build each sentence from one format string. Never concatenate translated fragments.
Never use display text as an identifier. Use `setAccessibilityIdentifier` for UI tests.
Use `Date.FormatStyle` and `.formatted(...)` for dates and numbers. Never hard-code date patterns or separators.
Wrap file paths and filenames inside sentences with `PathIsolation.isolate(_:)`.

Add the key to the catalog with a translation for each of the seven other languages, state `translated`. A command-line build does not write new keys into the catalog, so use Xcode or add them by hand.

### Plurals

Use catalog plural variations for every count. Never branch on `count == 1` in code. Pass the count as an interpolation, and add the variations in the catalog.
Each language needs its own categories: `en` and `de` use one and other, `es`, `pt`, and `fr` add many, `ar` uses all six, and `ja` and `zh-Hans` use only other.
When one sentence has two counts, use a substitution for each.

### Check the catalogs

```sh
bash scripts/check-localizations.sh
```

The script checks both catalogs. It fails on a missing translation, a state other than `translated`, different placeholders from English, missing plural categories, and a changed `RAMnotes`.
CI runs it in `.github/workflows/ci.yml`. Pass catalog paths to check other files.

### Pseudolanguage checks

Launch the Debug app in a test session with these arguments, in Xcode scheme arguments or on the command line:

| Check | Arguments |
| --- | --- |
| Double length | `-NSDoubleLocalizedStrings YES` |
| Accented text (finds missed strings) | `-NSAccentuateLocalizedStrings YES` |
| Right-to-left | `-NSForceRightToLeftWritingDirection YES -AppleTextDirection YES` |

Check clipping at the minimum window widths, and check that everything mirrors. A launch with only `-AppleLanguages (ar)` shows Arabic text but does not mirror on an English system. Add `-AppleTextDirection YES`.
Pass `--test-session UUID` so the run does not touch personal notes.

### Switch the app language in Debug builds

Debug builds show **Settings > General > Developer > Language**. Choose a language to set the app's `AppleLanguages` override and relaunch RAMnotes in it. Choose **System** to remove the override. The new instance waits until the old one exits (`--debug-relaunch-after`), so notes are flushed before they load again. The picker does nothing in a `--test-session` run. Release, AppStore, and Mac App Store builds do not contain it.

### Tests and screenshots

UI tests locate elements by English labels. Each one launches with `englishLocaleArguments` (`-AppleLanguages (en) -AppleLocale en_US`), defined in `ramnotesUITests/LaunchTests.swift`. Add it to every new UI launch.
`LaunchTests` has one Arabic smoke test. `DisplayNameTests` and `WindowTests` cover localized names, plurals, paths, and dates.
The `Screenshots` test plan has one configuration for each language. Check the signed app in each supported language.

## Repository rules

Keep current behavior in `docs/`. Keep private plans and development records outside the public documentation.
Keep the project README focused on people using the app. Put developer setup, build, test, and release instructions in `docs/`.
Check documentation links and test-name references after moving or deleting their targets.
Use [glossary](GLOSSARY.md) terms and preserve the ownership rules in [architecture](architecture.md).
Do not commit build output, `xcuserdata`, local signing settings, corpora, recovery data, certificates, or credentials.
