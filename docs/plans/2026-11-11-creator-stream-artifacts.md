# Creator LAN, native output limits and streaming artifacts

Three atomic changes on `feat/ai-creator`; no production app or desktop actions.

1. Keep the complete labeled connection form editable, discover models from unsaved local endpoints, preserve optional LAN authentication and declare localized macOS LAN purpose text. Reuse origin validation and narrow ATS CIDRs across all entry points.
2. Support explicit output limits up to 131,072 and server-native output by default, bounded context/usage negotiation, direct HTML/fenced HTML output with legacy decoding, and 256 KiB single-file source. All attempts remain counted; unvalidated code never runs.
3. Display bounded, credential-redacted model reasoning and code only in session memory. Add streamed source and verified embedded-render tabs with cancellation, lifecycle cleanup and independent preview retained.

Verification: Mock URLProtocol/memory credentials, offscreen views and WebKit checks, targeted tests per stage, then one complete routine gate. Release is Ad-hoc, arm64, macOS 15+, prerelease only; preserve main/latest. Physical LAN privacy and visible UI remain device acceptance items.

Status: all three stages implemented and verified. Stage 1: 14 targeted checks passed. Stage 2: 56 checks passed in the initial run (two new fixture expectations were corrected); the corrected/expanded targeted run passed 9 checks. Stage 3: 31 initial targeted checks passed; later focused suites covered failed-stream usage, lifecycle, unchanged revision budgets and escaped-credential rejection. The final focused run passed 11 checks.

Final routine gate: `python3 scripts/test.py` passed 720 Python checks and 5,066 native tests, with 0 failures and 69 conditional skips. The native run reported two system API main-thread runtime warnings. Documentation links and six-language catalog checks passed within the gate. No live model, benchmark, soak, personal model Keychain, visible desktop, Rust or renderer check was run; this change touches Swift, resources and documentation only.

Verification history: an obsolete 100,001-token rejection fixture was updated to use the new declared maximum. A full run then encountered a GPU energy-counter threshold failure; its isolated suite passed 13 checks without changing the threshold. A subsequent full run passed. After adding the decoded-credential regression, another run encountered `Cannot open file` in the existing replaced-navigation WebKit test. Its unchanged isolated suite passed 10 checks, followed by the final unchanged full-gate pass above. These transient failures are recorded, not treated as passing results or removed from the gate.

Release scope: Ad-hoc arm64 macOS 15+ prerelease, no main/latest update or local installation. Physical macOS 15 LAN permission, visible UI/input methods, heterogeneous displays, sleep/wake and full-system energy remain explicit device acceptance items in the [public test guide](../testing/creator-s4-public-test.md).
