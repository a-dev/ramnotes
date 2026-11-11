# Run the file-only sandbox probe

Use disposable files only. The probe replaces the selected file and can move it to Trash. It has no restore command.

1. Build a fresh session from the repository root:

   ```sh
   sh Prototypes/FileOnlyProbe/build.sh
   ```

2. Create a new directory named `ramnotes-file-only-<unique suffix>` outside the app container. Create `probe-target.txt` inside it. Set permissions to `0640` to exercise metadata preservation.
   To seed permissions, a read ACL, a custom extended attribute, a Finder tag, and an unrelated sibling, use:

   ```sh
   python3 Prototypes/FileOnlyProbe/metadata.py seed /private/tmp/ramnotes-file-only-example
   python3 Prototypes/FileOnlyProbe/metadata.py inspect /private/tmp/ramnotes-file-only-example
   ```

   The seed command requires a new directory and refuses to overwrite an existing fixture. Compare metadata immediately before and after saves. Allow provider metadata to settle before the baseline.

3. Open the app at the path printed by the build script. Keep this bundle and its identifier unchanged for relaunch checks.
4. Click **Select File…** and select only `probe-target.txt`. For a separate acquisition test, build another fresh session and drag the file from Finder onto the window background.
5. Check that unrelated sibling content reads and sibling creation both report denial. Either success stops saves and Trash. Parent enumeration is diagnostic only, as agreed in the implementation discussion. Normal application code must never enumerate the custom parent.
6. Run **Foundation Save ×3** and **NSDocument Save ×3**. Check the exact-byte, permission, bookmark, and isolation results.
7. Quit and reopen the same app. Check bookmark restoration, then repeat saves.
8. Run the document failure buttons. These test NSDocument, the preferred strategy. Check that failure before replacement preserves base bytes and failure after replacement preserves intended bytes.
9. Run each exit button separately. Each document exit button terminates the process with exit code 86. The before-replacement hook runs after NSDocument writes its staged file. The after-replacement hook runs after `writeSafely` returns and before bookmark renewal. Reopen the app and check `PASS interrupted save exact bytes` before the next operation.
10. Click **Trash File** and confirm. Check the API result and original-file reachability. Restore through Finder if needed.

For a before-selection negative control, launch a new session with a fixture path:

```sh
open /absolute/path/to/FileOnlyProbe.app --args --baseline-file /absolute/path/to/ramnotes-file-only-example/probe-target.txt
```

The argument supplies a path for attempted access. It does not create authorization. The baseline runs before any bookmark resolution or picker selection.

The build script uses the production `RAMnotesMAS.entitlements`, ad-hoc signs the app, verifies its signature, and prints signed entitlements. A new session identifier creates a separate sandbox container. Pass the same identifier to rebuild that session. Do not use a rebuilt session as fresh-access evidence.

Reports are written per process to `Application Support/results-<pid>.txt` inside that session's sandbox container. The probe retains base and intended bytes in its own defaults for failure checks. Keep reports, bookmarks, fixtures, and generated apps out of version control.

The Foundation candidate uses an item replacement directory, flushes the payload, replaces under coordination, and restores POSIX permissions on the target. It never syncs or creates an arbitrary temporary file in the parent directory. The NSDocument candidate disables autosaving and versions and calls `writeSafely` explicitly. Neither candidate is integrated into RAMnotes.

The exit controls exercise process interruption, not power loss. The metadata helper checks owner, group, mode, a read ACL, a custom extended attribute, and a Finder tag. Other ACL shapes, external replacement races, bookmark persistence failures, and distribution-signed behavior still need acceptance.
