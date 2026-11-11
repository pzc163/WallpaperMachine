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

## 两套核心源码引擎

`shader-glsl` 的模型合同为裸 GLSL 或单一 `glsl` 围栏；单 Pass 使用 `mainImage`，双 Pass 依次用 `// @pass BufferA`、`// @pass Image` 分隔。宿主提供标准时间、帧、像素尺寸、鼠标 uniforms，以及 `iCursor`、`iActive` 和 `p_<id>` 参数。BufferA 读取上一帧，Image 读取本帧 BufferA；无 BufferA 时 Image 自反馈。使用可用的 RGBA16F，缺少浮点附件时使用 RGBA8，作者必须兼容编码后的状态。最终显示统一 ACES/sRGB/抖动，不应在作者代码重复执行。

`three-3d` 的模型合同为裸 classic JavaScript 或单一 `javascript` 围栏，提供 `setupScene(api)` 和 `updateScene(api, dt)`。宿主建立透视相机、程序化 RoomEnvironment 的 128 像素 PMREM、RenderPass/UnrealBloomPass/OutputPass；作者负责场景、材质、灯光和有界更新，不另建渲染循环。`api` 包含 THREE、scene、camera、renderer、composer、bloom、parameters、cursor、environment、time、state、target、basePosition、onDispose。无外部 HDRI、纹理或字体。

两类源码可以以 `/* @param <version-1 参数 JSON> */` 开头；未声明时继承已有修订/母版参数。原生将核心源码封装为确定性 HTML，`wm-engine` 记录引擎版本，外壳重建必须逐字节一致，仍封闭为原有四文件 v2 包。未来引擎枚举不代表开放执行权限。

原生验证先通过外部监督的健康检查，再调用有界的引擎首帧探针推进三帧，然后使用 WKWebView 整页快照。黑帧、全透明、非有限颜色或非有限 3D 变换不能获得发布报告。离屏页面的原生 rAF 可被 WebKit 暂停，因此首帧推进不冒充长时间动画/能耗验证。GLSL 使用 `#line 1` 把驱动位置映射到作者源码；持久化仅保留 Image/BufferA、1～16384 行号及 syntax/type/undeclared/link/nonfinite 枚举，最多四条，不保存原始驱动消息。
