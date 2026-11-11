# Creator native runtime validation and publication

Subsequent integration: [S2.2 native creator workspace](creator-workspace.md) adds the panel UI, controller-start recovery and explicit backup/move refusal boundaries. Statements below about missing UI/startup wiring describe that earlier stage; its test evidence is historical. S2.1 was committed locally as `29cd3086` before S2.2, without push.

S1.4 connects [parameter generation](creator-generation.md) to real offscreen
WebKit capture, an immutable four-file revision and a recoverable library save.
It implements the service portions of PRD AC-02/07/10/15/16. Per the requested
scope, it adds no creator UI, startup wiring or desktop activation. The verified
S1.3 baseline was committed locally as `ac28cf34` on `feat/ai-creator`; this S1.4
work was committed locally as `8c1480b0` before S2.1. Nothing was pushed or installed.

See the [PRD](../plans/02-creator-prd.md),
[technical contract](../plans/03-creator-technical-plan.md#19-s14-原生运行封闭与发布实施合同)
and [stage plan](../plans/2026-11-10-creator-s1-s4.md).

[S2.1](creator-iteration.md) adds bounded repair and conversation bookkeeping around
this workflow; the S1.4 gate results below remain historical.

## Ownership and flow

| Component | Responsibility |
| --- | --- |
| `CreatorOrchestrator` | New project or explicit old-base generation, capture, seal, publish, cancellation and explicit recovery |
| `CreatorPosterService` | One bounded session in a real unattached WKWebView; initialization, errors, freeze/redraw and whole-page snapshot |
| `CreatorPosterImage` / `CreatorPosterMetadata` | Native nonempty-pixel checks, bounded JPEG encoding and metrics validation |
| `CreatorRuntimeCapture` / `CreatorSeal` | Source-bound in-memory capture and versioned immutable sealing provenance |
| `CreatorRevisionStore.seal` | New sealed child revision and final evidence at the existing atomic index commit point |
| `CreatorPublisher` | Existing import service, durable before/after journal, registry compare-and-swap and rollback |
| `CreatorRuntimeRegistry` | Installed bytes, final report and current host/policy/SDK binding; no v2 compatibility fallback |

The orchestrator request names a saved Profile/configuration, prompt, optional
project and optional base revision. New projects omit both IDs. An existing base
is explicit, never silently replaced with the latest revision. Success returns
the project, render-draft revision, sealed revision and installed directory.
Changing an existing wallpaper keeps its `ai-<project-uuid>` identity and all
history. A successful generation creates two local revisions, with separate
generation/sealing Jobs; sealing consumes no additional model request and carries
the original generation provenance.

Each orchestrator permits at most four active projects and cancels the older
task for the same project. Revision job tokens, current-source checks and file
locks protect late completions. A publication root permits only one transaction;
contention reports busy, without queuing or regenerating. Stage failures expose
fixed codes, not arbitrary model/transport text. A completed draft or sealed
revision survives a later failure; an uncommitted candidate is removed. Recovery
never repeats a model call.

## Real runtime and poster evidence

Capture first loads the structure report and its immutable preview snapshot.
Only a v2 `renderDraft` is eligible. The view remains unattached to any NSWindow;
there is no screen capture, desktop surface, permission prompt or hidden window.
It uses the existing strict scheme, nonpersistent WebKit store and frozen bytes.

Native instrumentation checks complete initial property delivery, fps 30,
pause delivery, loaded fonts and canvas dimensions; errors, unhandled rejections
and CSP violations fail the session without preserving page text. It freezes
the initialized frame and requests a resize redraw before `takeSnapshot`, then
checks state/errors again before encoding. This is deterministic initialization,
not identical JPEG bytes across different wall-clock/animation times.

The page/load/snapshot wait is at most five seconds, without an automatic second
snapshot. Cancellation, failure or timeout stops the surface and invalidates
callbacks. A late answer cannot resume or publish a stopped session. This does
not establish termination of arbitrary noncooperative scripts; S4 stays closed.
Synchronous bounded image encoding is not claimed to be preempted by the timer.

The snapshot covers the complete page, including the legacy S0 DOM clock and
all three v2 Canvas templates. `snapshotWidth` is in points; the returned image
is checked in actual pixels, including Retina scaling. Native RGBA sampling of
a 32×32 grid requires at least 922 opaque samples and two quantized colors;
this rejects blank/transparent output independently of page-reported readiness.
It is not a semantic visual-quality score and can conservatively reject an
almost uniform legal design.

Input images are bounded to 8,192 pixels per edge and 16,777,216 pixels total.
Output preserves the viewport ratio with a longest edge of at most 1,280 pixels
and 512 KiB. JPEG encoding tries quality 0.86 and, only when oversized, 0.68.
ImageIO verifies one complete decodable JPEG, dimensions and size. The native
report binds the actual width/height, sample counts and quantized color count.
The default viewport is 960×540; runtime profiles accept 64–1,280 points per edge.

## Immutable seal and final report

Sealing requires the same project identity, current source report, source
revision digest, latest revision and no competing active Job. It rebuilds the
manifest/project data natively with `preview: "preview.jpg"`, keeps index.html
unchanged and rechecks the render digest. The fixed set is creator.json,
project.json, index.html and preview.jpg; arbitrary extra files remain invalid.

`CreatorSeal` version 1 records the source revision ID/digest, render digest,
validation context and native metrics. The new revision binds the JPEG digest
and the sorted-path real-byte bundle digest. Its `template-runtime-v1` report
binds project identity, immutable metadata, render/poster/bundle bytes,
template/SDK/policy/host versions and viewport. Exactly five results are passed:
structure, sourceReconstruction, policy, runtime and posterCapture. The report
and revision become visible at the same atomic project-index commit point.

The older draft and `template-structure-v1` report remain unchanged, including
runtime/posterCapture = notChecked. The optional seal field is absent in legacy
records, preserving their canonical encoding. Original S0/S1.0 v1 generators,
three-file names, byte reconstruction and golden digest assertions are unchanged.
These are content bindings, not authenticated signatures against someone able to
rewrite all records and recompute every digest. Runtime passed describes this
bounded template initialization/capture profile, not a long-running load test.

## Save, playback and interruption recovery

`store.publication` checks the current full report and returns native import
permission. `WallpaperImportService` still rejects ordinary v2 folder imports
without that permission. CreatorPublisher stages the complete candidate and
previous package, uses the existing safe copy/replacement importer, then records
the binding through an atomic expected-value replacement. Formal playback is
rechecked before confirmation, as are the source revision and final installed
bytes. The library's existing `LibraryPreviewFetcher` decodes the saved cover.

The prepared/installed/confirmed journal contains both package digests and
registry bindings. Before confirmed, recovery restores the prior complete
package/binding or removes a first import; after confirmed it keeps the complete
new version. A process-wide file lease held across awaits prevents another
publisher from recovering a live save. Journal steps also have short file locks.
Recovery is idempotent, including interruption between import and journal update.

Files, registry and project index are separate transactions: intermediate
inconsistency blocks playback, rather than being a globally atomic update.
Unrelated edits, corrupt bytes/bindings or invalid old evidence preserve the
journal and fail closed instead of overwriting another writer. Host upgrades
invalidate the report; no automatic cross-version repair is implemented.
`recover(store:)` can finish a published project pointer after a confirmed save.
The orchestrator additionally recovers unfinished revision Jobs. These are
explicit services, not app-launch hooks.

Installed v2 content always requires a matching final registry report and keeps
the template runtime policy. Missing registry, altered JPEG/metadata, outdated
host/SDK/policy or unknown versions are rejected. Legacy v1 playback without a
registry remains compatible; an existing binding tightens its checks. Screensaver
and lockscreen creator publication remain blocked. Storage migration and backup
still do not include creator history; they require separate integration before UI.

## Opt-in live smoke

The normal `python3 scripts/test.py` gate uses mock model streams. The live test
skips before creating a network client. Enabling live mode is allowed only with
`--only CreatorLiveSmokeTests` (or its single method), never a full/UI gate.
The original S1.4 gate used mocks. A subsequent explicitly run live smoke passed
1 test, with zero failures/skips: CreatorLiveSmokeTests/testSingleLiveCreationAndSave.
The user identifies the profile as openaiCompatible with kimi-k3. Before S2.1,
the local result summary was checked and its disposable log/result bundle was
removed. No new request or credential access was needed for that verification.
This proves one creation/save path for that profile, not every provider or a live
iteration/repair benchmark.

In zsh, from the repository root, replace endpoint/model/protocol values with
the intended provider configuration. Read the key without placing its literal
value in command history:

```sh
read -rs 'CREATOR_LIVE_API_KEY?Temporary API key: '
export CREATOR_LIVE_API_KEY
TEST_RUNNER_CREATOR_LIVE_LLM=1 \
TEST_RUNNER_CREATOR_LIVE_PROTOCOL=openaiCompatible \
TEST_RUNNER_CREATOR_LIVE_ENDPOINT=https://your-provider.example/v1 \
TEST_RUNNER_CREATOR_LIVE_MODEL=your-model \
python3 scripts/test.py --only CreatorLiveSmokeTests
unset CREATOR_LIVE_API_KEY
```

Protocol is exactly openaiCompatible, anthropicMessages or geminiGenerateContent.
The endpoint is a base URL, without a key/query/fragment or completed operation
suffix. Codecs append chat/completions, messages or
models/{model}:streamGenerateContent?alt=sse and the appropriate version when
absent. Keys use request headers, including x-goog-api-key for Gemini. Profile
origin/configuration validation and redirect restrictions are unchanged.

Optional variables are `TEST_RUNNER_CREATOR_LIVE_PROMPT`,
`TEST_RUNNER_CREATOR_LIVE_JSON_MODE` (`automatic` by default, `required`, `schema`
or `disabled`), and `TEST_RUNNER_CREATOR_LIVE_LOCAL_MODE=1`. Automatic Creator
requests prefer a native `json_schema`; required uses `json_object`, schema forces
`json_schema`, and disabled sends no response format. Unknown values fail without
echoing input. For this smoke, the one-request budget below still forbids a second
request even in automatic mode.
HTTP/empty keys require the explicit local OpenAI mode and exactly localhost,
127.0.0.1 or ::1. For that case explicitly set `CREATOR_LIVE_API_KEY=''` instead
of reading a key. Otherwise HTTPS and a nonempty key are required.

Request budget is one and maximum output reservation is 2,048 tokens; no retry
or automatic JSON-mode downgrade can send a second request. Provider usage may
remain unknown and input/extra provider charges are not covered by this token
reservation. The optional smoke can incur the provider's charge when run.

Before any subprocess starts, the runner removes credential environment variables.
It passes only a random local port/token to Xcode, then serves the credential once
from memory at 127.0.0.1. The test uses an ephemeral URLSession and MemoryKeychain;
no API key enters Xcode's persisted test environment, a file or personal Keychain.
The bridge closes and clears its buffer after the run; this is application-level
nonpersistence, not protection against OS swap/debugging or a compromised process.

The smoke uses a disposable project/library and deletes both afterwards; it never
applies a wallpaper. XCTest retains attachments with the validated model parameter
result, usage/provenance, final report and JPEG, or bounded stage/failure codes.
Raw SSE, thoughts, error bodies and credentials are not recorded. The runner
prints the result-bundle location; that disposable output must be exported if
needed and is not durable repository evidence. The key is single-use even if
delivery fails; rerun explicitly to make another request.

## Verification and limits

The final targeted run passed 189 native tests with zero failures and four skips:
the three existing S0 unrestricted-code probes and the opt-in creator live test.
It covered all new services, old generation/storage/registry, v1 golden bytes,
template rendering, ordinary import, Web preview and library cover loading.
All 19 new routine native tests passed. The credential bridge's eight Python
tests and the runner's existing 18 tests also passed using synthetic credentials.
One full `python3 scripts/test.py` gate passed 695 Python tests in 33 modules and
4,907 native tests, with zero failures and 70 skips (4,977 native total). It ran
once; no retry was needed. Source/test/generated-project hashes captured before
the gate matched afterwards. XcodeGen generated the project; it was not edited
by hand. The 70 skips comprise the three S0 unrestricted probes, 62 opt-in
media/device checks, three live Steam checks, one reference job and the new live
creator smoke. They are not passing evidence for those features.

The full build log has 28 compiler warning lines at 14 locations outside this
change. Four runtime warnings about main-thread work were attached to passing
tests: `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`,
`VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`,
`WebMPlayerTests.testACancelledOrPausedWatchIsNotTold()` and
`WebMOpeningTests.testAVp9FileOpensWithItsFormatSizeAndLength()`. The first two were
also recorded in S1.3; the two WebM warnings were additionally observed this run.
These tests/production domains were not changed. Xcode supplied no source
locations; this task records the warnings without claiming their cause is fixed.

Early targeted iterations caught a Retina pixel expectation, callback argument
labels and actor access in the new code, then two cumulative mock-request test
assertions. These were corrected. A new snapshot actor warning was fixed by
declaring the injected snapshot function MainActor; the final targeted warnings
are outside the changed source/tests. No claim is made that earlier failed runs
passed. No visible UI, real provider, personal Keychain, desktop activation,
Release delivery, long-run energy/load or S4 isolation was exercised.

## S2.3 follow-up

Formal playback now holds a shared publication lock and rejects every active journal,
including the interval after registry replacement but before confirmation. Recovery precedes
headless bridge bootstrap. Custom registry reads must also pass the matching publication root.
See [creator-acceptance.md](creator-acceptance.md) for the AC matrix and separate opt-in
30-case benchmark/long soak commands. The one-request live smoke contract remains unchanged.
