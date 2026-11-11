# File-only move sandbox regression

This probe compiles the production storage implementation and uses only the sandbox,
user-selected read/write, and app-scoped bookmark entitlements. It does not use XCTest
or its additional filesystem exceptions. All notes it creates are disposable fixtures.

```sh
sh Prototypes/FileMoveProbe/build.sh
open build/FileMoveProbe/FileMoveProbe.app
```

1. Click **Move Disposable Note…**. In the native Save panel, select Downloads and keep
   the generated unique filename. Never select an existing file.
2. Require `PASS move`. The probe checks exact UTF-8 bytes, timestamp, NoteID, advanced
   location revision, source removal, and absence of unfinished location operations.
3. Click the button again and select another unique filename in Downloads. Require
   `PASS move` again. This exercises cleanup of a source authorized only as a file.
4. Terminate the probe process and reopen the same bundle. Require `PASS relaunch`.
   This checks restoration of the persisted file bookmark, NoteID, bytes, and completed
   transaction without retaining the first process's grants.

The probe stores its support path and NoteID in its own preferences so relaunch checks
use the same fixture. It retains the final disposable file for inspection. No personal
notes are opened. Build products and container data stay out of version control.

## Evidence recorded on 2026-11-01

The original production code reproduced the Downloads failure under these entitlements.
The result was `interrupted`, stage `prepared`, POSIX error 1 (`EPERM`), with source
and destination both present. Temporary instrumentation showed `copyfile`, destination
open, and file `fsync` succeeding; destination parent-directory sync then failed.
The kernel also reported a denied `file-read-data` operation on Downloads.

With directory syncing limited to folder-authorized locations, both moves above and a
fresh-process relaunch passed. The test fixture contained Unicode text. All 53 focused `LocationTests` also passed, and the app/test build succeeded.
This establishes local Downloads behavior; it does not establish provider, external-volume, distribution,
or power-loss acceptance. File-only access does not permit syncing the parent directory.
