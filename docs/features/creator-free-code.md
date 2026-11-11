# S4 自由代码创作与外部开发者公测

2026-11-11，`feat/ai-creator` 在三阶段升级中增加自由代码模式。模板模式仍为默认；
自由代码是独立合同、运行策略及验证配置，不会让旧包转入宽松兼容宿主。
这是一版供外部开发者测试的受限 HTML 创作实现，不是任意 Web 网站或插件执行器。

## 创作合同与版本

`CodeBundleOutput v2` 冻结为单行 JSON 头和一个原始 HTML 块：

```text
{"schemaVersion":2,"title":"紫色水墨","summary":"黑底指针互动"}
<file path="index.html">
<!doctype html><html><head><style>html,body{margin:0;background:#000}</style></head><body><canvas></canvas><script>/* bounded visual implementation */</script></body></html>
</file>
```

- 头部仅允许三个字段；标题/摘要沿用 60/240 Unicode 标量限制及控制字符过滤。
- HTML 最多 32 KiB UTF-8，完整响应最多 34 KiB。分隔行固定、只接收一个块，保留标签出现在源码中也拒绝；没有正则搜索后忽略尾部的容错。
- 文件名只能为 `index.html`。不接受模型路径、其他文件、二进制、外部资源、模块或导入。
- 第一版只接收不带属性的内联 `<script>`。JavaScriptCore 的 Function 构造器只编译有界脚本体，**不调用函数、不执行模型源码**；语法错进入原生静态修复分类。
- 通用 HTML 静态检查用于反馈，不作为网络隔离证明。执行仍必须经过真实 WebKit。
- 三种模型协议共用此合同：代码请求禁用 JSON response_format，Gemini 使用 text/plain；模板请求继续使用 JSON。前置思维片段丢弃，源码原字节保留。
- 模型源码写盘前检查当前合成/真实 Profile Key 的回显；失败信息只记录固定分类，不收录原始脚本错误、路径或日志正文。

资源包继续使用 v2 四文件 `creator.json/project.json/index.html/preview.jpg`，与模型输出 schemaVersion 分开。
源码 SHA-256、包摘要、修订元数据、封面和 `code-structure-v1/code-runtime-v1` 报告互相绑定；
注册表记录 `generatedOfflineV1`。旧 S0 三文件、旧 v2 模板及 rendererRevision 3 WebGL 模板
仍按各自原生重建器读取，历史字节摘要不变。

## 原生离线边界

自定义 scheme 仅返回原生控制的父页面，不直接把模型 HTML 当顶层文档执行。
父页面创建 `sandbox="allow-scripts"` 的不透明来源 iframe；没有 allow-same-origin、
allow-downloads、allow-popups、allow-forms 或 top-navigation 权限。生成内容写入 srcdoc 前
由原生在最前面加入 CSP：connect/img/font/media/frame/child/worker/object/base/form 均为 none，
只允许内联脚本和样式。首版视觉为程序绘制和系统字体，不开放图片/音频/本地文件素材。

内容规则、导航 action/response、下载转换 delegate 和权限 delegate 继续叠加生效。
非原生入口的导航、下载、重定向和目的地一律取消；不保存下载恢复数据，不允许文件选择、
捕获设备或弹窗。每个页面独立 nonPersistent 网站数据存储，不授予 file URL 权限。
原生宿主不处理代码子页面发送的兼容音频/文件/媒体消息。

S0 的 scheme 响应头 sandbox 实验仍是历史失败；本次改变的是实际 iframe sandbox。
下载 delegate 不是零网络证明：三个原 S0 探针和扩展矩阵在真实宿主中各用本地监听器正向对照，
以“已有控制连接=1，攻击后仍为1”判定，没有以缺少错误事件或等待超时当作成功拒绝。
严格模式在第一条请求前拦截，因而服务端附件/MIME/重定向响应不应实际送达被测页面。

## 外部监督、资源限制与生命周期

`CreatorCodeProcess` 集中封装 WebKit SPI `_webProcessIdentifier` 和
`_killWebContentProcessAndResetState`。应用记录自己创建的 WebWallpaperPage 与代码预览；
检查不同实例的实际 PID 和数据存储归属。共用进程/存储或缺少 selector 时拒绝自由代码，
不采用多个 WKProcessPool 作为证明，也不枚举或杀死其他应用的进程。

原生主进程每 250 ms 主动读取隔离内容世界的状态，一次只保留一个待回应检查；2 秒单调时钟
超时后定向终止所属 WebContent。页面不能用自报心跳续期。测试将期限缩短到 700 ms，实际
同步死循环和递归微任务均终止并释放 PID，另一页面保持可用。停止取消监督任务、移除处理器，
旧代次回调失效；重新预览产生新实例。正式播放失败进入既有宿主失败/重试路径，不自动无限重启。

- 每实例 WebContent footprint 超过 512 MiB 立即拒绝；持续约 3 秒超过 0.9 CPU 核的采样也拒绝。测试另用 192 MiB 阈值和有上限的分配样本验证释放。
- SDK 将 rAF 限制在 30 FPS，最多 64 个待执行回调；一个渲染 canvas、边长最多 4096、面积最多 2,073,600。OffscreenCanvas 不开放；canvas 属性绕路变更也触发检查。
- WebGL 强制 preserveDrawingBuffer，编译/链接失败产生固定分类。console 不向原生日志传输正文，超过 256 次记录资源错误。
- 不透明来源会隐藏部分运行错误细节；语法先原生编译检查，运行阶段 error/unhandledrejection/CSP 与 SDK 错误只保留枚举。固定 DOM 标记跨内容世界传递失败分类，不增加页面可调用的原生权限接口。
- 暂停后 rAF 停止；宿主分离页面后不再用 JS 探活唤醒它，仍采样原生 CPU/内存并保留已在途调用的截止时间。

上述是应用层配额及故障回收，**不是操作系统硬 CPU/GPU 配额**。WebKit GPU 进程可共享；
没有可精确归属于单壁纸的 GPU 内存/能耗证据。异常驱动、所有恶意着色器和所有历史 WebKit
版本的终止行为不在本机证明范围内。SPI 不受 Apple 公共 API 稳定性保证；macOS 15 真机需按
公测清单复验。不能将本次结果写成对任意敌对代码的安全审计或物理 S3 已清零。

## 预览、指针与发布

原生离屏 WKWebView 先通过外部健康采样，再冻结动画、等待字体、捕获并检验非空 JPEG。
纯黑/纯白空画面、超时、运行错误与取消均不能取得发布报告。运行失败的候选源码作为有界数据
进入下一次修复，仍重新静态检查、运行和生成封面；最多首次加两次修复，同一请求/token 账本。
401 和取消直接停止。失败候选不覆盖已发布版本；不可变历史可显式回退。

创作页有“精调模板 / 自由代码”原生模式选择器。切换模式取消当前选择，不删除工程；
重新选择历史工程恢复其模式。模板有预设/滑块，自由代码通过对话修改。预览、保存到库和
应用到显示器是独立动作，不自动修改桌面。

独立预览使用浏览器指针事件。桌面沿用宿主的按显示器路由及节流监听器，代码页面最多
min(30,目标帧率) Hz，发送 CSS 像素 pointermove/mousemove 和只读
`window.wallpaperCursor={x,y,normalizedX,normalizedY,active}`，坐标原点为左上。
暂停、遮挡、显示器休眠及停止立即退出光标订阅；多个活跃显示器各有独立实例。

无界面启动、播放列表、重载均继续验证注册表、完整包摘要及未完成发布事务。
锁屏扩展继续拒绝 Creator 包，不退回普通 file 宿主；尚未支持的备份/恢复/搬迁仍明确拒绝。

## 回归证据与剩余实机项

| 范围 | 原生自动化证据 |
|---|---|
| 三协议、原生封面、入库/离线读取、篡改 | CreatorCodeWorkflowTests |
| 语法/空白修复、失败预算、401/取消、UTF-8 大段分片 | CreatorCodeWorkflowTests |
| S0 下载、EventSource、媒体 | CreatorPreviewTests 对应三项，常规门禁不再跳过 |
| 网络/API/资源/文件/下载矩阵、opaque storage/parent/popup | CreatorCodeHostTests |
| 死循环、微任务、内存/日志/canvas 超限、共享存储拒绝、停止释放 | CreatorCodeSandboxTests |
| 指针坐标、暂停合成、尺寸、shader/unhandled 分类、进程退出 | CreatorCodeHostTests |
| 双显示器独立 PID、144 Hz 下指针限速、暂停/遮挡/休眠无监听 | CreatorCodeDesktopTests，替身表面，不开真实窗口 |
| 模式切换、历史保留、独立保存/应用 | CreatorPanelTests |
| 旧包、事务恢复、全入口、凭据与所有模板 | 既有 Creator/LLM/WebWallpaper 回归 |

常规门禁全部使用 Mock 模型、临时目录与内存凭据。没有真实模型请求、个人 Keychain、可见应用、
真实桌面或硬件权限操作。旧 S2.3 的 30/30 模型基准和 1800 秒长稳仅是原模板的历史结果，
不覆盖新 WebGL 或自由代码。可见审美、跨机 macOS 15、多屏 DPI/休眠、长期 GPU/整机能耗
仍按[公测清单](../testing/creator-s4-public-test.md)人工验收。

最终验证（2026-11-11）：18 项 S4 定向通过，另一次包含三探针/宿主/模板/协议/修复的定向回归
68 项通过；控制器及初期 S4 定向 27 项通过。完整 `python3 scripts/test.py` 门禁一次通过：
720 项脚本、5,034 项原生、0 失败、69 跳过。文档 11 项、本地化目录 8 项、面板本地化 9 项另行通过。
69 跳过为原有媒体/设备、Steam、参考素材及 live/benchmark/soak 授权项；三项 S0 隔离探针不在其中。
结果保留两个运行时警告，不作为设备验收证据。未修改 main，未运行真实模型/桌面；发布仅用独立预发布通道。
