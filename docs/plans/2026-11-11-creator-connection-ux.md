# Creator connection stability and workspace UX

Scope: three atomic commits on `feat/ai-creator`; no production application or desktop actions.

1. Label the native model form, add explicit local model discovery, declare narrow ATS CIDR exceptions, and cache origin/configuration-bound credentials only for network operations. Empty local credentials never read or write Keychain.
2. Retain SSE by default, add bounded OpenAI non-stream fallback, separate first-response/idle/total deadlines, and expose only phase/count progress. Every wire attempt consumes the existing request/token ledger.
3. Consolidate the project sidebar, add prompt-derived names, inline rename and per-turn retry/edit, and build a native multiline composer with model/mode/repair controls and inspiration examples.

Verification: isolated Mock URLProtocol and memory Keychain tests; offscreen native view tests in six languages; targeted checks per commit and one complete routine gate before packaging. No live model requests. ATS plist/CIDR contract and loopback transport are automated; physical LAN permission and macOS 15 hardware checks remain manual. Release packaging must audit all Mach-O minimum versions, dependencies and Ad-hoc signatures, preserve main/latest, and publish a new prerelease.

Status: implementation in progress.
