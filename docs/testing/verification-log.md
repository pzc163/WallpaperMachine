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

## 2026-11-12 — Creator long generation, connection testing and actionable diagnostics

- Implemented separate response/content/idle/total deadlines, optional per-profile limits and scoped Kimi K3 low/high/max reasoning effort; old optional-field encodings remain readable.
- Targeted final integration: 93 passed, 0 failed; documentation/localization checks: 28 passed.
- python3 scripts/test.py: 724 Python tests passed; native 5140 passed, 0 failed, 69 skipped. Live model, benchmark, soak and network opt-ins disabled.
- Three main-thread runtime warnings arose in unchanged AppUpdate, LockScreenWebMPlayer and WebMFilteredVideoSink tests; no Creator warning or failure.
- Real offscreen WebKit checked structured runtime/source diagnostics and full revalidation without another model call. Opaque-frame redaction remains explicitly unavailable rather than guessed.
- No personal model Keychain, visible app, installed app or real desktop operation. Physical macOS 15 and real long model generation remain manual acceptance items.

## 2026-11-12 — Creator cloud/local connection isolation

Separate cloud provider and local/LAN editors, draft identities and credential namespaces; preserve legacy records without UI Keychain access.

- Targeted CreatorConnectionIsolationTests: 5 passed; CreatorConnectionDraftsTests: 7 passed, including six-language wide/narrow offscreen form assertions and consecutive custom connection creation.
- python3 scripts/test.py: 724 Python checks; final 5121 native passed, 0 failed, 69 conditional skips, 119s; 2 runtime warnings.
- An earlier full run hit Cannot open file in the unchanged WebWallpaperPageTests refused/replaced navigation case; that suite passed 10/10 alone and the final full gate passed. No navigation code or assertions were relaxed.
- No real LLM requests, personal Keychain reads/writes, visible UI, installed-app restart or desktop changes. macOS 15 visible-device acceptance remains manual.

## 2026-11-12 — S5.2 provider center, single stage and offline media

- Full gate: python3 scripts/test.py — 724 Python checks; 5,109 native passed, 0 failed, 69 skipped (155s). Initial three failures repaired and targeted rerun passed.
- Media/engines: 15 native master captures; MOV and VP9 WebM decode, Range, pause/resume, asset digest, archive, opt-in thumbnail and parameter boundaries verified.
- Regression: v1/v2 golden bytes, code sandbox attack probes, immutable history and publisher recovery retained. Last focused regressions: 39 + 26 passed.
- Docs/localization: 28 checks passed; six UI languages and four READMEs updated. Offline Three pin check passed; Debug license closure 179, zero incompatible/unknown.
- No real provider calls, personal model Keychain, visible production app, desktop application or install. macOS 15 hardware, multi-display/energy and external provider compatibility remain manual acceptance.

## 2026-11-11 — S5.2 single stage, source editor and hot parameter publication

- Added a single aspect-controlled stage, editable source with Command-R, a conversation drawer and fixed inspector save/apply actions; localized all added controls in six languages.
- CreatorHotEditingTests: 4 passed, including same-page parameter capture, immutable history, invalid shader rollback and real RGBA16F / forced RGBA8 fallback.
- CreatorEngineTests, CreatorMasterTests, CreatorEngineAcceptanceTests, CreatorArtifactTests, CreatorGalleryTests, CreatorControlsTests and CreatorPanelTests passed in targeted batches.
- CreatorModelSettingsTests: both domain tests passed; final six-language expanded/collapsed and narrow-layout case passed 1/1 after fixing inherited accessibility identifiers.
- Old shader-v1 bytes retained. Nine masters rendered and animated offscreen; no visible UI, desktop or model API calls.
- Catalog and panel localization checks passed (8 and 9); documentation links passed (11). Static/Rust license inventory passed 178 entries; dynamic libraries explicitly deferred to package verification.
- Full routine gate and Release remain pending the S5.2 media-engine stage.

## 2026-11-11 — S5.2 provider center and shared model selection

- Added 11 cloud presets, local/custom groups, enabled models per credential-owning Profile, offline LobeHub 1.102.0 SVG assets and complete MIT notices.
- Targeted CreatorProviderCenterTests, CreatorSettingsStoreTests, ProviderCredentialStoreTests and CreatorPanelTests: 36 passed, 0 failed, 0 skipped.
- Localization catalogs: 8 passed; panel localization: 9 passed; documentation links: 11 passed.
- First sandboxed build could not discover the installed Metal toolchain; retry in the normal build environment passed. No toolchain installation or system setting change.
- No real model calls, personal credential reads, visible UI or desktop changes. Full gate and Release follow completion of S5.2.

## 2026-11-11 — S5.1 offline engines and nine master artworks

Native Shader/Three shells, an offline pinned library, declarative parameters and a native master gallery; no visible application, live model or desktop changes.

- Targeted phases: 28 + 17 foundation/store checks; 25 engine checks and 5 after uniform caching; 35 gallery/master checks; 5 final lifecycle/protocol/timeout acceptance checks passed.
- python3 scripts/test.py — exit 0; script checks passed; native 5,088 passed, 0 failed, 69 opt-in checks skipped of 5,157, 127 seconds.
- Nine masters rendered real offscreen JPEGs and passed animation, paused parameter changes, portrait resume, bounded frame scheduling and stop checks. Visual snapshots were reviewed; no placeholder substitutes.
- Three runtime main-thread warnings attributed to VideoFormatSupportTests, AppUpdateTests and LockScreenWebMPlayerTests; each passed, no source location in the issue records.
- Skipped: real paid model traffic, new-engine long soak, visible desktop, multi-display sleep, energy measurement and physical macOS 15. Native WebGL2 remains required; WebKit supervision is not an audit of arbitrary hostile code.

## 2026-11-11 — Creator streaming thoughts and verified artifacts

- Added session-only, bounded and credential-redacted model thinking/source streams, six-language artifact tabs, and publication-validated embedded WebKit previews. Legacy JSON source is checked again after decoding for credential leakage.
- Targeted stream/artifact/panel/composer suites: 31 passed; follow-up revision/stream/artifact regression suite: 25 passed; final native-output/artifact suite: 11 passed, all with zero failures.
- Final python3 scripts/test.py: 720 Python checks; 5066 native passed, 0 failed, 69 conditional skips; two system API main-thread runtime warnings.
- Earlier full runs exposed an obsolete token-limit fixture (corrected), a transient GPU energy-counter threshold failure (13 isolated checks passed without threshold changes), and a replaced-navigation WebKit file-open failure (10 isolated checks passed unchanged). Final full gate passed unchanged after these investigations.
- Document links, generated project and six-language catalogs checked. Test model traffic used Mock URLProtocol; memory credentials and offscreen WebKit only. Live models, benchmark, soak and visible UI/device acceptance were not run.
- No personal model Keychain, production app, real wallpaper, main/latest update, Rust or renderer changes. Physical macOS 15 LAN authorization, visible UI, multi-display, sleep and full-process energy remain device acceptance work.

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
