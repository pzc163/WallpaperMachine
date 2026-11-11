# Creator macOS 15 ad-hoc acceptance build

**Goal:** Deliver an arm64 macOS 15.0-compatible DMG without requiring Developer ID or notarization credentials.

**Architecture:** Reuse Rehearsal and Build with an explicit non-publishing ad-hoc mode. Keep the macOS 26 icon job separate from macOS 15 compilation. Audit all embedded Mach-O code and dependency minimums before packaging. Retain the original S3 pre-release and publish the verified new artifact under a separate non-version tag.

**Tech stack:** GitHub Actions, Xcode, Python standard library, codesign, hdiutil.

## Implementation and validation

1. Add `scripts/ci_package.py` and its unit tests: unsigned mode needs no credentials, cannot be used for production, and retains deployment/license gates.
2. Extend `scripts/package.py` and its tests to find nested Mach-O files, require arm64, reject foreign/missing deployment records, inspect all slices, and include the deployment evidence in metadata.
3. Add `ad_hoc` to Rehearsal/Build. Skip credential import and notarization only on this explicit route; never run production publishing for it.
4. Run targeted script tests and workflow syntax checks, then one full `python3 scripts/test.py` gate. Commit and push the verified build changes to the feature branch.
5. Dispatch the macOS 15 build, inspect real failures, repair evidenced dependency incompatibilities, then verify the downloaded DMG's contents, signatures, dependency minimums and checksum.
6. Publish a new Pre-release with `latest=false`, verify the downloaded asset, and remove task-local temporary output.

## Boundaries

- Apple Silicon only; no claim of Intel support or Apple notarization.
- No local application install/launch, real desktop changes, personal Keychain access, live LLM request or S4 changes.
- Keep the existing Release app and old S3 release intact. Do not falsify load commands or only lower Info.plist to hide newer dependencies.
- Physical macOS 15 Creator/display/sleep/energy acceptance remains pending until actually performed.

## Evidence

The local compatibility image is verified; see [the structured results](../testing/creator-macos15-results.json).
The existing Release host, extension and embedded framework already target macOS 15.0.
The actual incompatibility was four dylibs from three formulae: QuickJS-NG 0.18.0,
libpng 1.6.59 and Brotli 1.2.1. Their identical-version official arm64_sequoia
bottles were SHA-256 verified, extracted only to a task staging directory, and
substituted in the packaging dependency closure. The original exported symbols
(567 in total) and compatibility/current library versions match. All eight
packaged Mach-O minimums are 15.0; the app and mounted-image strict signature
checks pass. The original build and installed Homebrew were not modified.

The final gate passed 720 script tests and 5,000 native tests, with 72 opt-in skips.
An initial existing WebKit file-load failure did not recur in isolation or in two
subsequent full native gates; no application source was changed for it.
CI is configured but has not run: the fork currently has no registered workflows.
This artifact was assembled locally from the verified app and official macOS 15
dependencies; it is not a claim that a hosted macOS 15 build or physical S3 run passed.

The verified image was published as
[s3-macos15-93eb2aa5](https://github.com/pzc163/WallpaperMachine/releases/tag/s3-macos15-93eb2aa5)
with `prerelease=true`, never Latest. A fresh download matches the recorded SHA-256;
the original S3 release and `main` are unchanged. The build configuration is in
commit `62c3655e`. Both workflow enablement and direct dispatch returned HTTP 404;
the file exists on the default branch, but Actions still lists no registered
workflows. This is an unresolved hosted-CI activation limitation, not a passing run.
