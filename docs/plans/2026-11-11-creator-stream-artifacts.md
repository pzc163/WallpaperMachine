# Creator LAN, native output limits and streaming artifacts

Three atomic changes on `feat/ai-creator`; no production app or desktop actions.

1. Keep the complete labeled connection form editable, discover models from unsaved local endpoints, preserve optional LAN authentication and declare localized macOS LAN purpose text. Reuse origin validation and narrow ATS CIDRs across all entry points.
2. Support explicit output limits up to 131,072 and server-native output by default, bounded context/usage negotiation, direct HTML/fenced HTML output with legacy decoding, and 256 KiB single-file source. All attempts remain counted; unvalidated code never runs.
3. Display bounded, credential-redacted model reasoning and code only in session memory. Add streamed source and verified embedded-render tabs with cancellation, lifecycle cleanup and independent preview retained.

Verification: Mock URLProtocol/memory credentials, offscreen views and WebKit checks, targeted tests per stage, then one complete routine gate. Release is Ad-hoc, arm64, macOS 15+, prerelease only; preserve main/latest. Physical LAN privacy and visible UI remain device acceptance items.

Status: implementation in progress.
