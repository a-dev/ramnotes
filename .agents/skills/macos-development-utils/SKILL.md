---
name: macos-development-utils
description: Use for RAMnotes Apple or Xcode documentation lookup, app identity and icon changes, permission or signing diagnostics, and Mac App Store or direct-download release preparation. Complements macos-development with repository-specific operational guidance; ordinary Swift implementation and UI design belong to the existing development skills.
---

# RAMnotes development utilities

Read only the reference for the requested task:

| Task | Reference |
| --- | --- |
| Find an Apple API, check availability, resolve an SDK mismatch | [Apple documentation](references/apple-docs.md) |
| Prepare a Mac App Store build, signing, notarization, or a direct update | [Distribution](references/distribution.md) |
| Change the display name, bundle identity, login scheme, or icons | [Identity and icons](references/identity.md) |
| Diagnose sandbox access, entitlements, or permission prompts | [Permissions](references/permissions.md) |

Run commands from the repository root. Treat `docs/build.md`, `docs/contribution.md`, and the current Xcode project as authoritative; reread their relevant sections before acting. References describe where to investigate, not permission to release or change product identity.

Prepare local changes and inspectable artifacts within the user's request. Uploading, submitting for review, publishing, changing account records, or resetting grants requires authorization covering that action. Existing authorization remains valid; do not ask again. Keep passwords, private signing keys, and App Store Connect keys out of chat, logs, and the repository.

Keep behavior documentation current. Mark checks complete only from observed evidence. Use the existing development skills for implementation details rather than importing Shipcat's app scaffold, permission framework, payment system, or iOS workflows.
