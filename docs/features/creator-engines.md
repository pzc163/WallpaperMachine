# Creator engine foundation (S5.1)

S5.1 keeps the existing opaque code iframe, independent WebContent supervision,
30 FPS scheduler, 2,073,600 canvas-pixel ceiling, immutable four-file bundles and
publication registry. The owning implementation plan is
[creator-s51-engines](../plans/2026-11-11-creator-s51-engines.md).

## Offline library contract

`CreatorLibrary` serves only exact versioned entries in its native asset map.
`wm-lib://three/bundle.js` is a classic-script IIFE exposing `WMLib.THREE` and
RoomEnvironment, EffectComposer, RenderPass, UnrealBloomPass and OutputPass.
Three.js r180 is pinned to its npm SHA-512 and bundled SHA-256; the MIT license,
entry point and reproducible build record live in `ThirdParty/three/`.
`python3 scripts/bundle_creator_libraries.py` verifies bytes without network;
`--rebuild` explicitly downloads pinned build inputs and verifies identical output.

Only native-owned Creator WebViews register the scheme. Queries, fragments,
encoded aliases, path traversal, non-GET methods and unknown paths are refused.
CSP adds only `wm-lib:` to script-src in both parent and opaque child; connect,
images, fonts, frames, downloads and all other capabilities remain closed. Content
rules use one anchored, escaped URL per resource; WebKit's restricted rule regex
grammar must not be replaced with general-purpose alternation syntax.

New library/parameter sources bind a library digest into creator.json, covering
actual required library bytes plus the host API. Existing code with no declaration
or library keeps its previous optional fields and byte reconstruction. Do not
silently replace a pinned runtime in a later release; add a distinct version.

## Host signal API v1

`WallpaperHost` is a readonly object inside the unprivileged child only:

- `cursor`: normalized top-left x/y, damped vx/vy in normalized units per second,
  and a decaying active weight. Native desktop coordinates and ordinary preview
  pointer events feed the same state.
- `environment`: viewport/screen size, devicePixelRatio, system dark appearance,
  maxFPS=30 and maxPixels=2073600. Resize/appearance subscriptions receive updates.
- `parameters`, `paused`, `frame`; `onFrame((dt,time,frame)=>…)`,
  `onParameters(values=>…)`, `onResize(environment=>…)`, `onPause(paused=>…)`.
  Each subscription returns an unsubscribe function; each group is capped at 32.

The bus schedules no animation without frame subscribers. Pause/host suspension
stops callbacks; resume resets delta-time so sleeping does not jump a simulation.
The existing external native watchdog remains authoritative. An unattached WebView
may suspend native rAF: offscreen lifecycle tests therefore drive a deterministic
clock through the real limiter; they do not claim actual display refresh timing.

## Declarative @param contract

A single exact HTML metadata tag declares bounded scalar controls:

```html
<script id="wm-params" type="application/json">
{"version":1,"parameters":[{"id":"speed","label":"Speed","type":"number","default":1,"min":0,"max":3,"step":0.01}],"values":{"speed":1}}
</script>
```

At most 16 definitions, unique safe identifiers, bounded plain labels, exact values
and no unknown fields or duplicate JSON keys. Types are number, boolean and color
(`#RRGGBB`); number domains must be finite, within -10000…10000 and have a positive
bounded step. This is data, never source interpolation or an eval contract.
The inspector renders sliders/toggles/color pickers. Native validation precedes
property delivery, the page uses `WallpaperHost.parameters`, and the installed
project.json carries matching standard Wallpaper Engine property defaults.

Changing a control updates previews only. Validate changes rebuilds the same
source with new metadata, derives an immutable child revision, reruns real WebKit
and captures a new cover. Save/apply remain disabled while parameter values differ
from the selected validated revision; no model call is needed. History, offline
playback digest validation and explicit desktop application remain unchanged.

## Verification boundary

Foundation tests cover strict metadata, source/library binding, real sandbox Three
loading, property delivery, damped coordinates, deterministic pause/resume and
native parameter revision derivation. Existing offline attack and code generation
regressions remain active. Visible UI, physical display performance and macOS 15
permissions still require device acceptance; no production app is launched here.
