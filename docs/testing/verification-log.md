# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-11-10 — Creator S1.3 structured parameter generation

S1.3 catalog-derived prompts, strict parameter validation and immutable native drafts; see [implementation and boundaries](../features/creator-generation.md). S1.2 rollback commit `e3a61f55` was made before implementation; S1.3 remains uncommitted.

- `python3 scripts/test.py --only CreatorGeneratorTests CreatorOutputValidatorTests CreatorPromptBuilderTests CreatorDraftTests CreatorRevisionStoreTests CreatorStorageFormatTests CreatorRuntimeRegistryTests CreatorTemplateCatalogTests LLMCodecTests LLMProviderTests` — exit 0; final targeted 98 passed, 0 failed/skipped; earlier successful subsets 47 and 95. An initial new-parser compile error was fixed before these passes.
- `python3 scripts/test.py` — exit 0, run once: 687 Python tests / 32 modules; native 4,888 passed, 0 failed, 69 skipped of 4,957. All 28 additions passed. Existing rustup PATH was used; no installation.
- Skipped: 3 known S0 unrestricted-code probes, 62 opt-in media/device tests, 3 live Steam tests, 1 reference render; S4 remains closed.
- Two existing main-thread runtime warnings: AppUpdate signature-copy check and VideoFormatSupport changed-file check; both passed. No new/modified Creator/LLM compiler warning; other existing targeted-build warnings remain.
- Offline three-codec × three-template streams, explicit-base history, malformed/policy output, cancellation, Profile/base changes, budget/usage, metadata tampering and both commit-boundary interruptions covered with MemoryKeychain and all-URL Mock interception.
- `python3 scripts/tests/test_doc_links.py` — exit 0, 11 passed; `git diff --check` passed. Planning mirrors, 28 tested-file hashes, frozen generator/assertion bytes and task scope checked.
- Static evidence only: runtime/posterCapture notChecked. No paid/live provider call, personal Keychain, new UI, desktop operation, Release build, install or push. No parameter auto-repair; S1.4/S4 untouched.
- Raw test bundles/logs are disposable and removed after retaining the stage report and machine-readable summary; no other task artifacts are cleaned.

## 2026-11-10 — Creator S1.2 profile-bound model transport and three codecs

S1.2 adds profile-bound native model connections after local rollback commit `37f2c603`; see [connection implementation](../features/creator-llm.md). This stage has no creator UI or live model/Keychain test.

- Targeted `python3 scripts/test.py --only SSEParserTests --only LLMCodecTests --only ProviderCredentialStoreTests --only LLMProviderTests --only LLMStreamTransportTests --only ProviderProfileTests --only CreatorSettingsStoreTests --only CreatorRevisionStoreTests --only CreatorStorageFormatTests` — exit 0; 87 passed, 0 failed, 0 skipped. All 49 new tests pass.
- Earlier targeted integration run: 74 passed, 1 failed because URLSession moved the request body into httpBodyStream; corrected the offline fixture capture. Final runs also cover CRLF raw-byte limits at every split.
- One full `python3 scripts/test.py` — exit 0; 687 Python tests across 32 modules; 4,860 native passed, 0 failed, 69 skipped of 4,929 in 150 seconds. No full-gate retry.
- Skips: 3 known S0 unrestricted-code probes, 62 opt-in media/device tests, 3 live Steam tests, 1 reference render. S4 remains closed.
- Two existing main-thread runtime warnings in AppUpdate signature verification and VideoFormatSupport cache tests; those tests pass and their production code is unchanged. No new LLM/Creator compiler warning.
- `python3 scripts/tests/test_doc_links.py` and `git diff --check` — exit 0. Plans and implementation docs updated; frozen generators and golden digest assertions unchanged.
- Model traffic is intercepted for every URL by Mock URLProtocol; credentials use injected MemoryKeychain. No paid/real provider calls, personal Keychain access, desktop/UI operations, installation or Release build.
- Real endpoint/TLS/proxy/Keychain-permission interoperability is unverified. Output reservations are not billing limits; S1.3 strict schema and S1.4 UI/cover/publication remain pending. S1.2 changes remain uncommitted; no push.

## 2026-11-10 — Creator settings and provider profiles

S1.1 settings/profile metadata supplement; details and limits are in [creator revisions](../features/creator-revisions.md). Provider transport, Keychain and UI remain deferred.

- Saved the previously verified tree as local baseline `f7d6168f` on `feat/ai-creator`; no push. The supplement remains uncommitted.
- Added versioned nonsecret `CreatorSettings`/`ProviderProfile` records, actor/file-lock atomic updates, revision conflict checks and configuration fencing.
- `python3 scripts/test.py --only CreatorSettingsStoreTests --only ProviderProfileTests --only CreatorRevisionStoreTests --only CreatorStorageFormatTests --only CreatorRuntimeRegistryTests --only CreatorDraftTests --only CreatorPublisherTests --only CreatorPreviewTests --only CreatorTemplateCatalogTests --only CreatorTemplateRenderingTests --only ImportTests --only WallpaperPlaybackPreflightTests --only LockScreenWallpaperServiceTests`: final 231 passed, 0 failed, 3 skipped; initial run 230 passed, 3 skipped.
- First `python3 scripts/test.py`: Python 687 passed; native 4,809 passed, 1 failed, 69 skipped. Preset pixel reproducibility raced native state replay; a controlled 200 ms delay reproduced it before the test-only acknowledgement fix. No kernel or golden digest changes.
- Full-gate retry after the fix: Python 687 passed (32 modules); native 4,811 passed, 0 failed, 69 skipped (4,880 total). All 16 metadata additions and the delayed-replay regression passed. No further full-gate run.
- Skips: 3 known S0 unrestricted-code probes, 62 opt-in media/device tests, 3 live Steam tests, 1 reference rendering job. Runtime main-thread warnings: AppUpdate unsigned-copy check, VideoFormatSupport changed-file cache check, WebMOpening VP9 opening check; all passed, production code untouched.
- `python3 scripts/tests/test_doc_links.py`: 11 passed. Documentation/mirror/frozen-source checks: 36 passed. `git diff --check`: passed. 02/03/05 and their output copies are synchronized.
- No external model/Keychain access, desktop/UI run, Release build or install. S1.1 recovery is a service API; Creator settings/history backup/move integration, v2 poster generation/publication and S4 isolation remain future work.

## 2026-11-10 — Creator S1.1 immutable revision storage

S1.1 adds immutable creator revision storage, content-bound structural reports, job cancellation/recovery and strict package routing. No UI, model API, cover capture or desktop changes.

- Safety baseline: local `feat/ai-creator` commit `e3a190c613ce2a95cff2816876b1c94319415f3f`; S1.1 remains uncommitted; no push.
- `python3 scripts/test.py --only CreatorRevisionStoreTests --only CreatorStorageFormatTests --only CreatorRuntimeRegistryTests --only CreatorDraftTests --only CreatorPublisherTests --only CreatorPreviewTests --only CreatorTemplateCatalogTests --only CreatorTemplateRenderingTests --only ImportTests --only WallpaperPlaybackPreflightTests --only LockScreenWallpaperServiceTests` — exit 0; 214 passed, 0 failed, 3 known S0 probe skips.
- `python3 scripts/test.py` — one final full run, exit 0; Python 687 passed (32 modules); native 4,794 passed, 0 failed, 69 skipped of 4,863. All 27 new cases passed.
- Skips: 3 unresolved S0 unrestricted-source probes, 62 opt-in media/device cases, 3 live Steam cases, 1 reference-render case.
- Two existing main-thread runtime warnings: `VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()` and `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`; source locations absent.
- Legacy generators and golden digest assertions are unchanged. Tests use temporary stores, synthetic JPEGs and an unattached WKWebView; no visible window or desktop capture.
- Structural reports explicitly leave runtime/poster capture unchecked; v2 publication, model transport, UI and S4 remain pending. Creator history is not yet in backup/storage-move transactions.
- Rust/renderer checks and Release build not run: no changes in those domains and no application delivery requested. No install, push or wallpaper activation.

## 2026-11-10 — Creator S1.0 parameterized templates

S1.0 adds native-owned parameterized templates on the existing S0 host; no model API or desktop activation.

- `python3 scripts/test.py --only CreatorTemplateCatalogTests --only CreatorTemplateRenderingTests --only CreatorDraftTests --only CreatorPublisherTests --only CreatorPreviewTests` — exit 0; 43 passed, 0 failed, 3 known S0 unrestricted-source probes skipped.
- `python3 scripts/test.py` — exit 0; run once after final implementation; 687 Python tests passed in 32 modules; native 4,767 passed, 0 failed, 69 skipped of 4,836.
- Native skips: 3 S0 probes, 62 opt-in media/device checks, 3 live Steam checks, 1 reference-render job; S4 remains blocked by its existing gates.
- Two runtime main-thread warnings: unchanged `VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()` and `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`; no source locations reported.
- `python3 scripts/tests/test_localization_catalogs.py`, `python3 scripts/tests/test_doc_links.py`, `git diff --check` — exit 0; 8 and 11 Python checks respectively.
- 18 new tests cover all 32 parameter dimensions, six presets, actual offscreen pixels, aggregate resource budgets, cadence/lifecycle, strict reconstruction and legacy recovery.
- Real-clock offscreen first paint/edits passed; animation/FPS use a controlled clock in WebKit. Visible desktop quality, frame time, energy and arbitrary-code termination remain unverified. No Release build, install, commit or push.

## 2026-11-10 — Creator S0 trusted-template prototype

Creator S0 validates a service-level trusted-template workflow. Arbitrary-source isolation remains blocked by reproducible probes; see [the feature record](../features/creator-s0.md).

- Baseline: `7025ba39f4c92f6c1af221aa3060c62aefb0e2a2`; macOS 27.2 (26B123), arm64; no LLM, creator UI or Release delivery.
- `PATH=/opt/homebrew/opt/rustup/bin:$PATH python3 scripts/build.py --renderer-only` — exit 0; generated prerequisite renderer/bridge outputs without changing their source.
- `python3 scripts/test.py --only CreatorDraftTests --only CreatorPublisherTests --only CreatorPreviewTests --only WebWallpaperPageTests --only WebWallpaperPreviewSurfaceTests --only WallpaperPlaybackPreflightTests --only ImportTests --only LockScreenWallpaperServiceTests/testCreatorPrototypeCannotDowngradeIntoNativeFileHost` — exit 0; 113 passed, 0 failed, 3 known exploratory skips.
- `PATH=/opt/homebrew/opt/rustup/bin:$PATH python3 scripts/test.py` — exit 0; 687 Python tests passed; native 4,749 passed, 0 failed, 69 skipped. Run once at the final gate.
- Skips: 3 known-failing creator probes, 62 opt-in media/device tests, 3 live Steam tests, 1 reference-render job. The S0 cases themselves were 26 passed, 3 skipped.
- `TEST_RUNNER_CREATOR_UNRESTRICTED_PROBES=1 python3 scripts/test.py --only CreatorPreviewTests/testDownloadLinksAreBlockedBeforeConnecting --only CreatorPreviewTests/testEventSourceIsBlockedBeforeConnecting --only CreatorPreviewTests/testMediaIsBlockedBeforeConnecting` — exit 65; all 3 failures reproduced, not counted as passes.
- Real offscreen WebKit and real importer exercised with temporary bundles: properties, stop, snapshot validation, cancellation and unconfirmed-publication recovery. Actual desktop switching/recovery, devices, arbitrary-code termination, power-loss recovery and performance remain unverified.
- Full gate runtime warning: existing `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()` reported a main-thread call; no source location supplied.
- `git diff --check` and new-document relative-link checks passed; Xcode project regenerated by XcodeGen. Durable contract and known gaps are in the feature record; disposable evidence is not committed.

## 2026-11-10 — Library tile menu, drop to import, keyboard and batch favorites; service fixes

Installed gains a right-click menu on tiles (the inspector's More actions list, shared as WallpaperActionItems), files dropped on the page import, Command-Delete and Command-Return on the grid, File › Import… and Refresh Library, and a favorite tool for the ticked selection. The same change fixes six service defects (unreadable saved entries no longer erase their neighbours; an automatic command replacing a queued rule or Focus change no longer marks it handled; a day and night display keeps a manual choice across a relaunch; a shuffle round ends without a wallpaper that keeps failing; a stale Steam request no longer signs out a newer session; equal day and night start times are refused), adds feedback where actions were silent, and gathers the renderer's leftover material constants into one log line per scene.

- `python3 scripts/test.py` — exit 0; 4789 tests: 4723 passed, 0 failed, 66 skipped (the first run failed two tests that asserted the old batch-limit error; both were updated and the gate rerun)
- `python3 scripts/check_renderer.py` — exit 0; generated scenes pixel-equal pooled and isolated, 0 reload-cycle diagnostics; the local-corpus tests (particle corpus, local projects through the native backend, poster pictures, energy, corpus stamps, a local clip) skipped: no corpus configured
- New unit tests: PreservedJSONTests; unreadable entries in WallpaperAutomationStoreTests, PlaylistStoreTests, WallpaperCollectionStoreTests and PlaybackPreferencesTests; queue outcomes in UserCommandQueueTests; a Focus change replaced by a reload in WallpaperAutomationSchedulerTests; relaunch and shuffle rounds in PlaylistSchedulerTests; the Steam session in WorkshopSourceTests
- New panel tests: add-to-playlist and refresh notices, the unreadable-library state, the failed-still mark (offscreen render), drop import, the favorite tool, Command-Delete and Command-Return on the hosted grid, equal start times, preset and batch-limit refusals
- Renderer: two gtest cases for UnmatchedConstantTally in material_constant_behavior_test; no frame output changed, so no Wallpaper Engine reference comparison was made
- Not exercised: the tile's context menu, the drop outline and a real Finder drag, and the File menu items with their shortcuts in a real window. They need desktop control, which was not authorized; the menu's item rules are InspectorPolicy's existing tests, and the drop and menu actions are covered through the model
- Not rebuilt: no Release build was made, so the delivered app does not contain these changes
- Runtime warnings in the result bundle (2, main-thread call) come from AppUpdateTests and WebMOpeningTests, which this change does not touch

## 2026-11-09 — Web wallpaper submitted background for Stage Manager

- The desktop web container now submits one opaque black 1×1 Metal frame per backing layer and retains it through resize and page suspension, with no recurring GPU submission or rendering loop. The bounded allocation trade-off was approved; battery impact was not measured.
- On the Dell display, the user reported that a submitted surface kept Belle smooth, removing it or replacing it with an empty Metal queue brought the freeze back, and using the submitted surface as the existing black background looked normal and stayed smooth.
- The earlier tag-only Release candidate and native backing-flattening override failed the visible Stage Manager check. The override is removed; the existing transition tag remains alongside the submitted background.
- `python3 scripts/test.py --only WebWallpaperWindowCompositionTests` — before the Metal implementation, 3 passed and 2 new regressions failed; final run: 7 passed, 0 failed, 0 skipped. Coverage includes a real submitted frame, resize, suspension/resume and the no-Metal fallback.
- `python3 scripts/test.py` — passed: Python checks and XcodeGen succeeded; native suite: 4,698 passed, 0 failed, 66 skipped. Three unrelated runtime warnings concerned main-thread use in video and app-update tests.
- `python3 scripts/build.py --renderer-only` rebuilt current upstream dependencies; `python3 scripts/build.py --swift-only --configuration Release` passed. No renderer source changes were made by this fix.
- The clean Release app was restarted with the original covered-desktop preference restored. Runtime inspection confirmed attached web views and submitted 1×1 Metal backgrounds on both the Dell and built-in displays, with no diagnostic layer or runtime patch.
- The additional clean-build Stage Manager and Mission Control visual check was requested but remains unconfirmed. The accepted smoothness result above is from the working prototype, not a claimed final-build visual observation.
- Wallpaper Engine reference-frame comparison and measured power consumption were not performed; this change addresses host-window presentation rather than wallpaper content rendering.

## 2026-11-09 — Issue #177 rebuilt candidate rejected

- The user tested the Release app from local commit 5cb12719 and reported that the issue was not fixed. Its prior passing gate and manual flag-toggle trials do not establish a fix.
- Read-only process inspection confirmed the running executable was build/Build/Products/Release/WallpaperMachine.app/Contents/MacOS/WallpaperMachine.
- WindowServer readback acknowledged tag 55 on both the Built-in Retina Display and DELL U2725QE web windows. The debugger detached after inspection; no window policy was changed.
- The built-in window contained its live web view. The Dell window contained an NSImageView suspension poster; session logs recorded repeated presentation suspend/resume decisions for display 3.
- The foreground-app rule was Keep running, covered-desktop behavior was the default Pause, and the power source was External. The relationship between this pause and the reported stutter remains unconfirmed; a controlled manual retest with the coverage rule disabled is pending authorization.
- No new fix, desktop automation, app restart or settings mutation was performed. The candidate remains local and must not be treated as resolving #177.

## 2026-11-09 — Web transition composition final review (#177)

- Reviewed the web-window transition policy and live-resize restoration against current main; retained the general fix without wallpaper-specific behavior or per-frame work.
- python3 scripts/test.py --only WebWallpaperWindowCompositionTests: 3 passed, 0 failed, 0 skipped; reads WindowServer policy on unordered windows and exercises an AppKit live-resize cycle.
- python3 scripts/test.py: all 32 Python suites passed; 4,667 native passed, 0 failed, 66 skipped. The skipped asset, media, network and desktop-dependent checks are not passing coverage.
- One runtime warning in AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy: a method called on the main thread may cause unresponsiveness; unrelated to web transition composition.
- python3 scripts/build.py --swift-only --configuration Release: passed; built build/Build/Products/Release/WallpaperMachine.app. Existing linker deployment-target warnings remain.
- Prior same-window Belle manual trials recorded smooth playback with tag 55 set, stutter after clearing it, and smooth playback after setting it again; the prior rebuilt app readback also showed the flag set automatically.
- Final rebuilt-app visual acceptance remains unconfirmed. No desktop automation, wallpaper changes or app restart were performed during this final review. No valid Wallpaper Engine frame comparison is available.
