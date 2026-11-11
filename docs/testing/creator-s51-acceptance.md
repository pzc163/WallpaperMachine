# S5.1 多引擎验收

## 自动化证据映射

| 范围 | 自动化证据 | 通过条件 |
| --- | --- | --- |
| wm-lib 离线与版本固定 | CreatorHostFoundationTests；test_creator_libraries | 原生精确 URL 白名单、路径/别名拒绝、实际库 SHA、真实 WK 加载 |
| 参数类型与修订边界 | CreatorHostFoundationTests；CreatorGalleryTests | 有限范围/完整值集；预览编辑不能直接保存，验证后新修订保留原字节 |
| 核心源码与三协议 | CreatorEngineTests；CreatorEngineAcceptanceTests | 裸 GLSL/JS、单围栏、双 Pass、分片与思维分离；不附 JSON 格式限制，准确记录输入/输出用量 |
| 运行与失败修复 | CreatorEngineTests；CreatorCodeWorkflowTests | 真实 JPEG、黑/透明/NaN 拒绝；Shader 作者相对行号进入有限修复；旧 HTML 合同不变 |
| 九套母版画面 | CreatorMasterTests | 9/9 本地打开→真实运行→封面→不可变版本；每套像素有明显颜色变化；无模型请求 |
| 生命周期和资源 | CreatorEngineAcceptanceTests | 每套动画像素变化、暂停不推进、参数改变重绘、恢复适配竖屏、100ms 内最多四帧、画布上限、停止释放 |
| 外部监督 | CreatorCodeHostTests；CreatorEngineAcceptanceTests | 原生引擎启动最多 5s；ready 后死循环约 2s 期限终止，普通 HTML 仍 2s |
| 原生 UI 与本地化 | CreatorGalleryTests；CreatorPanelTests；CreatorComposerTests | 六语言、320pt 窄栏、无可见窗口；历史恢复引擎、未来引擎拒绝；保存和应用独立 |
| 缩略图边界 | CreatorEngineAcceptanceTests | Bundle 中九个闭集 ID、JPEG 解码下采样、任意路径拒绝 |
| 旧合同与发布策略 | 完整 scripts/test.py | S0/S1 黄金摘要、registry、导入、回退、隐私和现有播放入口全部保留 |

截图由离屏 WKWebView 捕获，仅包含自身程序化画面。初次审查修复云海/地形层次与黑洞负底数 pow 的 NaN，未以放宽非空断言或占位图替代。流体、引力、月相是视觉近似，不是物理精确仿真。暂停的 WebKit 会脱离视图，容器新尺寸在恢复时传入；不为隐藏壁纸持续唤醒布局。

## 可复现命令

```sh
python3 scripts/test.py --only CreatorHostFoundationTests --only CreatorEngineTests --only CreatorMasterTests --only CreatorGalleryTests --only CreatorEngineAcceptanceTests
python3 scripts/test.py
python3 scripts/build.py --swift-only --configuration Release
```

常规测试只使用 Mock 模型、临时数据和内存凭据。不要设置任何 Live/Benchmark/Soak 开关。测试不启动可见应用或替换真实桌面。测试附件中的九张 JPEG 是母版默认画面的证据；正式用户修订的封面仍每次重新捕获。

## 外部 Mac 验收

1. macOS 15+ Apple Silicon；核对预发布 DMG SHA-256，在独立测试数据环境运行。Ad-hoc 包未公证，不能称为 Apple 认证版本。
2. 无 Provider 时打开九套母版，分别拖动数值、开关与颜色；点击验证前确认保存/应用不能越过边界。
3. 在每种引擎选一套，用已配置模型改造；检查实时源码、错误修复、Token 用量、历史回退。API 调用可能收费，自动化结果不代表真实模型成功率。
4. 检查 16:9、16:10、竖屏及不同 DPI；拖动指针、暂停/恢复、遮挡、显示器休眠与系统睡眠后恢复。
5. 保存入库后物理断网重启播放，验证已发布引擎不依赖外网；区别模型服务连接与壁纸运行连接。
6. Release 真机测量宿主、WebContent、GPU 的总资源与能耗。30 FPS 是调度上限，不承诺所有硬件/所有作者源码达到 30 FPS；两百万像素也不是系统级 GPU 配额。

## 当前结果

2026-11-11：第三阶段定向验收 35 项通过；最终新增引擎生命周期、三协议、缩略图及超时检查 5 项通过。完整 `python3 scripts/test.py` 退出 0：脚本检查通过，原生 **5,088 passed / 0 failed / 69 skipped**，原生运行 127 秒。九套母版均通过实际离屏渲染与生命周期检查。跳过项属于需显式启用的媒体素材、网络、参考图、真实模型及长稳层，未计作通过。

本次有 3 条主线程运行警告；详细记录归属于 `VideoFormatSupportTests`、`AppUpdateTests` 和 `LockScreenWebMPlayerTests`，对应测试均通过，没有来源行号。未把警告隐藏或归为新引擎成功率。

预发布的 DMG 附带 SHA-256 与脱敏 metadata：记录实际源码提交、Ad-hoc 签名、每个 Mach-O 的最低系统版本和替换依赖的导出符号核对。目标是 macOS 15+ arm64；静态兼容性检查与实际 macOS 15 设备运行是两个验收层。

首次打包的强制许可证门禁发现 Three.js 已随资源携带 MIT 原文，但汇总器缺少登记；新增回归先复现缺失，再补齐登记，要求最终 THIRD-PARTY-NOTICES 包含完整上游原文。没有关闭 `--require-notices`。补丁后的完整 Python 门禁 724 项通过；真实 Release 依赖闭包 160 个组件均找到许可证原文，无缺失。此补丁只改发布脚本与其测试，不改变已通过原生门禁的应用代码。

尚未执行真实付费模型、30 分钟新引擎长稳、可见桌面、多屏睡眠或 macOS 15 实机验收。内置 WebGL2 引擎需要 WebGL2 实现（可为系统软件后端）；不可用时明确失败，不使用低质量静态替代。WebKit 监督仍依赖现有能力检测和 SPI，不能外推为任意恶意代码的安全审计。
