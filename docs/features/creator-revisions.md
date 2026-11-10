# Creator projects and immutable revisions

S1.1 adds native storage services to the [template workflow](creator-templates.md).
It implements the storage portions of PRD AC-02 (derive and return to a revision),
AC-07 (cancel/reopen) and AC-10 (invalidate changed evidence). It adds no creator
UI, screenshot capture or desktop activation. Model transport was subsequently
added by [S1.2](creator-llm.md), with no UI or startup wiring. See the
[PRD](../plans/02-creator-prd.md), [technical plan](../plans/03-creator-technical-plan.md)
and [stage plan](../plans/2026-11-10-creator-s1-s4.md).

## Owned paths and records

Paths come from `ClientPaths`; tests inject temporary roots. A default store
checks storage availability before creating anything and refuses to continue if
the selected storage root changes. It does not fill a replacement library when
an external disk is missing.

```text
supportURL/CreatorSettings.json          # nonsecret profiles; stays on this Mac
supportURL/CreatorRuntimeRegistry.json
storageURL/Creator/
  Drafts/creator-s0-<uuid>/             # existing S0/S1.0 source, unchanged
  Projects/<project-uuid>/
    project-meta.json
    Revisions/<revision-uuid>/
      revision.json
      validation.json                  # replaceable evidence, not bundle content
      bundle/
  Jobs/<job-uuid>/
    job.json
    .lease
    partial.bin                        # bounded opaque input, never executable
    candidate/revision.json
    candidate/bundle/
  Publication/                         # existing S0 journal; not renamed
```

Every native record is Codable JSON with a versioned envelope
`{schemaVersion: 1, payload: ..., digest: ...}`. Payloads also declare their own
version. Encoding is canonical (sorted keys); reads verify the payload checksum
and exact re-encoding. Unknown versions, unknown/duplicate fields, noncanonical
bytes and malformed records fail closed. Records are at most 256 KiB.

| Record | Responsibility |
| --- | --- |
| `CreatorProject` | Identity/title, ordered revision IDs, latest/last-validated/selected pointers, published ID reservation, active job |
| `CreatorRevision` | Immutable parent/provenance, template identity/revision, normalized parameters, bundle/SDK/policy versions and digests |
| `GenerationJob` | Project/base revision, token, durable state, attempts/budgets, candidate identity and digest |
| `ValidationReport` | Exact revision metadata, project identity, content digests, template revision, host/SDK/policy/profile/viewport and measured results |
| `CreatorSettings` | Nonsecret Provider Profile metadata, selection and optimistic settings revision; configured through `CreatorSettingsStore` |
| `CreatorRuntimeRegistry` | Installed legacy ID to revision/digest/policy/context binding; new v2 publication remains blocked |

JSON replacement writes a unique sibling, synchronizes the file, then renames
it atomically. Actor serialization and a nonblocking filesystem lock protect
cooperating writers across store instances. Reads reject symlinks in owned paths,
nonregular files and hard links. This is process-interruption recovery, not a
claim of power-loss durability, authenticated signatures, OS filesystem isolation
or protection from a local actor that can rewrite all files and recompute hashes.

## Settings and provider metadata

`CreatorSettingsStore` owns `supportURL/CreatorSettings.json`, separate from
movable wallpaper storage. It uses the same checksummed Codable envelope,
256 KiB read/write cap, atomic sibling replacement and filesystem lease as the
revision services. It does not cache a stale document between calls. A missing
file returns empty settings; a corrupt, linked, oversized, unknown-version or
unknown-field record throws and is preserved, never replaced with defaults.

The payload has its own schema version, a settings revision, up to 32 unique
profiles and an optional selected ID that must exist. Every mutation requires the
expected settings revision under the file lock; concurrent/stale writers receive
`busy` or `staleSettings` and must reload before retrying. Cancellation immediately
before rename and failed writes preserve the previous record. Reads observe the
old or new complete file. It has the same process-interruption, not power-loss,
durability boundary as the revision store.

Each `ProviderProfile` contains schema version, stable ID, name, protocol enum,
base URL, model, explicit local mode, capability overrides and bounded request/token
budgets (1–3 / 1–100,000). `requestsUsage` and `filtersLeadingThinkBlock` are
OpenAI-compatible overrides; S1.2 adds optional `jsonMode` (automatic, required,
disabled). Missing values preserve S1.1 canonical record bytes and mean automatic.
The other protocols require their standard values.
A saved profile starts at configuration revision 1. A changed profile increments
that revision and receives a new random configuration ID. Old handles are rejected;
selection alone and a no-op save do not rotate a profile. Reusing a deleted profile
ID still receives a new configuration ID, preventing stale-handle revival. Editing
one profile does not affect another profile even at the same host.

URLs are ASCII base URLs, at most 2,048 bytes, with no userinfo, query or fragment.
This intentionally rejects all base-URL queries; S1.2 codecs add protocol
queries such as Gemini `alt=sse`. The default is HTTPS. HTTP is valid only for
explicit local OpenAI-compatible profiles with exact normalized hosts `127.0.0.1`,
`localhost` or `::1`; neither DNS resolution nor other loopback representations
expand that list. Name/model limits are 60 characters/128 UTF-8 bytes; Gemini
models additionally use a single ASCII path segment. The origin value compares
scheme, normalized host and effective port; it is not credential authorization.

There is no key field, arbitrary authentication-header field or approval flag.
The [S1.2 credential service](creator-llm.md) binds Keychain credentials to profile
ID, origin and configuration identity. `withCurrentProfile` rechecks a full saved
snapshot under the settings file lock before a suspended task resumes. Atomic
profile replacement notifies active native requests before rename; a failed rename
can conservatively cancel an old request but never authorize a new host. The
settings JSON cannot certify a new host as approved. Jobs do not persist provider
secrets; the active request owns its profile snapshot and no request auto-resumes
after application restart.
The settings service, like the revision services, has no app-startup integration
or settings-backup support yet.

## Content and evidence binding

`CreatorTemplate.digest` is unchanged: sort relative paths, hash each UTF-8 path
length, path, content length and actual bytes with SHA-256. Sizes/mtimes are not
used as content evidence. v1 golden digest assertions remain unchanged.

- `bundleDigest` covers every exact bundle file, including metadata and a poster
  when present. Additional/missing files are invalid, not ignored.
- `renderDigest` for v1 equals its existing bundle digest. For v2 it hashes the
  native render-draft reconstruction, excluding only the sealing/poster changes.
- `posterDigest` hashes the JPEG bytes, after native decoding and limits.
- `revisionDigest` hashes the exact checksummed `revision.json` bytes. The report
  also binds project ID/creation/title. Mutable history/selection pointers are
  deliberately excluded from that identity, so adding a revision or rolling back
  does not invalidate unchanged older evidence. Their record checksum still
  detects edits outside the native writer.

`validate` currently issues only `template-structure-v1` evidence: reconstruction,
structure and trusted-template policy pass; runtime and poster capture are
explicitly `notChecked`. `lastValidatedRevisionID` refers to that named profile,
not final publication approval. Changed content, provenance, title, host version,
SDK/policy/profile or viewport requires validation again. Recovery does not
fabricate replacement reports. The preview receives the same frozen bytes that
were checked against the report, and repeats the check on every page reload.

## Revision and job transactions

`createProject` creates an empty project. `beginJob` records an explicit optional
base revision; `stage` constructs native-owned files, then `commit` moves a
complete candidate into the revision directory and atomically updates the project
index. There is no API to replace a committed revision's bundle or metadata.
`importLegacy` copies verified old bytes into a v1 revision without modifying the
source; upgrading creates a separate v2 child. `select` requires current evidence
and changes only the project selection, never an applied wallpaper.

The project index replacement is the commit point. Before it, a candidate folder
alone is not history. Afterwards, a finishing job-journal write may be replayed
without creating a duplicate revision. A saved but unvalidated new revision does
not replace the last validated selection.

```text
generating -> staged -> committing -> completed
          \-> cancelled
          \-> interrupted (restart without a live owner)
```

Only one job is active per project. Its `jobID + projectID + cancellationToken`
and persisted active pointer fence late callbacks. Starting a newer job cancels
the old one. Attempts cannot exceed the configured 1–3 request budget; token
budget metadata is bounded to 1–100,000. S1.2 atomically reserves request attempts
and maximum output tokens before sending; failed attempts are not refunded. The
optional `reservedOutputTokens` field preserves old canonical bytes when absent,
and old jobs with attempts but no reservation history cannot start another request.
This is an output reservation, not a provider billing limit. Cancelling/superseding
a job synchronously cancels matching in-process flights. Partial input is capped at
16 KiB; S1.2 never writes raw streaming input into it. Projects hold at most 1,000
indexed revisions; retention/garbage collection is not implemented.

Each live owner holds an OS file lease. `recover()` skips jobs with a live lease,
interrupts unfinished abandoned jobs, discards their partial/candidate files and
removes an uncommitted moved revision only after verifying its ownership/digest.
After the project commit point it completes the job instead. Repeated recovery is
idempotent. Cancellation cleanup also works in a cancelled Swift task.

Recovery rechecks indexed revisions and selects the last valid reported revision
when the current selection is no longer valid. An explicit valid older selection
is preserved. Corrupt committed bytes and corrupt journals are retained for
inspection and returned as invalid IDs; they are not overwritten. A corrupt job
cannot permanently retain the project's active pointer. Recognized temporary
JSON siblings left by interrupted atomic replacement are removed; the previous
authoritative record stays intact. Invalid project metadata is reported, not
guessed. An interrupted initial project creation can leave a hidden `.pending-*`
directory; it is not listed as a project and needs future maintenance cleanup.

## Package versions and routes

The original `CreatorTemplate.Specification.version: 1` generator is frozen.
Its exact three files and `creator-s0-<uuid>` identity still work without migration.
The optional S1.0 template IDs continue to select their fixed native generators.
Model output schema versions remain separate; provider/model/output-contract
fields are nil for these native S1.1 revisions.

| Format | Exact allowed files | Route |
| --- | --- | --- |
| v1 | `creator.json`, `project.json`, `index.html` | Existing S0 preview/import/publish/recovery |
| v2 render draft | Same three names, versioned manifest | Validated revision preview only |
| v2 sealed format | Those three plus `preview.jpg` | Format validation only in S1.1; publication waits for S1.4 |

The v2 manifest separately declares schema/bundle/policy/SDK versions, template
specification, `trustedTemplateV1`, native packaging state and poster digest.
Its publisher ID is reserved as `ai-<project-uuid>`. The native format builder can
validate an already supplied JPEG (512 KiB, 1–1280 pixels per edge, one complete
decodable JPEG image) and reconstruct `project.json.preview`. Tests use a synthetic
JPEG fixture; this is not template snapshot generation. S1.4 must derive a new
sealed revision and final report; it must not mutate an existing render draft.

Both `CreatorPublisher` and ordinary folder import reject v2 packages until that
final flow exists. Formal preflight rejects them as well, including forged type
changes. A `creator.json` marker or reserved creator/AI ID selects the restricted
WebKit host before loading; renaming a bundle cannot select the compatibility
file host. New v2 previews use the revision store loader and immutable scheme
resources. Unknown policy/versions, registry corruption or mismatched restored
bytes block loading. Lockscreen/screensaver publication continues to refuse all
creator routes, including renamed marker-bearing folders.

`registerLegacy` registers an already installed, validated v1 copy. It performs no
import or desktop action. A matching registry entry tightens legacy playback to
the recorded digest/context; an absent entry preserves the original S0 byte
validation behavior. Full registry/publisher transactions for v2 belong to S1.4.
No S4 networking/download/independent-process claim follows from these routes.

## Deterministic render-test synchronization

The first full gate of the settings supplement exposed an existing pixel-test
race. Navigation completion preceded asynchronous native state delivery; a late
`setPaused(false)` reset the template animation clock after the test had already
advanced its simulated frames. A controlled 200 ms delivery delay reproduced the
pixel mismatch before the fix. The test harness now observes actual property,
FPS and pause delivery before stepping, and waits for the pause acknowledgement
before reading pixels. A bounded wait throws on missing delivery; it does not
replace assertions with sleeps or retries. The new regression compares immediate
and delayed replay for all three templates. Production kernels, template versions
and golden byte-digest assertions remain unchanged.

## Verification and remaining boundaries

`CreatorSettingsStoreTests` and `ProviderProfileTests` additionally cover all three
metadata variants, exact local-address policy, origin comparison, resource bounds,
independent same-host profiles, generation fencing, restart, concurrent writers,
failed/cancelled atomic writes and invalid/unknown/secret-field records. These
16 tests do not perform network requests or access the personal Keychain.

`CreatorRevisionStoreTests`, `CreatorStorageFormatTests` and
`CreatorRuntimeRegistryTests` cover immutable derivation, rollback, source-byte
and metadata tampering, budgets, stale callbacks, live leases, cancellation,
restart commit boundaries, stale evidence, atomic-write interruption, corrupt
journals, path/link rejection, legacy migration, v2 whitelist/poster decoding,
registry rejection and an unattached real WKWebView revision preview/reload.
Affected import, preflight and lock-screen tests run with the existing S0/S1.0
regressions. The lock-screen tests use injected stores/provider actions; they do
not enable a real desktop provider.

The settings supplement's final targeted run passed 231, failed 0 and skipped 3.
The first full gate passed 4,809 native tests, failed the existing preset pixel
reproducibility test and skipped 69. After the controlled-delay reproduction and
test-only synchronization fix above, the permitted full-gate retry passed 687
Python tests and 4,811 native tests, failed 0 and skipped 69 (4,880 native total).
All 16 metadata tests and the added delayed-replay regression passed. This run
recorded three main-thread runtime warnings: the two cases listed below and
`WebMOpeningTests.testAVp9FileOpensWithItsFormatSizeAndLength()`. Those tests passed;
their production code was not changed. No further full-gate run was performed.

The initial 2026-11-10 revision-storage targeted run passed 214, failed 0 and skipped the three S0
probes. One full routine gate passed 687 Python tests and 4,794 native tests, with
0 native failures and 69 skips (4,863 total). All 27 S1.1 additions passed. Skips
were 3 S0 probes, 62 opt-in media/device tests, 3 live Steam tests and 1 reference
render job. The result retained the same two main-thread runtime warnings as S1.0,
in `VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`
and `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`; no source
locations were supplied. These unrelated warnings were recorded, not fixed here. The three known S0 unrestricted-code probes remain unresolved/opt-in.
Visible UI, desktop effects, actual screenshot capture, energy/load, real model
calls and publication of new v2 revisions are not covered by this stage.

Workspace recovery is an explicit service call, ready for the future creator
entry; S1.1 adds no app-launch/UI wiring. Creator workspace and runtime registry
are not included in the existing settings backup format. `Creator/` is not yet
part of `StorageLocation.movedItems`; storage migration of creator history is
unsupported in this service-only stage. Do not use the existing storage move or
backup operation as a creator-history backup. Integrate those transactions and
their tests before exposing a persistent creator UI.
