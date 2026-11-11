# Creator S3 fixes and S4 execution upgrade

The authorized scope is three independently verified commits on `feat/ai-creator`,
followed by an arm64/macOS 15 compatible ad-hoc pre-release. No application launch,
desktop replacement, personal Keychain access or live model requests are part of the
routine verification. Existing hardware evidence is not replaced by automated checks.

## 1. Shared model negotiation and local connections

Automatic OpenAI-compatible output negotiates schema → JSON object → prompt JSON.
Connection checks and creation use the same provider and native validation. A 400/422
must identify the response-format feature; unrelated errors and 401 never trigger a
mode downgrade. Shape errors can negotiate, while parameter-range/resource violations
remain content repairs. Complete leading thought blocks and one JSON fence are stripped;
ambiguous/truncated responses still fail. Each HTTP request is reserved before sending.

Protocol negotiation is recorded separately from the maximum two content repairs,
but both share a maximum of three requests and the configured token reservation.
Disabling content repair does not disable protocol negotiation. Historical conversations
without the optional negotiation fields preserve their original budget rules.
New settings use 24,576 reserved output tokens, up to 8,192 per request. Blank UI input
means that default; invalid and overflowing values cannot be saved. Smaller explicit
budgets remain effective and can prevent another attempt.

The connection result carries the actual negotiated mode, model and elapsed time.
A native dismissible success banner shares the existing error-banner strip. A new test,
cancelled/failed test or configuration edit clears stale success. Confirmation still
shows the saved target and model, and explains that negotiation may cost multiple calls.

Explicit local OpenAI-compatible mode additionally accepts RFC1918 IPv4, IPv6
`fc00::/7` and `fe80::/10`, and valid `.local` DNS labels. Public HTTP, alternate numeric
IPv4 notation, credentials/query strings in URLs and cross-origin redirects are rejected.
Configuration generation and origin binding remain unchanged. No network discovery or
automatic credential copying is introduced.

Stage 1 verification: the routine gate passed 5,006 native tests with zero failures and
72 explicit skips; all 720 script tests passed. Focused negotiation, profile, generation,
repair, conversation and settings coverage passed 56/56. No live provider or desktop
operation was used. At the stage 1 checkpoint, stages 2 and 3 remained pending; that commit did not unlock S4.

## 2. Versioned WebGL template renderer

Keep the three v2 template catalogs, 10/12/10 parameter counts, six presets and resource
limits. Preserve byte reconstruction of existing immutable templates by retaining their
renderer revision. New revisions use a bounded WebGL fragment renderer with native
catalog parameters, 30 FPS, at most 2,073,600 pixels and a deterministic capture barrier.
Clock typography uses a high-DPI overlay and measured safe insets. Context loss/recovery,
pause/resume/resize/stop and a safe non-GPU fallback require regression evidence.

Stage 2 focused verification: 26/26 native tests passed, including real WebGL
compilation, native JPEG pixels, context loss/restoration and forced fallback. The
old S0 and v2 bundle digests remain pinned. The routine gate passed all 720 script tests and 5,012 native tests, with zero
failures and 72 explicit skips. S4 remains closed until its independent isolation
gate passes.

## 3. Free-code execution and external test package

Free code is a distinct versioned contract and runtime policy. It must pass the original
S0 request probes with positive controls, independent native liveness checks, scoped
termination and reconstruction tests before the public mode is enabled. A page-owned
heartbeat, JavaScript API wrappers alone, `stopLoading()` or changing a state flag are
not isolation evidence. Keep immutable histories, native capture, digest-bound validation
and all playback-entry checks. Failed candidates must never replace the active wallpaper.

The cursor bridge is per display, runs only while visible playback needs it, emits at most
30 updates/second, and stops on occlusion, pause, sleep and teardown. It exposes only
coordinates and activity, without a file, credential or XPC capability.

The final pre-release must describe what was actually verified, retain the ordinary
release channel, and include the image checksum and ad-hoc installation instructions.
Visible UI, hardware-specific sleep/multi-display and energy acceptance remain separate
from headless/native test success.

## Verification

Each commit runs its focused native regression suites and the routine gate, with all
models mocked and credentials isolated. The final package additionally verifies nested
signatures, bundled library deployment versions, mounting and published download bytes.
Durable outcomes are recorded in the owning feature documentation and verification log;
temporary output stays in one task artifact directory and is removed after verification.

Final stage 3 gate: all 720 script and 5,034 native tests passed, zero failed and 69
explicit skips. The original three S0 probes now execute in the ordinary gate.
Focused S4 coverage passed 18/18, with a broader 68/68 regression run and a 27/27
controller/S4 run. Documentation and localization checks passed. The single-HTML
contract, opaque iframe, process ownership/SPI limitations and remaining hardware/GPU
checks are described in [the implementation](../features/creator-free-code.md).
Release construction and publication follow the verified commit; no main merge,
latest promotion, personal credentials or visible desktop operation is authorized.
