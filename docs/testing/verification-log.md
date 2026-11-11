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

## 2026-11-11 — Creator connection form and local credential sessions

- Targeted LLMConnectionUXTests, ProviderCredentialStoreTests, CreatorModelSettingsTests and LLMStreamTransportTests: 21 passed, 0 failed, 0 skipped.
- Documentation links (11), panel localization (9) and localization catalog (8) checks passed. Full routine gate follows after all three atomic changes.
- Memory Keychain and Mock URLProtocol only; offscreen six-language form checks. No production app, LAN host, personal Keychain or model API accessed. macOS 15 physical LAN authorization remains a device check.

## 2026-11-11 — S4 offline code creation and developer preview

- Stage 1 commit 8fccf4b9: bounded schema/object/prompt negotiation, LAN endpoints and native success banner; 720 script and 5006 native passed, 72 skipped.
- Stage 2 commit c9ada8b3: versioned WebGL templates, legacy byte reconstruction, native covers and context recovery; 720 script and 5012 native passed, 72 skipped.
- S4: single raw HTML contract, immutable code revisions, three protocol codecs, native snapshot publication and bounded repair/history.
- Opaque sandbox iframe and positive-control network matrix; the original download/EventSource/media probes execute and pass.
- Native process ownership and external deadline: synchronous loop, microtask starvation, bounded memory/log overload, release and coexistence tests passed.
- Cursor and dual-display host tested using inert surfaces/monitor; no visible window or desktop assignment.
- Focused S4 18/18, broader regression 68/68, controller/S4 27/27 passed.
- Full python3 scripts/test.py: 720 script tests and 5034 native passed, 0 failed, 69 skipped; two runtime warnings retained.
- Documentation 11, catalog localization 8 and panel localization 9 checks passed. No live model, personal Keychain or physical S3 operation.
- WebKit SPI availability checked at runtime; GPU hard quotas, macOS 15 hardware, visible quality, sleep and whole-system energy remain separate public acceptance items.

## 2026-11-11 — Versioned WebGL Creator templates

- New template specifications use rendererRevision 3; existing S0 and revision 2 bytes are frozen and checked with golden digests.
- The native catalog retains 10/12/10 parameters, six presets, a 30 FPS paint ceiling and 2073600 pixels. New kernels use simplex flow fields, a dark parallax starfield and measured DOM clock typography.
- Real offscreen WebGL snapshots cover all parameter effects, 144 Hz callback pacing, extreme canvas sizes, heterogeneous clock anchors, actual context loss/restoration and forced no-GPU fallback.
- Native poster and short-soak instrumentation now checks WebGL draws and pixels; capture remains a whole-page WKWebView snapshot.
- Focused suites: 26 passed, 0 failed. Full python3 scripts/test.py: 720 script tests, 5012 native tests passed, 0 failed, 72 native skips.
- No live model, visible application or desktop changes. Physical display quality, macOS 15 hardware, energy and a new 30-minute soak remain unverified; prior soak evidence does not certify the new renderer.

## 2026-11-11 — Creator model negotiation and LAN profiles

- Automatic OpenAI format negotiation is shared by connection probes and creation: schema, JSON object, prompt JSON; each request consumes the same bounded ledger.
- Native validation errors retain allowlisted field details; format negotiation is independent of the maximum two content repairs.
- Local mode accepts strict private IPv4, local IPv6 and mDNS names; origin/configuration credential binding and explicit connection confirmation remain mandatory.
- Connection success banners include actual mode, model and elapsed time in all six app languages; stale or cancelled results cannot restore success.
- Focused native suites: 56 passed, 0 failed. Full python3 scripts/test.py: 720 script tests and 5006 native tests passed, 0 failed, 72 native skips.
- No live API, personal Keychain, visible UI, desktop replacement or hardware acceptance was exercised. S4 remains closed in this commit.

## 2026-11-11 — Creator macOS 15 ad-hoc packaging

- Added explicit ad-hoc Rehearsal mode; production publishing remains gated and notarized by default.
- Package audit now covers all embedded Mach-O files, arm64 architecture, minimum deployment versions and linker-version parsing.
- Final python3 scripts/test.py: 720 script tests and 5000 native tests passed; 0 failed, 72 opt-in skipped, 2 runtime warnings.
- Initial existing WebKit Cannot open file failure passed in isolation and two subsequent complete native gates; runtime source unchanged.
- Local package uses verified identical-version official macOS 15 bottles; all 567 original exports retained and all 8 Mach-O minimums are 15.0.
- DMG mount, deep strict signatures, dependency closure and source-app preservation verified; details in docs/testing/creator-macos15-results.json.
- No Apple notarization, hosted macOS 15 CI run, physical display test, live model request, desktop change or S4 enablement.

## 2026-11-11 — S3 creator JSON mode and native preset controls

- Scope: OpenAI-compatible JSON mode selection, native template presets, six-language strings, typed controller validation and offscreen tests; S4 remains closed.
- Baseline: local feat/ai-creator at 6b2350d8, initially clean. No push or app installation.
- Targeted: python3 scripts/test.py --only CreatorControlsTests --only CreatorModelSettingsTests --only CreatorPanelTests --only CreatorWorkspaceTests recorded 26 passed/1 fixture failure; after supplying the fake library snapshot, --only CreatorControlsTests passed 3/3. The full gate covers all 27 cases.
- python3 scripts/test.py: one final routine run, exit 0; 708 Python passed; native 5,000 passed, 0 failed, 72 skipped, 128s; two runtime warnings.
- Skips: 62 media/device, 3 Steam network, 1 reference, 3 S0 unrestricted, 3 Creator live/benchmark/soak. Real model and device opt-ins were removed from the runner environment.
- Additional checks: localization 17/17, document links 11/11, git diff --check; handbook command syntax and all 66 checklist rows/AC coverage checked.
- Initial build prerequisite: installed Metal toolchain was hidden by a stale xcrun path cache; xcrun --kill-cache restored compiler lookup. No component download.
- No personal Keychain, visible windows, installed-app quit/launch, desktop application, display/sleep changes or network API calls. Release build is requested after this local commit; real S3 visual/device acceptance remains pending.

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
