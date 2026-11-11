# Creator bounded repair and revision iteration

Subsequent integration: [S2.2 native creator workspace](creator-workspace.md) adds the panel UI, controller-start recovery and explicit backup/move refusal boundaries. Statements below about missing UI/startup wiring describe that earlier stage; its test evidence is historical. S2.1 was committed locally as `29cd3086` before S2.2, without push.

S2.1 implements the service portions of FR-07/08 and AC-02/03/07. It extends the
[S1.4 workflow](creator-publication.md) with a persistent whole-turn budget,
bounded parameter repairs, local conversation history and explicit selection of
validated historical revisions. See the [PRD](../plans/02-creator-prd.md),
[technical contract](../plans/03-creator-technical-plan.md#20-s21-有限修复对话与回退实施合同)
and [stage plan](../plans/2026-11-10-creator-s1-s4.md).

Before implementation, the user's S1.4 live-smoke result was checked: one test
passed with no failures/skips. Protocol/model were user-reported as
openaiCompatible/kimi-k3; this verifies one creation/save, not real repair quality.
Its temporary log/result bundle was removed without reading response attachments.
The verified S1.4 code and documents were committed locally as `8c1480b0` on
`feat/ai-creator`, then the worktree was checked clean. S2.1 remains uncommitted.
No push, installation, personal Keychain access or desktop operation occurred.

## Ownership and state

| Component | Responsibility |
| --- | --- |
| `CreatorOrchestrator` | Whole-turn lifecycle, bounded retries, full runtime/seal/save, cancellation and explicit historical selection |
| `CreatorConversation` | Versioned local messages and authoritative per-turn request/output reservation ledger |
| `CreatorRevisionStore+Conversation` | Locked atomic persistence, iteration ownership, state transitions and request reservations |
| `CreatorRepairIssue` | Native failure categories, catalog-only field diagnostics and runtime reason codes |
| `CreatorConversationText` | Bounded context filtering after exact current-credential redaction |
| `CreatorGenerator` / `CreatorPromptBuilder` | Explicit original parent, repair context, strict output validation and immutable fresh attempts |
| `LLMProvider` | Single-call mode for S2.1; existing retry mode retained for standalone S1.2/S1.3 callers |

`CreatorOrchestrator.Request.maxRepairs` defaults to zero and accepts 0...2.
The caller must explicitly allow retries. A turn follows generating → runtime →
sealing → publishing → completed. Failures while generating or capturing may
enter repairPending, then create a new generation Job. Other terminal states are
failed, cancelled and interrupted. The caller receives the iteration ID, failure
category, request count and budget-exhausted flag, rather than an arbitrary
transport or WebKit error string. Existing standalone generation APIs retain
their earlier typed errors.

## One budget for the complete turn

For fixed output modes the request limit is `min(1 + maxRepairs, profile.requestBudget)`.
Automatic OpenAI negotiation may use the configured request budget even with repairs
disabled; the combined limit is still three. Optional `negotiatesJSON` and
`negotiationCount` fields distinguish format negotiation from content repairs and
preserve the old budget semantics when absent. Native field diagnostics survive
negotiation, and invalid candidate bytes are never committed. Every attempt reserves its maximum output tokens under the same
Profile/turn token cap. A new child Job has one request; Provider internal retries
are disabled. A 429, 5xx, timeout, disconnected/truncated stream, invalid answer,
runtime failure or automatic JSON-mode fallback cannot open another budget.

Before sending, storage writes the whole-turn reservation, then the child Job's
counter. These are two atomic records under one file lock, not a cross-file
atomic transaction. A crash between them conservatively charges an unsent
attempt; the reservation is never refunded or reused. Tests inject failure at
that boundary and verify zero packets, one retained reservation and no replay
after restart. Reusing a child ticket or calling the legacy counter helper
cannot bypass the ledger.

401/403, provider refusal, stale/missing configuration, invalid local input and
cancellation stop immediately. Storage, sealing and publication failures do not
call the model again. Retry-After is respected up to 30 seconds; a longer delay
stops without shortening it. 5xx uses a bounded 0.5-second outer wait. Only
openaiCompatible automatic JSON mode may downgrade, consuming one of the same
attempts; required mode remains required. Cancellation interrupts waits and
streams. Profile state and origin-bound credentials are rechecked on every new
request, including after repairPending.

Available usage from a normally completed answer is recorded even if its
parameters are rejected. A failed/truncated transport without a completed usage
snapshot remains unknown. Reservations exclude input and provider-specific
charges; they are not an invoice or a hard spending cap. Revision generation
metadata records its own child Job's count and optional `iterationID/repairIndex`;
the conversation owns whole-turn totals. Missing optional fields preserve older
canonical encodings.

## Minimal repair context and complete verification

The native catalog supplies all parameter types/ranges/enums, presets and
resource limits. Detailed static validation reports missing/extra fields,
types, ranges, enums and default conflicts without returning untrusted values.
Unknown field names are represented by the known parent (`$`, parameters or
properties), never echoed. Runtime diagnostics use timeout/pageFailed/
invalidCapture, not page logs or WebKit descriptions.

A repair sends at most 240 Unicode scalars of sanitized input summary, the native
diagnostic and the same allowed catalog. It may include a validated base's
parameters. If runtime validation failed, the latest intact attempted draft can
supply parameters, while its title/summary are replaced by native fixed text.
The source `parentID` still refers to the user's original chosen base. Invalid
model output, raw SSE, reasoning, system prompt, exception bodies and filesystem
contents are never copied into repair context or conversation storage.

Before persistence or sending, the current Profile's credential Grant replaces
its exact secret without exposing the Key. Native filtering then removes known
credential assignments, URLs, absolute path forms, long token-like strings and
control characters. This is not a claim to recognize every arbitrary secret
hidden in natural language. This stage has no asset/file attachment input and
never reads files named in a prompt. No additional Keychain namespace is added.

Every valid repair answer undergoes strict static validation, deterministic
native template reconstruction, a new immutable renderDraft, real offscreen
WKWebView initialization/render checks, native JPEG capture, a new sealed revision
and a matching current-policy/SDK report. Runtime failure cannot turn a static
report into passed evidence. The test's injected first runtime failure is
followed by the real poster service; success is not a fake state assignment.
No generated JavaScript or S4 isolation work is introduced.

## Local conversation, recovery and historical selection

`Projects/<project-id>/conversation.json` is checksummed versioned Codable JSON,
using the existing actor/file lock, atomic replacement, bounded no-link reads
and private file permissions. It contains up to 64 turns and at most 256 KiB;
overflow fails explicitly rather than silently truncating history. A missing
file on an old project reads as empty without creating it. Corrupt, unknown or
symlinked records fail closed. Content checksums are not signatures against a
local actor able to rewrite all files and recompute their hashes.

Each turn records a sanitized user message, original base ID/digest, Profile and
configuration IDs, cancellation token, limits, attempt reservations, optional
usage, native failures and draft/result references. Multi-round context is the
explicitly chosen revision plus the current follow-up; the complete stored
conversation is not automatically uploaded. It is outside revision bundles and
never imported into the wallpaper library. No conversation export exists.

An iteration file lease spans the gaps between model requests, repair waiting,
runtime capture and publication. Recovery skips a live owner. After its lease
is released by process exit, recovery interrupts the abandoned turn and cleans
uncommitted Job candidates, without resuming or issuing requests. Complete
immutable drafts remain inspectable. Automatic static-only attempts do not
replace the last working selection; recovery prefers full runtime-validated
versions (and compatible legacy v1) for the last usable pointer. An explicitly
selected intact structure-validated draft remains a valid restricted preview.

`selectRevision` checks current evidence before cancelling active work, then
updates only the project's selected working/preview ID. It neither republishes
the selected version nor changes desktop assignments. A subsequent follow-up
uses that history only when its ID is explicitly passed. Tests keep the second
installed version while previewing the first, then derive a third from the first,
and separately verify that a failed second version leaves the first usable.

Cancellation before a commit point removes only the owned candidate. Complete
revisions and confirmed publications survive late cancellation; no claim is made
that an already committed save can be undone retroactively. Restart recovery is
an explicit service call, not yet wired to application startup.

## Verification and remaining boundaries

All 28 new tests in CreatorRepairTests, CreatorConversationTests and
CreatorIterationTests passed. The final Creator/LLM targeted run covered 25 test
classes: 210 passed, zero failed and four skipped. The final
`python3 scripts/test.py` gate passed 695 Python tests in 33 modules and
4,935 native tests, with zero failures and 70 skips
(5,005 native total). Two full gates ran under the failure-only retry rule. The first had 4,934 passed,
one failure and 70 skips: the unchanged GPU energy counter test read about
0.87 mW against its 10 mW lower bound. Its isolated recheck passed, then the
second full gate passed without source or threshold changes. The sampling
fluctuation remains unexplained; it was not repaired or hidden. Source/test/generated
project hashes matched before and after. XcodeGen regenerated the project.

The 70 skips are three known S0 unrestricted probes, 62 opt-in media/device checks,
three Steam network checks, one reference job and one creator live smoke. The
final targeted/full build logs have 28/0 compiler warning lines outside the
changed sources/tests. The full gate recorded 3 main-thread runtime warnings
in passing, untouched tests: `WebMOpeningTests.testAVp9FileOpensWithItsFormatSizeAndLength()`, `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`, `VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`.
These are recorded without claiming their causes were repaired.

Early targeted iterations corrected an async XCTest assertion compilation issue,
an overbroad assertion against a legitimate number in the native catalog, and
stale Profile errors being categorized as storage errors. Final targeted runs
passed; earlier failures are not counted as passes.

All routine model traffic is intercepted by the local Mock URLProtocol, including
unknown hosts; credentials are synthetic and stored in MemoryKeychain. Successful
runtime checks use the real native offscreen WebKit/JPEG path in isolated
temporary libraries. The default-skipped live-smoke entry is not enabled for
S2.1. The user's earlier one-request live result does not validate real multi-round
repair, model quality or other providers.

No UI, real desktop activation, application install/Release delivery, long-run
energy/load test, startup wiring, backup/storage migration or S4 isolation fix
is included. A recurring template/WebKit defect may consume the permitted
attempts and still fail; bounded parameter regeneration is not an engine repair.
Work stops at S2.1; later stages require their own instruction.
