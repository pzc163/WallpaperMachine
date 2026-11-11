# Creator connection stability and workspace UX

Scope: three atomic commits on `feat/ai-creator`; no production application or desktop actions.

1. Label the native model form, add explicit local model discovery, declare narrow ATS CIDR exceptions, and cache origin/configuration-bound credentials only for network operations. Empty local credentials never read or write Keychain.
2. Retain SSE by default, add bounded three-protocol non-stream fallback, separate first-response/idle/total deadlines, and expose only phase/count progress. Every wire attempt consumes the existing request/token ledger.
3. Consolidate the project sidebar, add prompt-derived names, inline rename and per-turn retry/edit, and build a native multiline composer with model/mode/repair controls and inspiration examples.

Verification: isolated Mock URLProtocol and memory Keychain tests; offscreen native view tests in six languages; targeted checks per commit and one complete routine gate before packaging. No live model requests. ATS plist/CIDR contract and loopback transport are automated; physical LAN permission and macOS 15 hardware checks remain manual. Release packaging must audit all Mach-O minimum versions, dependencies and Ad-hoc signatures, preserve main/latest, and publish a new prerelease.

Status: all three implementation stages complete and routine gate passed.

## Verification results

- Settings/credentials/model discovery: 21 targeted native checks passed.
- Streaming/protocol/repair/code flow: 53 checks passed; final header/idle boundary rerun: 12 passed.
- Workspace/controller/six-language layouts: 29 passed; expanded composer suite: 5 passed, including native three-to-eight-line growth and scrolling.
- Full gate: 720 Python checks and 5,048 native checks passed, 0 failed, 69 intentionally skipped; 2 runtime warnings remain. The first full run found two obsolete benchmark assertions tied to the old 60-second deadline; those now test independent 25/90/300-second defaults and the complete rerun passed.
- No live model/API calls, personal model Keychain access, visible app launch or desktop changes. Physical LAN privacy authorization, macOS 15 hardware and visible UI/IME behavior remain device acceptance items.
- Release target: `creator-ux-preview-20261111`, Pre-release only, never main/latest. DMG SHA-256, Ad-hoc signatures, dependency/ABI and minimum-macOS evidence are supplied with the release assets. Four README languages and the public testing guide describe the update.
