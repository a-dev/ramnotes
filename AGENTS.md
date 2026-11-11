# Project commands

Run these from the repository root:

```sh
# Open and run the app in Xcode (select My Mac, then press Command-R).
open ramnotes.xcodeproj

# List the schemes and targets.
xcodebuild -list -project ramnotes.xcodeproj

# Build the Debug app.
xcodebuild -project ramnotes.xcodeproj -scheme ramnotes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

# Run the test targets.
xcodebuild -project ramnotes.xcodeproj -scheme ramnotes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

See [docs/contribution.md](docs/contribution.md) for setup and test rules. See [docs/README.md](docs/README.md) for the spec, UI, and architecture.

# Test scope

Do not run the full UI test suite after small changes. Reserve full UI test runs for large changes or an explicit user request. For small changes, use a build check and focused tests appropriate to the change.

# Docs

Keep the docs true to the code. When a code change affects behavior, update the matching doc in `docs/`. Keep private plans and development records in ignored `tmp/docs/`.

# Note-management boundaries

Use domain-driven design for note-management behavior. Put note invariants in domain types or policies. Domain code must not perform I/O or depend on AppKit, application contracts, or concrete infrastructure. Application workflows own sequencing; infrastructure owns platform effects. Use the terms in `docs/GLOSSARY.md`. Preserve documented transaction boundaries and test affected invariants. Update `docs/architecture.md` when ownership changes.

`ramnotesDomain` independently compiles the sources in `ramnotes/Domain/` as a static library. The app explicitly imports and links this module in Debug, Release, and AppStore configurations. Domain sources belong only to that target. `ramnotesDomainTests` runs pure rules without an app host and uses the public domain API. Keep domain dependencies limited to Foundation values and the Swift standard library. The catalog adapter is in the app target. NoteStore owns serialized workflows; infrastructure collaborators own coordinated location effects and recovery-file creation. Editors, windows, and recovery presentation consume application capabilities. AppCoordinator owns service composition and platform entry points. Editing capabilities, deletion/history workflows, lifecycle transactions, and location entry points are in Application. Location/default-folder/recovery sequencing is in Application extensions on the NoteStore actor, preserving synchronous durable checkpoints. LocationFiles, RecoveryFiles, and RecoveryStore own their file effects. Presentation code is in `ramnotes/Presentation/` (views and feature controllers); views hold no store, catalog, recovery, or file-grant references. `ramnotes/Editing/`, `ramnotes/Windows/`, and `ramnotes/Settings/` hold controllers outside it (see `docs/architecture.md`). The compiler enforces the domain boundary. Application, infrastructure, and presentation share the app target, so their separation is an ownership convention. Application does not import AppKit and calls file, bookmark, and security-scope APIs through `StorageFiles`, `LocationFiles`, `RecoveryFiles`, and `FolderAccess`; only the coordinated save and trash claims use `NSFileCoordinator` directly.
