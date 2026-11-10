# Creator model connections

S1.2 adds the native connection layer after [S1.1 storage](creator-revisions.md).
It implements the service-level portions of PRD FR-02/10 and AC-07/12/17/18.
It does not add UI, call a live model during tests, execute returned content, or
publish a revision. See the [PRD](../plans/02-creator-prd.md),
[protocol contracts](../plans/03-creator-technical-plan.md#44-共享传输层与纯逻辑-codec)
and [stage plan](../plans/2026-11-10-creator-s1-s4.md).

The local rollback anchor is `37f2c603` on `feat/ai-creator`, containing the
previously verified S1.1 settings supplement and planning documents. Before S1.3,
the verified S1.2 work was committed locally as `e3a61f55`; it was not pushed.
No installation or desktop operation is part of either stage.

## Ownership and call boundary

`App/Services/LLM/` owns the connection services:

| Component | Responsibility |
| --- | --- |
| `LLMProvider` | A bounded generation job, credential/configuration checks, retry budget, cancellation and sanitized diagnostic events |
| `ProviderCredentialStore` | Explicit key binding, independent Keychain accounts, checked credential grants and native authentication headers |
| `LLMStreamTransport` / `LLMStreamOperation` | An ephemeral URLSession per attempt, suspended-task start, response policy, deadlines and one terminal result |
| `SSEParser` | Actual-byte limits and UTF-8-safe incremental event framing, independently of protocol JSON |
| `OpenAICompatibleCodec`, `AnthropicMessagesCodec`, `GeminiGenerateContentCodec` | Pure request descriptions and independent per-attempt response state; no network, files, Keychain or UI |
| `LLMRequestCoordinator` | Synchronous invalidation on settings/credential/job mutations and exclusion of duplicate in-process job requests |

The caller supplies a saved Profile ID/configuration ID and a live S1.1 job
ticket. The provider returns complete answer text, optional usage, the Profile
snapshot, ticket, attempt count, reserved output tokens and elapsed time. A
successful response leaves the native job in `generating`; the
[S1.3 generator](creator-generation.md) validates the parameter schema before
staging a revision. No raw stream or partial answer is
written to `partial.bin`. Failure/cancellation cleans the owned job using S1.1
transactions and preserves earlier revisions. `busy` does not cancel another
owner's job. Restart recovery interrupts abandoned jobs, never resends them.

Only a complete JSON object is accepted here. S1.3 adds `LLMJSONEnvelope` to
accept a single whole Markdown JSON fence; surrounding prose, multiple blocks,
unclosed fences and oversized text fail. The 16 KiB cap includes leading
whitespace and fence bytes. The independent S1.3 validator owns duplicate-key,
unknown-field, template/parameter/default-value and code-field rejection. A
valid JSON object from this service is not permission to run or publish it.

## Credentials and target changes

`ProviderCredentialStore` reuses `KeychainGenericPassword`. Its service identifier
is `WallpaperMachine.Creator.ProviderCredentials.v1`; each account is the stable
Profile UUID in lowercase. The Keychain payload binds the key to the Profile ID,
normalized origin (scheme/host/effective port), configuration UUID/revision, and
canonical Profile digest. Binding is an explicit native operation; saving or
copying a Profile never binds a key automatically.

Host, scheme, port, base path, model, capabilities or other Profile metadata
changes invalidate the binding. Deleting and recreating the same Profile ID gets
a new configuration UUID and cannot revive an old key. A stale Keychain item may
remain, but cannot authorize a request. Same-host profiles have independent keys.
Keys are bounded visible ASCII header values, with no whitespace/CRLF; metadata,
jobs, codecs and model input never receive a key. Grants redact ordinary string,
debug-string and Mirror representations. This is not protection from a debugger
or arbitrary native code with access to process memory.

Before reading credentials and before resuming each suspended task, the provider
reloads the saved Profile. The final full-snapshot check and `resume()` execute
under the settings store's file lock, shared with Profile edits. In-process
Profile replacement, credential replacement/removal and job cancellation notify
active requests synchronously. A conservative cancellation can occur before a
settings rename that later fails; it cannot authorize the new target.

While a request is active, a 100 ms monitor also checks external file replacement
or another process's settings/job edits. There is no idle monitor. Already-sent
data cannot be recalled, and the remote service can still charge for it. Changes
made directly in a different process's system Keychain are not watched in this
stage. Test coverage uses independent store instances plus external atomic file
replacement, not real cross-process Keychain notifications.

Default HTTPS/TLS validation stays enabled. Only explicit local OpenAI-compatible
profiles with exact normalized `127.0.0.1`, `localhost` or `::1` hosts may use HTTP
or omit the key. Missing local keys omit Authorization; stale/malformed bindings
are rejected even in local mode. No DNS-derived or alternative IP exception exists.

## Streaming, limits and errors

The transport clears system credential storage, cookies, caches and inherited
extra headers. Server trust uses system verification; other authentication
challenges are cancelled. `URLSessionTaskDelegate` rejects **all redirects**,
including same-origin redirects, before forwarding credentials. Fixed POST
endpoints are not silently changed into other methods or paths. Redirect refusal
is recorded before invoking the completion callback, so reentrant/late callbacks
cannot turn it into success.

SSE decoding buffers bytes until a complete line, then decodes UTF-8. It handles
multibyte characters across chunks, BOM, LF/CRLF/lone CR, comments, event names,
multiline data and blank-line dispatch. Actual raw bytes, including both bytes of
CRLF, discarded fields and thought content, count toward limits. Incomplete frames
or invalid UTF-8 are rejected. Parsing `[DONE]` does not ignore a malformed tail.

| Limit | Value |
| --- | --- |
| Raw response stream | 1 MiB per attempt |
| SSE line/event | 64 KiB, including framing bytes |
| Complete answer | 16 KiB UTF-8 |
| Error body inspected for JSON-mode fallback | 4 KiB; never logged |
| Input text | 16 KiB total; 1–32 messages, ending in a user message |
| Request body | 128 KiB after native JSON encoding |
| Request deadline | 60 seconds by default; injected limit must be positive and at most 300 seconds |
| Concurrency | 4 jobs per provider, 32 coordinator registrations; one in-process request owner per job |

Swift task cancellation immediately cancels/invalidate the session and completes
the waiting consumer; timeout also works for a held response. Decoder state is
locked, a terminal result wins once, and later data/completion callbacks cannot
replace it. There is no executable partial result.

`LLMFailure` and `LLMLogEvent` expose only fixed codes, HTTP status and bounded
counts; they do not retain raw NSError descriptions, URLs, prompts, response/error
bodies, credentials or thoughts. The log uses `AppLog`. This policy governs these
app diagnostics, not arbitrary operating-system tracing enabled outside the app.

401/403 do not retry. 429 accepts delta-seconds or HTTP-date Retry-After, defaults
to one second when absent/invalid, and returns an error when the requested wait
exceeds 30 seconds rather than retrying sooner. 5xx retries use bounded backoff.
Timeout, malformed/truncated stream, refusal and network failure do not retry.

Each attempt atomically consumes the native job's request budget (at most three)
and reserves `maxOutputTokens` against the smaller job/Profile token budget before
resuming. Failures and JSON-mode fallback are not refunded. Optional
`GenerationJob.reservedOutputTokens` and `Capabilities.jsonMode` leave old S1.1
canonical records byte-identical when absent. An old job with consumed attempts
but no reservation history cannot obtain another request. Input/provider-specific
token charges are not covered by this output reservation. Usage is optional and
describes only the last successful request, not all failed attempts or a task's
total bill. S1.3 persists these counters without adding parameter-repair calls;
future corrective attempts must reuse the same budget.

## Protocol-specific behavior

| Protocol | Implemented behavior |
| --- | --- |
| OpenAI-compatible | Chat Completions SSE, Bearer, system message, `max_tokens`, JSON object mode, optional `include_usage`, choice 0, usage-only tail, `stop` plus `[DONE]` required |
| Anthropic Messages | `x-api-key`, fixed `anthropic-version: 2023-06-01`, top-level system, block index/type tracking, cumulative start/delta usage, legal stop reason plus `message_stop` required |
| Gemini GenerateContent | Header-only `x-goog-api-key`, `/v1beta/models/{model}:streamGenerateContent?alt=sse`, top-level systemInstruction, generationConfig JSON MIME, candidate 0, STOP plus complete EOF and optional tail usage |

OpenAI-compatible root URLs receive `/v1`; a nonempty base path is the API prefix.
Anthropic/Gemini append `/v1` or `/v1beta` unless that is already the last path
segment. Profiles contain base URLs, not complete operation endpoints. Protocol
queries are constructed natively; Profile base URLs cannot contain any query.

OpenAI `jsonMode` defaults to automatic: request `json_object`, and permit a single
budgeted fallback only for a 400 explicitly naming `response_format` with an
unsupported/unknown parameter code. `required` disables fallback, `disabled`
omits the field initially. No free-form error-message heuristic is used. Explicit
`requestsUsage = false` omits stream_options without probing with another request.
Actual endpoint/model differences, including support for `max_tokens`, remain
unverified; no Responses API, tool calling or model-specific option negotiation
is implemented.

OpenAI reasoning_content and typed thought blocks are discarded. Only an explicit
Profile capability enables leading `<think>...</think>` filtering, incrementally
across deltas; unknown/unclosed wrappers fail, while literal tags inside JSON
strings remain unchanged. Anthropic thinking/redacted_thinking/signature blocks
and Gemini thought=true parts are skipped. Usage snapshots merge by field without
summing cumulative deltas; absent values remain unknown, not zero, and malformed
or decreasing cumulative counts fail. Thought-token counts are retained separately
when supplied, never inferred from visible text.

## Verification and remaining work

49 new tests in `Tests/Unit/LLM/` cover the three codecs, credential/header rules,
UTF-8/SSE boundaries and limits, cumulative/missing usage, thought filtering,
401/429/5xx, JSON-mode fallback, timeout/truncation, cancellation/reentrant callbacks,
Profile/key/job changes, duplicate callers, and zero secret text in app errors/logs.
Final targeted coverage also includes ProviderProfile, CreatorSettingsStore,
CreatorRevisionStore and CreatorStorageFormat (87 tests in total).

Every model URL is intercepted by `LLMMockURLProtocol`, including unknown URLs,
which fail with unsupportedURL instead of falling back to a network. Tests use
the existing `MemoryKeychain`, unique temporary roots and synthetic keys. The
first expanded targeted run found a test capture issue: URLSession had moved the
request body to httpBodyStream. The fixture now captures those bytes; it never
forwards the request. Review also added a CRLF byte-limit regression.

The final targeted run passed 87 tests with no failures or skips. One full
`python3 scripts/test.py` gate passed 687 Python tests (32 modules) and 4,860
native tests, with 0 failures and 69 skips (4,929 native total). All 49 additions
passed. No full-gate retry was needed. Existing S0/S1.0 golden assertions and
generators remain byte-identical. The generated Xcode project was refreshed by
the test runner, not edited by hand.

The 69 skips are 3 known S0 unrestricted-code probes, 62 opt-in media/device tests,
3 live Steam tests and 1 reference-render job. They are not counted as passes.
Two existing main-thread runtime warnings remain in
`AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()` and
`VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`.
Both tests passed; their production code was not changed. No compiler warning
points to the new/modified LLM or Creator source/tests in the targeted build logs.
Other existing compiler warnings remain outside this change.

No real provider request, TLS/proxy interoperability, personal Keychain permission,
UI, screenshot/cover, desktop activation or Release build is validated.
The subsequent [S1.3 strict parameter contract](creator-generation.md) is
implemented and tested separately. [S1.4](creator-publication.md) adds native
cover/publication and a default-skipped live smoke entry, with one request and
one-shot in-memory credentials. UI and actual provider verification remain pending.
S0/S1.0 generators and golden digests are unchanged. The known S0 unrestricted-code
probes and S4 isolation work remain unresolved; S1.2 does not relax those gates.

S2.1 callers disable internal transport retries and manage them in the persistent
[conversation budget](creator-iteration.md). Each child Job has one request;
JSON-mode fallback, 429 and 5xx share the outer limit rather than resetting it.
Standalone callers retain the S1.2 behavior. A credential Grant can redact its
current secret without exposing it; generation context then applies bounded
native text filtering. No new Keychain namespace or external logging is added.
