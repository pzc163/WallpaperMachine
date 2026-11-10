# Creator S0 technical prototype

This is a service-level prototype, without a creator tab or a model API. The
[implementation plan](../plans/2026-11-10-creator-s0.md) defines its scope. It does
not install, launch or change the desktop as part of verification.

The [S1 and S4 follow-up plan](../plans/2026-11-10-creator-s1-s4.md) adds the future
parameter-only contract, native covers and download/process gates. The
[S1.0 parameterized templates](creator-templates.md) now extend this service
workflow while preserving legacy bundle bytes. [S1.1 revision storage](creator-revisions.md)
adds immutable history, versioned records and a four-file format boundary; cover
capture and the download guard remain unimplemented. The results below are the
recorded S0 results, not a reclassification of unrestricted-code safety.

## Storage and existing author protocol

`ClientPaths.supportURL` is the app-support directory, overridable with
`WALLPAPER_MACHINE_HOME`. `storageURL` follows `StorageLocation.json` and the
target marker; `libraryURL` is `storageURL/Library`. A missing moved disk does
not silently fall back to another library.

An installed project's `project.json` defines its type, entry and
`general.properties`. User choices live separately in
`supportURL/wallpapers/<wallpaperID>.json`: `property_overrides`, `audio`,
`monitors`, `media_integration_enabled` and engine options. User-chosen files
are retained in `UserAssets` and staged into `.mwe-user-assets` for web access.
Standalone HTML import copies only that file; multi-file projects must be
imported as whole directories. `WallpaperImportService` validates a staged
copy before moving or exchanging it into the library.

The existing WebKit author protocol is injected at document start. Swift
delivers property JSON using `callAsyncJavaScript` in the page world to
`window.__mweWallpaperHost.applyUserProperties`, which calls the page's
`wallpaperPropertyListener.applyUserProperties`. It delivers the full first
accepted set, then changes only, and replays values a late listener has not
received. See [web wallpapers](web-wallpapers.md#host-protocol).

Audio registration uses `wallpaperRegisterAudioListener` and the
`mweWallpaper` message channel. Active, enabled subscribers are registered with
the Rust bridge. One Swift pump reads 128 spectrum values at approximately
30 Hz, deduplicates analysis generations and calls the page's audio listener.
The first 64 values are left, the next 64 right, low frequencies first; web
values are clamped to 0–1. Preview disables real audio and media information;
active registered pages may receive synthetic zero arrays. See
[audio response](audio-response.md) and [live preview](wallpaper-properties.md#live-preview).

## Draft and runtime contract

The original S0 `CreatorTemplate` supplies gradient, stars and clock examples.
Its inputs are a UUID, template kind, finite hue in 0–360 and finite speed in 0–2. This is
the trusted-template mode from the plan, not arbitrary code generation.

`CreatorDraftStore` creates immutable directories named `creator-s0-<uuid>`.
Each contains exactly `creator.json`, `project.json` and `index.html`. It rejects
links, additional files, invalid metadata, oversized files, altered source and
incorrect content hashes. The file bytes must equal a reconstruction from the
bounded specification. A cancelled create never publishes a partial directory.

`CreatorPreview.make` validates a draft separately from the installed-library
loader and creates the existing `WebWallpaperPreviewSurface`. The underlying
`WebWallpaperPage` recognises the reserved creator ID prefix on desktop and
preview alike. It reads a validated bundle on a background task, then serves an
immutable in-memory snapshot through `wm-creator://bundle/index.html` without a
file URL read grant. The page is nonpersistent and does not enable the
compatibility host's broad file access.

The template has a restrictive CSP with hashes for its fixed script and style,
plus a compiled native content rule list installed before loading. No external
requests, frames, workers, media, fonts, forms or objects are part of this
format. The navigation delegate accepts only the entry, native dialogs and
capture are denied, and incoming native messages are limited to bounded diagnostics.
Properties and pause still use the existing author protocol. The creator host
disables audio and media demand regardless of stored preferences.

Loading and stop use the page generation fence, so a late disk read cannot
resurrect a stopped preview. Modified bytes are rejected on reload. There is no
claim that arbitrary JavaScript can be forcibly interrupted or assigned exact
CPU/GPU quotas: infinite-loop source is rejected before execution in this mode.

The reserved prefix is an S0 routing contract, not the planned production
runtime registry. Byte reconstruction, rather than a caller-supplied hash or
metadata flag, determines whether source may execute. The original generator is now frozen for S0 compatibility; enhanced templates
use explicit versioned IDs as described in the S1.0 document.

The native lock-screen/screen-saver publisher rejects creator IDs, since its
extension has not adopted this resource host. Ordinary Workshop pages keep
their compatibility behavior. Copying or renaming a bundle outside this
workflow is not a cross-application security guarantee.

## Publication and recovery

`CreatorPublisher` uses the actual `WallpaperImportService` and a caller-provided
installed verification step. Its staged candidate and previous bundle are
immutable snapshots. It records a journal before import, rechecks the installed
version immediately before importing, and confirms only after
verification and another digest check. A failed verification or cancellation
restores the previous version; a failed first import is removed if it still
matches this transaction. Unrelated or externally modified content is never
overwritten by recovery.

`prepare`, `install` and `confirm` are separate durable boundaries. A recreated
publisher's `recover()` rolls back an unconfirmed transaction, even if import
completed before the journal phase advanced. Recovery is idempotent. A file
lock serializes operations across publisher instances; an outstanding journal
blocks another publication until it has been resolved. These boundaries cover
process interruption; sudden power loss and concurrent writes by unrelated
processes are not a transactional guarantee.

S0 recovery concerns library contents. It does not yet drive an actual desktop
assignment, restore a display's previous wallpaper, expose UI or provide the
full project's revision history. A future creator session must call recovery
before offering new publication operations.

## Verification

### Isolation decision and known failing probes

On macOS 27.2 (26B123), injecting arbitrary JavaScript into the loaded page
exposed an outgoing loopback connection from an anchor with `download`, despite
the CSP, native content rules and navigation policy. A response-header
`sandbox allow-scripts` experiment did not eliminate it and was removed.
The EventSource probe reported `InvalidTransition { phase: idle targetPhase:
failed(deinit) }`; its cause is unresolved. The media probe did not contact the
listener but did not deliver a rejection event within 1.5 seconds either.
Neither of these latter outcomes proves a usable isolation boundary.

Consequently S0 accepts **trusted templates and bounded parameters only**.
It does not implement the proposed arbitrary-source `generatedOfflineV1`
contract. Arbitrary download, EventSource, allocation and logging payloads are
rejected by `CreatorDraftStore` before a preview is constructed. Native test
injection intentionally bypasses this byte-validation boundary to explore a
possible future host; it is not an available authoring API.

The three known failing exploratory methods are opt-in, explicitly skipped
in the ordinary gate, and must not be counted as passing restriction checks:

```sh
TEST_RUNNER_CREATOR_UNRESTRICTED_PROBES=1 python3 scripts/test.py \
  --only CreatorPreviewTests/testDownloadLinksAreBlockedBeforeConnecting \
  --only CreatorPreviewTests/testEventSourceIsBlockedBeforeConnecting \
  --only CreatorPreviewTests/testMediaIsBlockedBeforeConnecting
```

Free-form generation remains blocked until these probes and a process-isolated
stop/watchdog design pass. A first model integration may emit template
parameters; an independent restricted host is a separate decision.

### Template workflow coverage

- `CreatorDraftTests`: complete templates, immutable drafts, content changes,
  path and link rejection, bounded parameters and cancellation.
- `CreatorPublisherTests`: real import, stable identity, failure and cancellation
  rollback, restart from unconfirmed installation (including import before the
  journal advances), idempotent recovery and preserving external edits.
- `CreatorPreviewTests`: real offscreen WKWebView, painted canvas, property
  updates, pause/resize, request blocking with a loopback positive control,
  resource/capture/native-message rejection, snapshot immutability, stop and a
  preview-to-import-to-installed-host round trip.
- `LockScreenWallpaperServiceTests.testCreatorPrototypeCannotDowngradeIntoNativeFileHost`:
  both native publication modes refuse the unsupported creator runtime using
  temporary stores and injected desktop actions.

The 2026-11-10 targeted run passed 113, failed 0 and skipped the 3 exploratory
probes. The full gate passed 687 Python tests and 4,749 native tests, with no
failures and 69 native skips: 3 creator probes, 62 opt-in media/device tests,
3 live Steam tests and 1 reference-render job. Of the S0 cases themselves,
26 passed and 3 were skipped. Enabling the exploratory command above reproduced
all 3 failures; routine-gate success does not supersede those findings.
The full run also recorded a main-thread runtime warning in the existing
`AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`.

No visible desktop, actual audio capture, battery measurement, arbitrary-code
watchdog, full multi-display behavior or model generation is implied by a
passing offscreen run.
