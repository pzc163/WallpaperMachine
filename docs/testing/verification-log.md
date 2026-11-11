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

## 2026-11-11 — Creator S2.3 final acceptance closeout

S2.3 final closeout; durable evidence: [acceptance](../features/creator-acceptance.md) and [redacted metrics](creator-s23-results.json).

- Reviewed existing live smoke (1 passed), fixed-model/schema benchmark (30/30 first-pass, 100% final) and three-page 1800-second WebKit soak (540 responsive samples, zero observed external attempts/terminations); no new live requests.
- `python3 scripts/test.py` once: exit 0; 708 Python and 4,994 native passed, 0 failed, 72 skipped of 5,066 native tests; all opt-in flags cleared.
- Skips: 62 media/device, 3 Steam network, 1 reference render, 3 S0 known-failing probes, and smoke/benchmark/long-soak one each.
- Warnings: 6 dependency deployment-target link warnings, 1 AppIntents extraction notice, 3 main-thread warnings in existing tests; all affected tests passed, warnings not fixed here.
- Final document/link and catalog checks passed; three plan mirrors agree; 3,720 non-document files stayed unchanged across the full gate.
- No Rust/renderer/FFI changes; no extra kernel gate or Release build. No personal Keychain, UI automation, installation or desktop changes.
- Archived aggregates only; removed all task test logs/results/reports and confirmed temporary test roots. S3 device/visual acceptance awaits authorization; S4 remains disabled.

## 2026-11-11 — Creator prompt and structured-output compatibility

- Native prompt uses flat scalar output, an empty properties default and a catalog-generated clock example; full validator/export schema unchanged.
- OpenAI automatic prefers native json_schema; required/json_object, schema/strict and disabled/prompt-only are explicit. Downgrade uses the same request/token budget.
- `python3 scripts/test.py --only LLMCodecTests --only LLMProviderTests --only LLMStreamTransportTests --only ProviderProfileTests --only ProviderCredentialStoreTests --only CreatorPromptBuilderTests --only CreatorOutputValidatorTests --only CreatorGeneratorTests --only CreatorRepairTests --only CreatorWorkspaceTests --only CreatorBenchmarkTests --serial` — exit 0; 120 passed, 0 failed, 0 skipped. Mock model streams and real offscreen validation only.
- `python3 -B scripts/tests/test_creator_live_smoke.py` — 9 passed; `python3 -B scripts/tests/test_creator_acceptance.py` — 8 passed; synthetic credentials and loopback IPC only.
- `python3 -B scripts/tests/test_doc_links.py` — 11 passed; `git diff --check` — clean.
- Compiler log: 339 warning lines, none attributed to touched files; zero XCTest runtime warnings.
- Three pre-existing benchmark artifacts cleaned. No live model request, personal Keychain, visible UI, desktop change, full gate, commit or push; requested targeted scope only.
- Real-model quality/grammar acceptance remains unmeasured after this patch; single live smoke still has requestBudget=1.

## 2026-11-10 — Creator S2.3 headless acceptance and benchmark harnesses

S2.3 — headless recovery, publication playback gate, credential-echo rejection and acceptance harnesses.

- S2.2 baseline committed locally as `35594fb9` on `feat/ai-creator`; no push. S2.3 remains uncommitted.
- Final targeted: 52 passed, 0 failed, 3 existing S0 probes skipped; broader targeted: 105 passed, 0 failed, 5 skipped.
- `python3 scripts/test.py` — one full run, exit 0; 701 Python tests; native 4,978 passed, 0 failed, 72 skipped (5,050 total).
- New tests: 16 native + 6 Python passed; 1,246 source/test/config hashes unchanged across the full gate; 9 frozen sources preserved.
- Skip groups: 62 media/device, 3 Steam network, 1 reference renderer, 3 S0 unrestricted probes, 3 creator live/benchmark/soak opt-ins.
- Two main-thread warnings in VideoFormatSupportTests and AppUpdateTests; both tests passed, warnings not claimed fixed.
- Mock 10×3: first 60%, final 90%, 48 requests, 24 unknown usages; not a live quality result. Real WK short soak 0.825 s, not 30 minutes.
- AC-01–14 matrix, exact commands and limits: [creator-acceptance.md](../features/creator-acceptance.md). S3 device/UI and S4 isolation remain open.
- No live API, personal Keychain, visible UI, desktop change, Release build or installation; structured evidence retained before cleaning this task's logs/results.

## 2026-11-10 — Native creator workspace and model settings (S2.2)

Added the native AI Creator tab and model settings, with explicit generate/save/apply actions, trusted previews and controller-start recovery. [Feature and boundaries](../features/creator-workspace.md).

- S2.1 baseline committed locally as `29cd3086` on `feat/ai-creator`; S2.2 remains uncommitted, no push or install.
- Targeted Creator/shell/settings/image/backup run: 211 passed, zero failed, three S0 skips. Storage/move/backup: 71 passed; deletion/recovery: 38 passed; final controller suite: 11 passed.
- Final `python3 scripts/test.py`: 695 Python tests and 4,962 native tests passed, zero failures, 70 skips. All 27 new tests passed; source/test/generated-project hashes were unchanged during the gate.
- Gate attempts: first interrupted for a preview-session lifecycle correction (exit 73, not accepted as passed); second failed in an unchanged WebKit navigation replacement test; isolated recheck passed, then the final full recheck passed without source/assertion/threshold changes.
- The WebKit failure reported `Cannot open file`; cause unresolved. Final build had seven existing linker/metadata warning lines and two main-thread runtime warnings recorded in passing existing tests.
- Skips: three S0 unrestricted probes, 62 opt-in media/device checks, three Steam network checks, one reference job, one creator live smoke. No real provider requests, personal Keychain or desktop actions.
- Legacy v1 golden bytes and v2 validation stay intact. Draft display names are separate workspace metadata; draft deletion preserves installed bytes and runtime policy.
- Existing backup/restore/storage moves explicitly refuse Creator data, with a shared lease and durable first-write marker. Full Creator migration/backup is not implemented.
- Six-language keys and offscreen narrow layouts checked; visible appearance, VoiceOver, actual preview-window interaction, real providers/Keychain and desktop activation remain unverified. S4 remains closed; no Release/long-run power test.
- Final documentation/link/scope checks and cleanup retain structured test results; disposable test logs and result bundles are removed after collection.

## 2026-11-10 — Creator S2.1 bounded repair, conversation budget and rollback

[S2.1 bounded repair and iteration](../features/creator-iteration.md) implements FR-07/08 and AC-02/03/07 service behavior; no UI or live desktop.

- Baseline: checked the user's prior CreatorLiveSmokeTests (1 passed, 0 failed, 0 skipped; protocol/model user-reported); removed only its temporary log/result and committed S1.4 locally as `8c1480b0` on `feat/ai-creator`; clean before S2.1, no push.
- Targeted `python3 scripts/test.py --only <Creator/LLM classes>`: exit 0, 210 passed, 0 failed, 4 skipped; all 28 new S2.1 cases passed. Local Mock URLProtocol and MemoryKeychain; successful repairs use real offscreen WebKit/JPEG.
- First full `python3 scripts/test.py`: exit 65; 695 Python passed; native 4,934 passed, 1 failed, 70 skipped. Unchanged GPU energy-counter test measured about 0.87 mW against a 10 mW lower bound.
- Isolated `python3 scripts/test.py --only EnergyUsageMonitorTests/testKernelCountersForThisProcessAdvanceWithGPUWork`: exit 0, 1 passed, 0 failed/skipped; no source or threshold changes. Root cause of the sampling variation remains unconfirmed.
- Failure-only full-gate retry: exit 0; 695 Python (33 modules), native 4,935 passed, 0 failed, 70 skipped (5,005 total). Exactly two full runs; source/test/generated-project SHA-256 identical between runs and after verification.
- Skips: 3 S0 unrestricted probes, 62 media/device opt-ins, 3 Steam network tests, 1 reference job and 1 Creator live smoke. No real-provider request, personal Keychain access, desktop operation or Release/install this stage.
- Final compiler-warning lines: targeted 28, full 0, none in changed sources/tests. Runtime warnings in passing untouched tests: `WebMOpeningTests.testAVp9FileOpensWithItsFormatSizeAndLength()`, `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`, `VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`.
- Updated 02/03/05, feature owners and index; final documentation/source/scope checks and links recorded in the S2.1 report. Task-only artifacts removed after preserving counts; S2.1 remains uncommitted and stops here.

## 2026-11-10 — Creator S1.4 native runtime, sealed publication and opt-in smoke

[S1.4 native publication](../features/creator-publication.md) connects template generation, real unattached WebKit snapshots, immutable four-file evidence and recoverable library import. S1.3 was committed locally as `ac28cf34`; S1.4 remains uncommitted, with no push or desktop change.

- `python3 scripts/test.py --only CreatorPublicationTests --only CreatorPosterTests --only CreatorOrchestratorTests --only CreatorLiveSmokeTests --only CreatorGeneratorTests --only CreatorDraftTests --only CreatorRuntimeRegistryTests --only CreatorPublisherTests --only CreatorRevisionStoreTests --only CreatorStorageFormatTests --only CreatorTemplateCatalogTests --only CreatorTemplateRenderingTests --only CreatorPreviewTests --only ImportTests --only WallpaperImportStagingTests --only WebWallpaperPreviewSurfaceTests --only LibraryPreviewFetcherTests` — exit 0; 189 passed, 0 failed, 4 skipped.
- `python3 scripts/tests/test_creator_live_smoke.py` and `python3 scripts/tests/test_test.py` — exit 0; 8 and 18 passed, synthetic loopback credentials only.
- `python3 scripts/test.py` — exit 0, once; 695 Python tests in 33 modules; 4,907 native passed, 0 failed, 70 skipped of 4,977. All 19 new routine native tests passed; live smoke skipped.
- Skips: 3 S0 unrestricted probes, 62 opt-in media/device checks, 3 live Steam checks, 1 reference job and 1 creator live test. No real model request, personal Keychain, UI/desktop, Release delivery or S4 validation.
- Four main-thread runtime warnings in passing unchanged AppUpdate, VideoFormatSupport, WebMPlayer and WebMOpening tests; no source locations. The two WebM warnings were additionally observed this run. Full compilation has 28 warning lines outside the changed sources/tests.
- `python3 scripts/tests/test_doc_links.py` — exit 0; 11 passed. Planning mirrors, frozen v1 generators/golden assertions, tested-source hashes, branch/scope and `git diff --check` verified; XcodeGen generated the project.

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
