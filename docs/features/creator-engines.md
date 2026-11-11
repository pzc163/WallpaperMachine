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
CSP adds only `wm-lib:` to script-src in both parent and opaque child. S5.2 permits
only digest-bound `wm-media:` images/video; connect, remote resources, fonts, frames
and downloads remain closed. See [media contracts](creator-media.md). Content
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

S5.2 controls update the existing preview and can be saved directly. The native parameter-only
proof compares the rebuilt HTML with the prior source after replacing only the validated metadata.
A ready, supervised embedded page supplies a fresh whole-page JPEG and nonempty-pixel check
without reloading; absent a ready page, save prepares an offscreen page. All newly sealed bytes
receive their own digest/report. Source edits use full runtime validation, never this shortcut.
History and explicit desktop application remain separate from preview.

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

## 母版画廊与本地编辑

新工程默认选择 shader-glsl；引擎菜单同时保留经典参数模板和自由 HTML。画廊按引擎显示三套作品，其 JPEG 来自真实离屏 WKWebView，而非静态占位绘制。打开母版会本地重建、验证、生成封面并选择不可变修订，不需要 Provider 或模型请求。修改颜色、数值、开关会同步预览；可直接保存为新修订，参数派生和封面/摘要封闭由原生事务完成，应用显示器仍单独操作。

| 引擎 | 母版 | 核心机制 |
| --- | --- | --- |
| shader-glsl | Aurum Ink | 半拉格朗日反馈、邻域平滑与旋度力的流体视觉近似，指针注入颜料；不是精确 CFD 求解器 |
| shader-glsl | Luminous Cloudsea | 有界体积步进、分层噪声密度与短程光线衰减 |
| shader-glsl | Event Horizon | 弯曲射线、发光吸积盘、颜色频移近似与透镜星场；不是相对论数值模拟 |
| three-3d | Prismatic Atelier | 倒角透光玻璃矩阵、色散、摄影棚反射、动态点光 |
| three-3d | Boreal Terrain | 低多边形起伏地形、色阶与雾、程序化极光帘幕 |
| three-3d | Orbital Relic | 2,048 容量实例化粒子、轨道圈与金属多面体核心 |
| html-canvas | Bioluminescent Mycelium | 2,400 容量粒子、低分辨率趋化场、指针引力与尾迹 |
| html-canvas | Celestial Tourbillon | 几何齿轮、摆轮、当地时间指针与近似月相 |
| html-canvas | Form in Motion | 包豪斯色块、排版、网格与缓动构成 |

母版源文件和参数目录随 Bundle 固定，源码 SHA-256 校验后才能生成；不按任意路径找资源。母版截图只用于画廊，用户发布封面仍每次真实捕获。未指定历史版本时，在选择的引擎内以中英文关键词匹配母版；无匹配时稳定使用该引擎第一套，不额外调用模型。已有版本以其不可变核心为准，不被参考匹配覆盖。

冷启动编译 PMREM/后期管线会短时阻塞 WebKit。只有通过原生外壳重建验证的两套引擎拥有最多 5 秒启动心跳期限；ready 后恢复 2 秒期限。普通 HTML 仍为 2 秒，验证任务总期限仍为 5 秒；不会因页面自报活动延长期限。此次并行测试实际发现并修复了旧 2 秒冷启动误判，未放宽 CPU、内存、帧率或画布限制。

## S5.2 shader precision and editing

New Shader documents select `wm-lib://engines/shader-v2.js` through optional
`runtimeVersion: 2` metadata. Old documents keep v1 byte-for-byte. V2 allocates
linearly filtered RGBA16F feedback and verifies both allocation errors and framebuffer
completeness; unsupported/incomplete attachments retry RGBA8. The pixel budget,
number of buffers, pause and context-loss cleanup remain bounded. The frame probe
reports actual feedback precision. Aurum Ink retains HDR density instead of an
explicit unit clamp and uses a smooth optical-density response to reduce contouring.

`CreatorHotEditingTests` exercises real half-float and forced fallback rendering,
parameter capture on the same WK surface, immutable history and failed source edits.
Physical display quality/energy still needs visible device acceptance.

## S5.2 图影扩展

画廊现有五种引擎、十五套母版；新增 hybrid-media 和 scene-2d 的六套图影作品。媒体包使用 v3，旧无素材运行库与 v1/v2 重建保持兼容。[完整素材、分享和离屏视频边界](creator-media.md)。
