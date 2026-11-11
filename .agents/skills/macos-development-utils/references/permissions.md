# Permissions and sandbox diagnostics

RAMnotes needs no Full Disk Access, Accessibility, or Input Monitoring permission. Do not use these as a repair for folder access or shortcuts. Keep App Sandbox enabled, including during local checks; `CODE_SIGNING_ALLOWED=NO` is not the project's local-build procedure.

## Identify the boundary that failed

Distinguish a sandbox entitlement, user-selected file grant, security-scoped bookmark, TCC permission, login-item approval, and packaging-tool automation permission. They have different owners and remedies. Check the failing operation and signed artifact before suggesting System Settings changes.

Inspect `ramnotes/App/ramnotes.entitlements`, `RAMnotesDebug.entitlements`, and `RAMnotesMAS.entitlements`, plus the helper's entitlements when relevant. Confirm which file the chosen target/configuration uses, then inspect the actual signed bundle:

```sh
codesign -d --entitlements :- /path/to/RAMnotes.app
codesign -dv --verbose=4 /path/to/RAMnotes.app
```

The app uses user-selected read/write access and app-scoped bookmarks. Direct builds also have Sparkle-related exceptions; Debug has an additional library-validation allowance. Do not propagate these to the Store product or add broad entitlements to hide a failure.

## File access and ownership

Trace grant/bookmark handling through `ramnotes/Storage/FolderAccess.swift` and the location workflows. Preserve distinctions between folder access and file-only note access, including restore-access behavior. A missing or stale grant does not authorize silently choosing another location or overwriting a note.

Keep note invariants in the domain and platform file effects in infrastructure. NoteStore application workflows own sequencing and durable checkpoints; presentation requests capabilities. Read `docs/architecture.md` before changing these responsibilities.

Use disposable test sessions and the focused location/folder/external tests in `docs/contribution.md`. When XCTest exceptions obscure real sandbox behavior, use the existing `Prototypes/FileOnlyProbe/` or `Prototypes/FileMoveProbe/` and signed-product manual checks. An unsigned or test-host success is insufficient evidence of distribution access.

## Prompts and identity

Request new capabilities only when an authorized feature needs them. Verify current Apple documentation for the exact API, usage-description key, entitlement, and denial/revocation behavior; do not copy a generic permission catalog. Localize any new usage text through the project's catalogs.

Keep signing and bundle identity stable while diagnosing persistent grants or login registration. Compare signing identities before concluding that a rebuild cleared access. Do not reset all TCC grants or app data as a first diagnostic step. A targeted reset needs authorization that covers the lost grants and must avoid personal notes.

Finder automation requested by `scripts/package-dmg.sh` belongs to the packaging process; it does not imply that RAMnotes itself needs Apple Events permission. Verify login approval through the existing `SMAppService` integration rather than inventing a launch agent.
