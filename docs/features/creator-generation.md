# Creator structured parameter generation

S1.3 connects the [S1.2 model service](creator-llm.md) to
[immutable revision storage](creator-revisions.md). It implements the service-level
generation parts of PRD FR-03 and AC-02/03/04/07/10/12. It creates a complete native
render draft and structure-only evidence, without UI, a live model request in
tests, poster capture, publication or desktop activation. See the
[PRD](../plans/02-creator-prd.md), [contract](../plans/03-creator-technical-plan.md#41-s1-实施合同templateparameteroutput-v1)
and [stage plan](../plans/2026-11-10-creator-s1-s4.md).

Before implementation, the verified S1.2 code and documents were committed locally
as `e3a61f55` on `feat/ai-creator`, then the tree was checked clean. The verified S1.3 implementation was subsequently committed locally as
`ac28cf34` before S1.4. No push, installation or desktop operation was performed.

## Ownership and call boundary

| Component | Responsibility |
| --- | --- |
| `CreatorGenerator` | Per-project cancellation, explicit base context, model request, strict parse, native compile and revision transaction |
| `CreatorPromptBuilder` / `CreatorOutputSchema` | Catalog-derived instructions, parameter domains/units/defaults/presets/resource caps and JSON Schema |
| `CreatorJSON` / `CreatorOutputValidator` | Bounded JSON grammar, duplicate-key rejection, exact contract and native allocation checks |
| `CreatorTemplateCompiler` | Accepts only a validated output value and creates the native specification and plain presentation metadata |
| `CreatorGenerationMetadata` | Versioned model/configuration/job/budget/usage provenance, bound into the revision digest |
| `CreatorBundlePresentation` | Bounded plain title/summary in native manifest and project.json, never source or a path |
| `LLMJSONEnvelope` | One complete Markdown JSON fence, shared by answer assembly and strict parsing |

The caller supplies an existing project ID, optional `baseRevisionID`, saved
Profile ID/configuration ID, prompt and maximum output tokens. From-zero generation
omits the base; project creation remains a separate native store operation.
`generate` returns an immutable `CreatorRevision`. Each generator allows at most
four active projects; a new generation cancels the older operation for the same
project. Native job IDs/tokens and the persisted active pointer fence late results
even across store instances. `cancel(projectID:)` also interrupts a held stream.

## Prompt and output contract

The System Prompt exports `gradient-v2`, `stars-v2` and `clock-v2` directly from
`CreatorTemplateCatalog`: 10/12/10 parameters, native types, ranges, enum values,
units, defaults, six preset examples and fixed resource budgets. No second copied
parameter table is used. UI step sizes are not JSON `multipleOf` requirements.
The full JSON Schema is separately exportable; the prompt uses a compact catalog
to fit the existing input limit. Schema domains and native validation have
boundary/preset consistency tests; cross-field equality of defaults is additionally
enforced by Swift, not claimed as a general JSON Schema capability.

User descriptions are nonempty and at most 2,048 UTF-8 bytes; all request text,
including catalog and base context, remains within S1.2's 16 KiB input limit.
The user message is encoded as data. An explicit base contributes only its ID,
template, full parameter set and title/summary; it is never replaced with the
latest revision. The base's metadata digest is captured natively and rechecked
before staging and commit. The prompt contains no stored Key, provider origin,
local path or native digest. Prompt-injection resistance comes from native output
validation and reconstruction, not from trusting the model to follow prose.

The model must return exactly six root fields:

| Field | Rule |
| --- | --- |
| `schemaVersion` | Integer 1, independent of bundle/template versions |
| `templateID` | Exactly one of the installed v2 catalog IDs |
| `title`, `summary` | 1–60 and 1–240 Unicode scalars; no whitespace-only text, C0/C1 controls, line/bidi control characters |
| `parameters` | Every native parameter exactly once, with no coercion, unknown key or out-of-domain value |
| `properties` | Required object, possibly empty; known parameter subset, each containing only a matching `default` |

The capability/asset whitelist in v1 is empty. `assets`, `capabilities`, `files`,
code, paths, URLs and permission fields are not recognized, even when empty.
Numeric/boolean/enum domains do not provide an arbitrary string escape hatch.
Title/summary are plain metadata; literal markup there never enters index.html.

Parsing starts only after the protocol has finished normally. One entire `json`
or unlabelled Markdown fence is accepted, including CRLF; prose, multiple blocks,
unclosed fences and trailing text are rejected. No substring search, bracket
repair or partial result is used. The 16 KiB UTF-8 output cap includes surrounding
whitespace and fences. A byte parser limits depth to 8 and nodes to 4,096, rejects
invalid number syntax/nonfinite values, invalid escapes/surrogates and duplicate
keys after string decoding. Numbers use the catalog's finite Double semantics.

Missing fields, wrong types/ranges, default conflicts, malformed/truncated or
oversized output yield `malformedOutput`. Unknown fields/templates/versions and
capability/code expansion yield `policyViolation`. Public failure descriptions
contain only fixed codes; no raw prompt, model text, URL or credential is attached.
There is no automatic parameter-repair request in S1.3; S2.1 must use the same
request budget if it later adds bounded repairs.

## Native reconstruction and transaction

Only a validated output can be passed to the compiler. It constructs a native
specification; the existing generator supplies all HTML/JS, property definitions,
resource caps and policy. All generated parameter values become initial
`project.json.general.properties[*].value` values, including controls omitted
from the model's optional subset. The model cannot write files or choose names.

The result is `bundleVersion: 2`, `packaging: renderDraft`, with exactly
creator.json, project.json and index.html. Optional manifest `presentation`
stores title/summary and participates in deterministic byte reconstruction,
`renderDigest` and `bundleDigest`. Without it, old v2 encoding is unchanged.
S0/S1.0 v1 generators and golden digest assertions are untouched. An old v1 bundle
with a v2 catalog template can be a base for a new v2 revision; the original
two-parameter S0 kinds require an explicit upgrade before model iteration.
Neither route overwrites old bytes. No preview.jpg is generated in this stage.

Generated revisions populate providerID, modelID, outputSchemaVersion and a
versioned optional `generation` record: job ID, configuration ID/revision, protocol,
attempt count, reserved output tokens, elapsed time, optional usage and base digest.
The prompt summary collapses whitespace and keeps at most 240 Unicode scalars;
the raw answer, thoughts and system prompt are not persisted. Missing optional
fields preserve old canonical records. Any provenance/usage change invalidates
the existing report. These are content digests, not cryptographic authentication
against an actor able to rewrite every file and recompute all hashes.

Each actual request consumes S1.2's durable request/output reservation; retries
are not refunded. Usage is only the final successful request's optional snapshot,
not failed-attempt usage or the total bill. Unknown usage stays nil. Maximum-output
reservations exclude input and provider-specific token charges.

The generator rechecks Profile state before packaging and before commit. These
checks and the revision file lock are separate transactions, not an atomic lock
across both stores; no zero-time-window claim is made about external edits after
the final check. Packaging sends no further request. In-flight credential checks
and invalidation retain the S1.2 boundary.

Before the project-index commit, native structure evidence is written into the
candidate and moved with the revision. The same atomic index replacement makes
the revision and its validated selection visible. Results are:
`structure/sourceReconstruction/policy = passed`,
`runtime/posterCapture = notChecked`. This is `template-structure-v1` evidence for
restricted draft preview, not publication approval.

Cancellation is checked before the request, during transport, parsing, compilation,
each candidate-file write and immediately before the commit point. Failures clean
the owned job/candidate and leave old revisions intact. A cancellation or injected
failure after the index commit does not remove committed history: recovery keeps
the whole revision/evidence and completes the journal. Tests inject failures on
both sides of this boundary. Existing restart recovery never reissues model calls.

## Verification and remaining boundaries

28 new tests cover three protocols × three templates, all six presets, schema
domains, exact property defaults, explicit older-base iteration, plain metadata,
single-fence handling, duplicate keys/escapes/numbers/depth/size, contract and path
rejection, in-flight and four-stage cancellation, superseded jobs, stale bases,
changed Profiles, provenance tampering, usage/budget accounting, v1 compatibility
and interruptions around commit. The final targeted run passed 98 tests with
zero failures or skips, including storage, runtime routing, catalog and LLM
regressions. An initial targeted compilation caught an optional-byte range-pattern
error in the new parser; it was fixed before the successful runs. Review also
added rejection of a trailing control character that a dollar regex anchor could
otherwise overlook.

One full `python3 scripts/test.py` gate passed 687 Python tests (32 modules) and
4,888 native tests, with 0 failures and 69 skips (4,957 native total). All 28 new
tests passed. The full gate ran once; no retry was needed. Source/test/project
hashes were captured before the gate and checked afterwards. XcodeGen regenerated
the project; it was not hand-edited.

The 69 skips are 3 known S0 unrestricted-code probes, 62 opt-in media/device tests,
3 live Steam tests and 1 reference-render job. Two existing main-thread runtime
warnings remain in `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`
and `VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`;
both tests passed and their production code was not changed. Targeted build logs
contain existing warnings outside this change; none points to the modified/new
Creator or LLM source/tests. The incremental full gate emitted no compiler warning.
These skips/warnings do not validate real providers, media devices or S4 isolation.

Every model request is intercepted by `LLMMockURLProtocol`, including unknown
addresses; no fallback to the network is allowed. Tests use the existing in-memory
Keychain, synthetic secrets and isolated temporary roots. No personal Keychain,
live paid API, creator UI, runtime capture, desktop operation or Release build
is exercised by the new generation tests. Existing full-suite opt-in/skipped
checks are reported separately, never as passes.

The subsequent [S1.4 service workflow](creator-publication.md) implements native
poster capture, runtime/final evidence and publication. Visible UI and authorized
real-model validation remain pending; S1.3 itself still produces only a render draft. Parameters are not
automatically repaired; project backup/storage migration, startup recovery wiring
and visible interaction remain unimplemented. S4's download/network/termination
probes remain unresolved and unrestricted code stays disabled. This stage stops
after implementation and verification.
