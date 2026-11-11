# Apple documentation lookup

Use this workflow when an API signature, availability, entitlement, or platform behavior needs verification. Do not infer an API exists from a name in a third-party template.

1. Establish the toolchain with `xcodebuild -version` and `xcrun --sdk macosx --show-sdk-version`. Read the selected target's deployment setting from `ramnotes.xcodeproj/project.pbxproj` or resolved build settings. Do not substitute the host OS version for the deployment target.
2. Discover a connected Xcode documentation search tool if available. Search by exact symbol and framework, then by the behavior if necessary. Do not assume a particular tool name or that Xcode integration is installed.
3. If unavailable or insufficient, search Apple's documentation at `developer.apple.com/documentation` and the relevant release notes. Read the actual page, including availability and deprecations. For signing and submission, use Apple's current help pages as well. Cite the pages used in the answer.
4. Check the signature against the installed SDK. Runtime availability guards do not make a symbol compile on an SDK that lacks it. Report whether an obstacle needs a newer SDK, an OS fallback, or a different API.
5. For implementation, build the affected target using `docs/contribution.md`. Add availability guards only where the API is newer than that target's deployment floor, with a fallback that preserves the requested behavior.

Return the verified symbol or behavior, its relevant availability, the source link, and any remaining uncertainty. A successful build verifies SDK compatibility; use focused behavior checks when runtime semantics matter. A documentation-only lookup does not require an app build.
