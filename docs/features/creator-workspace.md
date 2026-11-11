# Native Creator workspace (S2.2 and S3 controls)

S4 adds a native template/free-code mode picker, a separate single-HTML authoring
contract and bounded desktop cursor delivery. Settings now share automatic output
negotiation, a dismissible success banner and explicit LAN mode. See
[the current free-code boundary](creator-free-code.md); the earlier stage evidence
below is historical. Save and Apply remain separate actions.

S2.1 was verified against its recorded file hashes and committed locally on
`feat/ai-creator` as `29cd3086ef81b3046a98a1498029ac200c007483` before this work.
The tree was clean. S2.2 was subsequently committed locally as `35594fb9`.
S3 control preparation starts from the clean S2.3 baseline `6b2350d8`;
nothing is pushed or installed by this work.
This feature uses trusted templates only. It does not unlock S4 execution.

## Ownership and native shell

`PanelController+Creator` owns typed asynchronous actions through the existing
launch/run coordinator. `CreatorModel` is observable presentation state;
`CreatorWorkspace` is the actor handling files, model requests and publication.
Views never access credentials or perform domain IO. The shared image pipeline
verifies a poster against its bundle digest before decoding it off the main thread.

The tabs are Library, AI Creator, Steam Workshop, pixiv, Settings. The creator
uses PageSearchBar, FilterSidebar, InspectorColumn, PanelCard and the same native
button and settings components. The 960-point compact rule prevents the leading
sidebar and trailing inspector from consuming the narrow window together.
Recent projects remain reachable after selecting a project. The first version
has conversation, bounded repair controls and expandable native diagnostics;
there is no source editor.

## Three explicit actions

1. Generate: `createForPreview` produces parameters, static evidence, a real
   offscreen WebKit capture and a sealed four-file revision. It ends the turn
   only with matching publication-grade evidence. It does not import anything.
2. Save to wallpaper library: the explicit action uses CreatorPublisher and the
   existing importer, records the runtime policy and refreshes the library.
3. Apply to display: requires the selected revision to match the installed registry
   binding, checks the installed bytes again and uses the existing target-display
   action. Saving or selecting a history entry never calls this action.

The original createAndSave API still serves its existing tests and opt-in smoke.
Completing from sealing is permitted only with full runtime evidence and matching
iteration/source identities. Reports are not manufactured by changing status.

Parameter controls use the catalog's native types, ranges and localized labels.
Edits update only an open temporary preview. Validate changes creates an immutable
child revision and runs native runtime capture again; save/apply stay disabled
while values differ. A failed runtime check retains the previous valid selection.

The Presets menu takes its entries and complete values from the selected
revision's native template definition. Selecting one replaces the whole parameter
dictionary in one validated controller action and updates an open preview, including
a paused preview. Unknown presets, a different template, busy operations and cancelled
edits are refused before changing values. Neither revisions nor installed bytes change.
Validate changes still creates and fully checks a new revision before publication;
selecting values identical to the current revision does not invent a dirty state.

## Composer and project navigation

Search and New live only at the top of the project sidebar. The workspace contains
the current title with inline Return-to-save/pencil rename, conversation, and one
native multiline composer. The sidebar keeps rename/copy/delete context actions;
collapsed layouts use the existing sidebar toggle, without a duplicate project list.

The plain NSTextView grows from three to eight lines and scrolls beyond that. Return
sends; Shift-Return inserts a newline; marked text and modifier combinations stay
with the input method. Model selection, template/code mode, repair count and send/stop
share the composer footer. Edit-and-resend restores a failed/cancelled/interrupted
turn's original sanitized prompt and focuses the composer; Retry uses that prompt
with the currently selected Profile/mode and the current validated base. Neither
action rewrites the old turn. Four localized inspiration cards fill the composer
without making a request. A successful generation clears its submitted prompt.

The first submitted prompt names an untouched default project using up to 18
characters after common filler prefixes. This uses already-redacted text and writes
`display-name.json`, outside immutable identity/digests. Existing names, explicit
renames (even back to the default name), conversations and historical revisions
are preserved. Views do no storage, credential, preview or network operations.

## Projects and history

Display names use a versioned `display-name.json` alongside project metadata;
this is workspace presentation, outside source identity. Existing renameProject
semantics and metadata-tampering assertions remain unchanged. Native duplication
assigns a new UUID, rebuilds the selected parameters and captures fresh evidence;
it does not copy credentials or publish automatically.

Deletion requires confirmation. The directory is atomically renamed to
`.deleted-<UUID>` before recursive cleanup; recovery validates the tombstone's
project identity and completes cleanup. Installed wallpaper bytes and independent
registry bindings stay intact. Publication recovery validates installed bytes even
when the source project was deliberately deleted. History entries are immutable;
rollback only changes the selected work/preview pointer.

## Connections and cancellation

Settings uses aligned visible labels (stacked in narrow windows), a local/LAN Base URL hint,
and explicit cancellable model discovery with a selectable result list. Changing the draft
cancels discovery and ignores stale results.

Settings adds Provider Profile CRUD and active selection, all three codecs,
endpoint/model, request budget 1–3 and token budget 1–100000. An entered key is
bound explicitly through ProviderCredentialStore; views never read it back. A
changed target clears the field, saving rotates the configuration generation,
and old requests are cancelled. An empty field never approves a previous key for
a new configuration. Explicit local OpenAI mode uses the loopback/LAN allowlist in [model connections](creator-llm.md).

OpenAI-compatible profiles expose **JSON output mode**: Automatic (with fallback),
JSON Schema (strict), JSON object (required), and Prompt only. An absent mode still
displays Automatic without rewriting legacy metadata. The choices store the existing
`automatic/schema/required/disabled` values; changing a saved mode rotates its
configuration generation and cancels old requests, so remote credentials need explicit
rebinding. Explicit local mode with an empty key bypasses Keychain entirely.
Gemini displays its native JSON response-format policy and Anthropic its prompt JSON
contract instead of offering OpenAI-specific switches. None of these modes bypasses
the strict native parameter validator. The eight added labels/notes and existing
preset names cover all six app languages.

Test connection asks for confirmation with the saved target, model and possible
charge. It uses the same bounded three-mode negotiation as creation, within the
saved request/token budget; cancel remains available. Success displays a dismissible
native top banner with model, effective output mode and elapsed time. New tests and
configuration edits clear stale success. Blank token input uses a 24,576-token total
reservation, up to 8,192 per request. Its temporary project is removed and
no response text is saved. Cancelling does not refund an already sent request.
Classification text and native diagnostic fields exclude secrets and sensitive
paths. Token output reservations are not a monetary cap; absent usage is Unknown.

## Preview and lifecycle

Only the explicit preview action, with a presenting panel window, creates the
independent AppKit window. It uses CreatorPreview's checked snapshot, starts muted,
supports pause/resume and 16:9, 16:10 and 9:16, and stops on close. Loading has a
30-second deadline. Opening another revision closes the previous preview.

The first PanelController.start runs publication recovery then job/conversation
recovery, loads metadata and exposes the result. Reentrant recovery uses one task.
It never resolves credentials or sends a model request. S2.2 originally integrated only
controller startup. S2.3 adds headless bootstrap recovery and coalesces both entry points;
see [creator-acceptance.md](creator-acceptance.md). Corrupt registry or installed content
is reported and refused; no ordinary Web-policy fallback exists.

## Storage boundary

The old backup/move format cannot atomically preserve all Creator data and policy.
This version explicitly refuses backup export/restore and storage moves when it
finds CreatorSettings, CreatorRuntimeRegistry, Creator source/job data or AI library
projects. A shared file lock and a durable `.CreatorWorkspacePresent` marker fence
the first Creator write against backup or move preparation. Pending move/restore
transactions prevent new Creator mutations. The marker remains conservatively
after all drafts/connections are deleted; automatic removal awaits a complete
transaction-format upgrade. Empty startup lock directories do not block normal
backup or move use. Keys are never backed up.

Checks run at move planning, preparation and startup completion, and at backup
preview/staging/export and startup restore. Old backups containing AI wallpapers
are refused. Existing non-Creator backup and move behavior retains its regressions.
This is a documented refusal boundary, not support for copying Creator to a new disk.

## Verification and limits

S3 controls: `CreatorControlsTests` covers all six presets through an unattached real
WKWebView, unchanged published/history bytes, revalidation and save/apply gates;
`CreatorModelSettingsTests` covers all four persisted modes, credential reapproval,
in-flight cancellation, stale saves, and offscreen controls/layout in six languages.
These tests use local Mock responses, memory credentials and temporary files only.
Visible controls, real Keychain, multi-display use and energy remain S3 manual work.
S3 control gate (2026-11-11): 708 Python and 5,000 native tests passed, zero failed,
72 skipped; the full routine gate ran once. The skips remain the 62 media/device,
three Steam-network, one reference, three S0 unrestricted, and three Creator
live/benchmark/soak opt-ins. Two runtime warnings remain in the result bundle.
The final preset-focused rerun passed all three tests; the preceding four-suite
run passed the other 24 and two preset cases but exposed a missing fake library
snapshot in the publication test. The fixture was corrected before the full gate.
An earlier compile attempt resolved a stale xcrun Metal path cache; the installed
toolchain was reused without a download. Localization (17 checks), documentation
links (11 checks), and the external handbook/checklist checks passed separately.
Release construction follows the authorized local commit; no visible app launch,
installed-app shutdown, real credentials, live model calls or desktop action occurs.

Historical S2.2 verification: 695 Python tests and 4,962 native tests passed,
zero failed and 70 skipped. All 27 new workspace/boundary/controller tests passed.
The final controller-focused run passed 11 tests. Broader targeted runs recorded
211 passed/3 skipped, storage 71 passed, and deletion/recovery 38 passed.
The full gate was started three times: an audit interruption (exit 73, not accepted
as passed), then one unchanged WebKit navigation test failure (exit 65), then a
passing full retry after its isolated recheck passed. The failure reported Cannot
open file during replaced file loads; its cause remains unresolved. No source,
assertion or threshold changed between that failure and the final rechecks.
Source/test/generated-project hashes matched before and after the final gate.
The 70 skips are three S0 unrestricted probes, 62 opt-in media/device checks,
three Steam network checks, one reference job and one creator live smoke. Routine tests use
Mock URLProtocol, isolated memory credentials, temporary storage and offscreen
WebKit. Native layout checks do not display windows or capture the desktop.
Six languages and catalog-derived control labels are maintained. Visible
appearance matching, VoiceOver, real Provider/Keychain use, standalone preview
window interaction, live desktop application and long-run performance remain
unverified without a separately authorized manual run. S0 unrestricted download,
EventSource and media probes remain skipped and S4 remains closed.

Related: [02 PRD](../plans/02-creator-prd.md), [03 technical plan](../plans/03-creator-technical-plan.md),
[05 stage plan](../plans/2026-11-10-creator-s1-s4.md), [test policy](../testing/README.md).
