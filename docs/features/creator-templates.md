# Creator parameterized templates

S1.0 extends the [S0 service workflow](creator-s0.md) with three native-owned
Canvas2D templates. It adds no creator UI, model connection, arbitrary source
input, cover file or desktop activation. The remaining work is tracked in the
[S1/S4 plan](../plans/2026-11-10-creator-s1-s4.md).

## Catalog and controls

`App/Services/Creator/CreatorTemplateCatalog.swift` owns the IDs, typed values,
parameter domains, defaults, units, control definitions, presets and budget.
`CreatorTemplateRenderer.swift` contains the fixed rendering kernel. A complete
parameter dictionary is required; unknown/missing fields, wrong JSON types,
nonfinite or out-of-range numbers, fractional layer counts and unknown enum
values are rejected before any source is generated. Runtime property patches
accept only values in those same domains and ignore invalid entries.

| ID | Parameters | Presets |
| --- | --- | --- |
| `gradient-v2` | 10 | Aurora ribbons; Ember haze |
| `stars-v2` | 12 | Quiet orbit; Meteor voyage |
| `clock-v2` | 10 | Dawn dial; Night terminal |

Each control ID maps directly to its parameter ID. The catalog generates
`project.json` sliders, booleans and combos with their defaults and order. Slider
steps describe UI increments; only the layer count is restricted to integers.
Native label tokens use the existing inspector localization path; option labels,
template names and preset names are in the app catalog in every shipped language.
No bundle byte depends on the currently selected UI language.

| Template | Parameters and accepted values |
| --- | --- |
| All | `primaryHue`, `secondaryHue`: 0–360 degrees; 0 and 360 are the same color |
| Gradient | `angle`: 0–360 degrees; `contrast`, `waveStrength`, `grainAmount`, `vignette`: 0–1; `motionSpeed`: 0–2; `waveScale`: 0.5–4; `breathingHz`: 0–2 Hz |
| Stars | `starDensity`, `starSizeSpread`, `trailLength`: 0–1; `parallaxLayers`: integer 1–4; `twinkleHz`: 0–3 Hz; `meteorRate`: 0–6 events/minute; `motionSpeed`: 0–2; `clockVisible`: boolean; `clockAnchor`, `clockScale`: as below |
| Clock | `backgroundMotion`: 0–2; `clockAnchor`, `clockScale`: as below; `hourFormat`: `12h`/`24h`; `showSeconds`, `showDate`: booleans; `font`: `system`/`serif`/`monospace`; `glow`: 0–1 |
| Clock placement | `clockScale`: 0.5–1.5; `clockAnchor`: `topLeft`, `topCenter`, `topRight`, `middleLeft`, `center`, `middleRight`, `bottomLeft`, `bottomCenter`, `bottomRight` |

Clock text is drawn into the same canvas using built-in fonts and the local
date/time format. No font downloads, DOM text assets, expressions or user source
are accepted. The seed is fixed by the template revision; rendering comparisons
use an injected test clock without adding a production script-execution seam.

## Compatibility and publication

The S0 three-file bundle remains the only package format in this step:
`creator.json`, `project.json`, `index.html`. The specification's existing
`version: 1` is the **bundle/policy version**, not the suffix of a template ID.
Optional `templateID` and `parameters` select a catalog template. Without either,
the original S0 generator and its exact bytes are retained. Mixed legacy hue/speed
customization and catalog fields, mismatched kinds and unknown revisions fail
closed. The old `creator-s0-<uuid>` identity prefix is retained for host routing.

`CreatorDraftStore` still reconstructs and compares all bytes before loading or
importing. An unrecognized metadata field or duplicate key cannot be preserved
by reconstruction, even if JSON decoding accepts it. The same hash/CSP/resource
host is used for the new kernels. Template byte verification is not proof that a
kernel has no bugs; the existing unrestricted-code probes remain unresolved.

`CreatorPreview` now derives the initial properties from the catalog for enhanced
templates. The existing publisher imports them and can recover the exact legacy
bundle after an interrupted replacement. No migration is performed in place. Once persisted, changes to a kernel, budget
or serialized control contract require a new template ID and retention of the
old generator.
Production revision history, four-file packages, native JPEG covers and separate
runtime registration remain in S1.1/S1.4.

## Resource and lifecycle limits

The initial native budget is fixed for these template IDs:

| Resource | Limit |
| --- | --- |
| Star particles, across all layers | 384 |
| Trail segments, across all particles | 1,536; at most 8 per particle |
| Concurrent meteor slots | 2; slots divide the requested emission rate |
| Canvas pixel area | 2,073,600 pixels |
| Either canvas dimension | 4,096 pixels |
| Device scale | 2× maximum; further reduced to meet area/dimension limits |
| Paint rate | 30 FPS maximum, including coalesced parameter/resize redraws; lower host ceilings honored |
| Gradient ribbons / grain samples | 12 / 128 |

The layer count partitions the same particle array. Trail allocation is reduced
when density would otherwise exceed the total segment budget. Zero density and
zero meteor rate disable their respective effects. A fixed-seed cadence produces
the requested mean meteor rate, rather than multiplying emissions by layer count.
Long frame gaps advance animation by at most 100 ms to avoid catch-up bursts.

Animation uses `requestAnimationFrame`. First paint and parameter/resize changes
also have an on-demand path: bursts coalesce under the same ceiling, and there
is no timer-driven animation loop. Dimensions change only when a replacement
frame is drawn, avoiding a cleared canvas between throttled frames. Pausing
stops the animation callback chain but permits bounded edit redraws; `pagehide`
cancels pending frame and redraw work. The existing native stop/generation fence
remains responsible for replacing the document and discarding late loads.

The current native host detaches paused views. Container size changes take effect
when the view is reattached on resume. The unattached WebKit view in this machine's
tests did not receive animation frames; Apple's
[inactive scheduling policy](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)
documents task suspension outside a window. The implementation preserves that
host policy. Offscreen first paint and property edits are tested with real timing;
animation phase, cadence and FPS use a controlled clock in the actual WKWebView.

These are bounded renderer workloads, not OS CPU/GPU quotas or an arbitrary-code
watchdog. There is no measured battery, memory or frame-time claim. At large
display sizes the fixed pixel budget reduces drawing resolution.

## Verification

`CreatorTemplateCatalogTests` covers strict types/ranges/key sets, combined
allocation, property serialization, localized labels, pinned legacy bundle
digests, unknown revisions, altered bytes and enhanced-import recovery.
`CreatorTemplateRenderingTests` runs in unattached real WKWebViews and covers:

- Pixel changes for each of the 32 parameter dimensions, including time-dependent
  effects with a fixed clock; circular hue/angle comparisons use distinct angles.
- Two distinct presets per template (sampled mean RGB difference greater than
  5/255), and repeatable output at the same seed, time and viewport.
- All-minimum/default/all-maximum combinations and every enum choice.
- Actual draw-call counts, aggregate particle/trail/meteor caps, 30/10 FPS
  ceilings (including the host's zero/unlimited setting), and large/wide/tall
  canvas limits with proportional scaling.
- Meteor cadence at 0, 1 and 6 events/minute over a simulated minute.
- Native property delivery, rejected capability expansion, pause/edit/resize/
  resume/stop, burst coalescing and cancellation on `pagehide`.
- Real-clock first paint and edit redraws without changing inactive scheduling.

The S0 draft, preview, publication, recovery and security regression tests remain
in the gate. The three opt-in unrestricted-source probes remain skipped by the
routine run for their recorded S0 failures; no S4 claim follows from S1.0.
Visible desktop animation, subjective visual quality, real-device load and
multi-display behavior still need separately authorized manual verification.

The 2026-11-10 final targeted run passed 43, failed 0 and skipped the 3 S0
probes. The full routine gate ran once after implementation: 687 Python tests
passed; native results were 4,767 passed, 0 failed and 69 skipped (4,836 total).
The 18 new S1.0 tests all passed. The 69 skips comprise the 3 S0 probes, 62
opt-in media/device tests, 3 live Steam tests and 1 reference-render job.
Two main-thread runtime warnings were attached to the unchanged
`VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne()`
and `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`; the
result did not provide source locations. They were recorded, not fixed here.
