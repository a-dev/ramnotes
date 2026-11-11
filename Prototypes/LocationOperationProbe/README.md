# CP-03 signed location-operation probe

This disposable App Sandbox app compiles the production `NoteStore`, its storage dependencies and metadata contracts. It does not open or reset the product app's state. Its unique bundle is `dev.ramnotes.CP03LocationProbe`.

Build with `sh Prototypes/LocationOperationProbe/build.sh`. Create a disposable APFS disk image, mount it at `/tmp/ramnotes-cp03-volume`, and create `probe-destination` inside it. The native folder picker accepts only that exact normalized folder. The probe generates synthetic text in a new `CP03-<UUID>` directory in its own sandbox Application Support directory and a uniquely named destination file. It never selects an existing note or overwrites a destination.

1. Launch `build/LocationOperationProbe/CP03LocationProbe.app` and choose **Choose Disposable Destination**. Select `/tmp/ramnotes-cp03-volume/probe-destination` using the native picker.
2. Verify the PASS message: the production actor copied across volumes, verified bytes/mtime, persisted `destinationVerified` and retained the source. Injected faults at verification and source removal keep the operation at that boundary despite observer callbacks.
3. Terminate this probe process, relaunch the same signed app, and choose **Resume Persisted Operation**. This creates a fresh production store without injected faults. Startup restores persisted grants, verifies the recorded destination identity/revision, removes only the unchanged original and completes the catalog. The PASS check includes NoteID, location revision, timestamp and empty recovery diagnostics.
4. Repeat relaunch/resume to verify completed custom-file restoration. Inspect `collection.json` and `probe-result.txt` in the reported run directory. Keep fixtures for evidence; no automatic cleanup or migration exists.

The entitlements are reused from `StorageAccessProbe`: sandbox, user-selected read/write, and app-scoped bookmarks only. Test hooks and broad test-host entitlements are not used.
