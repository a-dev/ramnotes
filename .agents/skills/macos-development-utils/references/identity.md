# Identity and icons

Distinguish a display-name or artwork change from a persistent identity migration. RAMnotes is already named and configured; do not start a naming interview or replace identifiers because a template uses different conventions.

## Inspect the identity surfaces

- `ramnotes.xcodeproj/project.pbxproj`: app and helper bundle IDs, display/product names, versions, signing team, category, icon settings, and all affected configurations.
- `ramnotes/App/Info.plist`: shared URL registration. Direct builds generate an additional plist through `scripts/validate-direct-update-config.py`; change the source rather than generated output.
- `ramnotes/Invocation/LoginService.swift` and `ramnotesLoginHelper/main.swift`: helper identifier and `ramnotes-login` handoff.
- `ramnotes/App/InfoPlist.xcstrings` and `Localizable.xcstrings`: localized display text. Preserve the project's terminology and localization rules.
- `ramnotes/App/AppIcon.icon`, asset catalog, and About icon images: inspect the project's actual icon pipeline before editing. Do not replace the Icon Composer source with a template PNG icon set.

Read `docs/build.md` for channel identities. The direct and Store products intentionally have different product names but the same display name and bundle ID. Do not normalize this difference away.

Before changing a bundle ID, team, or helper ID, trace preferences, app-container paths, bookmarks, login registration, and update trust. State the migration impact and resolve missing product decisions before applying an identity migration. A visible rename alone does not authorize a new persistent identity.

For artwork, preserve supplied source assets and produce a preview when the visual choice is undecided. Use the actual macOS icon format and current Apple guidance; do not apply iOS transparency or margin rules indiscriminately. Update dependent About assets only when they are intended to share the new artwork.

Verify the affected built products' `Info.plist`, signatures, icon resources, and login helper registration. Use disposable notes for access checks, and inspect the icon in the app/Finder when visual verification is possible. Report any visual or signed-product checks still outstanding.
