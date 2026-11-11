# S5.2 实施与验收

日期：2026-11-12。分支：feat/ai-creator。范围见 [S5.2 计划](../plans/2026-11-11-creator-s52.md)、[图影合同](../features/creator-media.md)。本轮未修改 main，未启动可见正式版、安装应用、读取个人模型密钥或更换桌面。

## 已交付

- 供应商双栏中心：11 家云端预设、LM Studio/Ollama、自定义云端/本地服务，Profile 共用凭据及多个模型、可选视觉模型能力、自动/手动上下文预算、折叠高级 JSON 设置。
- LobeHub 1.102.0 离线 SVG 图标、锁定来源/摘要及 MIT 通知。初始 S5.2 包中 MiniCPM 使用字母标识；后续按用户提供的参考图，改用 ModelBest 官方平台的原始蓝色 SVG，独立记录[来源与摘要](../features/creator-llm.md#s52-provider-center)，不归入 LobeHub MIT 资产。
- 单舞台、对话抽屉、源码编辑/运行、参数热更新与自动派生保存、固定保存/应用栏；应用仍为用户显式动作。
- 新版半浮点反馈（RGBA16F + LINEAR，实际附件验证后回退 RGBA8），旧运行库字节继续可用。
- 图片/视频导入、拖入/粘贴/库选择、原生五色调色板/亮度遮罩、单次视觉缩略图授权、v3 封闭素材包与 `.wmpkg` 分享。
- hybrid-media / scene-2d 六套图影母版，合计十五套；默认底图有来源记录，画廊封面来自真实 WKWebView。

## 自动化证据

| 范围 | 验证 |
| --- | --- |
| 供应商/凭据 | Provider/Settings/LLM 与原生面板定向覆盖，共 36 项；检查共享模型、配置代次、免密路径、上下文与图标映射 |
| 单舞台/参数/源码 | CreatorHotEditingTests、Artifact/Controls/Gallery/Panel：新修订、独立保存/应用、源代码失败保留旧版、六语言与窄宽布局 |
| 媒体闭环 | CreatorMediaTests：原生分析、Range/HEAD/取消、路径白名单、字节篡改、分享、旧版保留、Mock 迭代、三协议视觉合同 |
| 真实视频 | 合成 MOV 以及 VP9 WebM：离线读取、实际解码、原生截图；MOV 实测 206 响应、播放时间推进、静音、暂停/恢复和分享后导入 |
| 母版 | CreatorMasterTests：15/15 真正运行检查并生成非空 JPEG；CreatorEngineAcceptanceTests：实际像素变化、暂停参数变化、竖屏与 30 FPS 调度上限 |
| 隔离/兼容 | CreatorCodeSandboxTests 的下载/EventSource/外部媒体正向对照探针通过；v1/v2 黄金摘要、发布恢复、不可变历史继续通过 |
| 完整门禁 | `python3 scripts/test.py`：724 Python 检查；5,109 原生通过、0 失败、69 跳过，原生 155 秒 |
| 文档与语言 | localization_catalogs、panel_localization、doc_links 共 28 项通过；四语 README 与六语言目录同步 |
| 离线依赖 | `python3 scripts/bundle_creator_libraries.py` 通过；Debug 许可证闭包 179 项，0 不兼容、0 未知、0 缺登记 |

完整门禁的 69 项跳过沿用外部资产/设备/显式 opt-in 条件，不能算作通过；未启用真实 LLM、Benchmark、Soak、可见 UI 或真实桌面测试。结果包记录 3 条主线程响应性运行时警告，非测试失败，不声称消除所有历史诊断。

## 本轮实证修复

### MiniCPM 图标补齐（2026-11-12）

按用户参考图替换字母占位，原样内置 ModelBest 官方 SVG；供应商目录与模型切换器共用资源，也识别本地 MiniCPM / openbmb/MiniCPM 模型。保留品牌蓝色、透明底及矢量缩放，来源与摘要独立于 LobeHub MIT 清单。

- `python3 scripts/test.py --only CreatorProviderCenterTests`：6 通过、0 失败、0 跳过。
- `python3 scripts/test.py`：724 Python 检查通过；5,109 原生通过、0 失败、69 条件跳过，原生 135 秒；2 条主线程响应性警告。
- 未运行可见 UI / 桌面验收；后续发布沿用 macOS 15+、arm64、Ad-hoc 路线，实际交付以对应 Pre-release 的源码提交、DMG 和 SHA-256 为准。

### S5.2 主体

1. WebKit 自定义内容规则不接受通用正则中的所有写法；媒体扩展改为独立锚定规则，资源 handler 继续执行精确清单匹配。
2. opaque srcdoc 同时受父容器和自身 CSP 约束；两层只增加 wm-media 图像/视频白名单，connect-src 仍为 none。
3. 未挂载窗口的 WebKit 不授予媒体开始条件。视频验证使用从不显示、不可聚焦的临时宿主；真实 Range 和播放时间构成正向证据，无静帧假播放。
4. 恢复时先解除原生媒体暂停，再发送宿主恢复回调，避免正常恢复中的 play() 被拒绝。主动暂停产生的 AbortError 不误报资源损坏。
5. 湖面着色器负值参与 pow 引发非有限像素，改为显式乘法；非有限探针保持有效。
6. 初次完整门禁发现旧测试断言与热保存行为不符，以及无媒体旧版修订被多余的现代预览报告读取阻断。仅媒体引擎读取素材快照，26 项定向复验和第二次完整门禁通过。

## 发布与实机边界

Release 使用 `python3 scripts/build.py --swift-only --configuration Release`；打包以同版本官方 arm64_sequoia 依赖校验导出符号/ABI/最低系统版本，保持 macOS 15.0。只发布独立 S5.2 Pre-release，Ad-hoc 签名且未公证，S5.1 包继续保留；以 Release 附件的 SHA-256 和包元数据核验实际交付。

实际 macOS 15、可见拖放/剪贴板授权、多屏 DPI/睡眠、整机/GPU 能耗和第三方模型/视频编码组合仍需人工测试。2.5D 使用亮度/高度分层视差，不宣称真实深度重建。桌面暂停、沙箱和包摘要保护没有因素材功能而取消。
