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

## 2026-11-11 — Creator native output limits and raw HTML contract

- Protocol/repair/code targeted run: 56 passed; two new test-fixture assertions corrected. Follow-up LLMNativeOutputTests and CreatorModelSettingsTests: 9 passed, 0 failed.
- 128K explicit request -> context fallback -> usage-option fallback -> 70 KiB raw HTML -> offscreen validation/poster passes in exactly three attempts without content-repair permission.
- Native maximum omits optional ceilings; Anthropic retains required max_tokens. Legacy profile encoding and immutable packages stay readable; 256 KiB source and 32 MiB wire limits are independent.
- Document links and panel localization checks passed. No live API, real credentials or desktop actions. Full gate remains for the final stage.

## 2026-11-11 — Creator editable LAN connection drafts

- Targeted: LLMConnectionUXTests, ProviderProfileTests, CreatorModelSettingsTests — 14 passed, 0 failed, 0 skipped.
- Local discovery uses the unsaved endpoint and optional memory key; invalid unrelated fields do not block it. Six-language native purpose text and ATS CIDR contract checked.
- No real LAN/API, personal Keychain or visible desktop actions. Physical macOS 15 LAN privacy prompt remains manual; full routine gate follows the remaining stages.

## 2026-11-11 — Creator native composer and connection preview gate

- Workspace/controller/settings targeted suite: 29 passed; expanded composer and native growth/scrolling suite: 5 passed. Six languages and compact layouts tested offscreen.
- Full python3 scripts/test.py: 720 Python checks, 5048 native passed, 0 failed, 69 skipped; 2 runtime warnings. First run exposed two old deadline assertions; updated contract checks and full rerun passed.
- No live API, personal model Keychain, visible window, production app or desktop access. Physical macOS 15/LAN privacy, visible IME/UX and hardware acceptance remain manual.
- Feature branch only; Release and Ad-hoc macOS 15 packaging requested. Package-specific signatures, dependency minima and hash are attached to creator-ux-preview-20261111, outside the source verification record.

## 2026-11-11 — Creator streaming deadlines and progress

- Three-protocol codec, transport, bounded repair and code workflow checks: 53 passed, 0 failed. Final response-header/idle boundary rerun: 12 passed, 0 failed.
- Added independent first-response/idle/total deadlines, redacted phase/count updates, and bounded non-stream negotiation using the existing ledger. Documentation (11), localization catalog (8) and panel localization (9) checks passed.
- Only deterministic Mock flows and offscreen WebKit; no real APIs, personal Keychain, visible windows or desktop changes. Full routine gate remains scheduled after workspace UX.

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
