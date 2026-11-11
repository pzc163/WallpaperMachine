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
Nonempty credentials are loaded lazily into a process-only cache keyed by the full
Profile/configuration and settings location. UI refresh/selection never reads Keychain.
Settings/key changes synchronously invalidate caches. Local profiles without an explicit
`usesCredential` marker do not read or write empty Keychain records; legacy local
credentials require explicit re-entry to opt in. External Keychain edits take effect
on next process launch or explicit rebinding.

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

Default HTTPS/TLS validation stays enabled. Explicit local OpenAI-compatible profiles
may use HTTP or an empty key for exact loopback hosts, RFC1918 private IPv4,
IPv6 `fc00::/7` and `fe80::/10`, and valid `.local` mDNS names. Link-local IPv6
may include a literal interface scope encoded as `%25en0`; that scope remains part
of the credential origin. Numeric/octal IPv4 aliases, public HTTP and encoded-host
ambiguities are refused. Missing local keys omit Authorization; stale bindings
remain invalid. The app declares `NSAllowsLocalNetworking` and ATS insecure-HTTP exceptions only
for loopback/RFC1918/link-local/ULA CIDRs. No global native ATS bypass is enabled.
[Apple's CIDR exceptions](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)
apply on macOS 14+, covering our macOS 15 minimum. Profile checks remain stricter
than ATS; Creator WebKit keeps its separate offline CSP/download policies.

Explicit local model discovery asks confirmation for the entered target, performs
one bounded GET `/v1/models`, rejects redirects, and uses only the entered in-memory
key. It does not read Keychain, save a Profile or consume generation tokens. It
validates/deduplicates/sorts at most 512 model IDs; cancellation stops the request.
This is explicit target consent, not background network discovery.

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
| First response | 25 seconds until response headers; unreachable endpoints fail promptly |
| Stream idle | 90 seconds since response headers or last received bytes, including reasoning/heartbeat data |
| Request total | 300 seconds by default (including code generation); injected deadlines must be positive and at most 600 seconds |
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
Timeout, truncated stream, refusal and network failure do not internally retry. Complete
format violations may negotiate only in automatic OpenAI mode.

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

## Stream negotiation and progress

All three protocols request streaming first. Explicit HTTP 400/422 rejection of
`stream`/`stream_options` permits one non-stream fallback. OpenAI/Anthropic use
`stream:false`; Gemini uses `generateContent` without an SSE query. JSON responses
are size-bounded, require an explicit successful finish reason, retain usage and
omit thought blocks. A server that directly returns its valid non-stream response
can be decoded without another request. Arbitrary 400s, authentication failures,
truncated streams and bad content types do not trigger this downgrade.

Negotiation consumes the same whole-turn request and token reservations as JSON
negotiation/repair (maximum three wire calls). It does not enable content repair
when the repair switch is off. Historical conversation records retain their original
budgets. Cancellation aborts transport and negotiation without refunding sent calls.

Progress contains only connecting/thinking/content phase, accepted character count
and numeric usage. Content updates are coalesced to at most five per second, with
phase changes/final usage delivered promptly; raw reasoning never reaches UI or disk.
A response header completes the connection deadline, allowing local model prefill
to use the idle interval. Receiving tokens resets idle, never the total deadline.

## Protocol-specific behavior

| Protocol | Implemented behavior |
| --- | --- |
| OpenAI-compatible | Chat Completions SSE, Bearer, system message, `max_tokens`, JSON object/schema modes, optional `include_usage`, choice 0, usage-only tail, `stop` plus `[DONE]` required |
| Anthropic Messages | `x-api-key`, fixed `anthropic-version: 2023-06-01`, top-level system, block index/type tracking, cumulative start/delta usage, legal stop reason plus `message_stop` required |
| Gemini GenerateContent | Header-only `x-goog-api-key`, `/v1beta/models/{model}:streamGenerateContent?alt=sse`, top-level systemInstruction, generationConfig JSON MIME, candidate 0, STOP plus complete EOF and optional tail usage |

OpenAI-compatible root URLs receive `/v1`; a nonempty base path is the API prefix.
Anthropic/Gemini append `/v1` or `/v1beta` unless that is already the last path
segment. Profiles contain base URLs, not complete operation endpoints. Protocol
queries are constructed natively; Profile base URLs cannot contain any query.

OpenAI `jsonMode` defaults to `automatic` (including an absent legacy field).
Creation and connection checks negotiate `json_schema` → `json_object` → prompt JSON
using the same provider. Calls without a native schema start at JSON object.
`schema`, `required` and `disabled` are fixed modes and do not downgrade.
Creation supplies `template_parameter_output_v1`; the probe supplies `connection_check`
and requires exactly `{"ok":true}`. The returned connection result includes the
actual mode, model, request count, usage and elapsed time, not merely HTTP success.

A bounded 400/422 error must identify response-format support (parameter or message);
unrelated parameter errors and 401 do not negotiate. Invalid complete JSON shapes can
negotiate as well; native range/resource violations remain content repairs. Every
candidate still passes the same strict native validator. Leading `<think>...</think>`
blocks are filtered incrementally by default, `reasoning_content`/typed thought blocks
are discarded, and one complete Markdown JSON fence is unwrapped. Tags inside JSON
strings remain literal. Unknown/unclosed wrappers, ambiguous text and truncated streams
are refused; filtering never refunds request/token usage.

Negotiation and up to two content repairs share one maximum-three-request ledger.
Negotiation does not require enabling content repair; its counter is persisted separately.
New Profiles default to 24,576 reserved output tokens, with up to 8,192 per request;
smaller configured budgets remain hard limits. The UI treats blank input as the default,
rejects invalid/overflowing input, and shows the default explicitly. Existing stored
limits are not silently rewritten. Unknown usage stays unknown. No raw response,
thought text, key or arbitrary error description enters diagnostic logs.

Anthropic/Gemini retain their native contracts and cumulative usage semantics. Explicit
`requestsUsage = false` omits stream_options without probing. No Responses API, tool
calling or automatic model-name/max-token-field discovery is implemented.

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
