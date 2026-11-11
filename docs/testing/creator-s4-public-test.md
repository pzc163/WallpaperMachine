# S4 外部开发者公测清单

面向 Apple Silicon、macOS 15.0+ 的 Ad-hoc Pre-release；未经过 Apple 公证，不支持 Intel。
本轮的代码和离屏自动化完成情况见 [S4 实现](../features/creator-free-code.md)。
请使用独立 macOS 测试账户；应用沿用正式版 Bundle ID，不在同一账户同时运行两个版本。
关闭自动更新，测试包仅从本 fork Releases 手动获取；不进入 main/latest 通道。

## 安装与回退

1. 先按 Release 页提供的 SHA-256 核验 DMG，再挂载并复制到测试账户的 `~/Applications`。
2. 如 Gatekeeper 阻止，先检查发布来源与校验值；仅对已核验的测试副本执行：

```sh
xattr -cr "$HOME/Applications/WallpaperMachine.app"
codesign --verify --deep --strict --verbose=2 "$HOME/Applications/WallpaperMachine.app"
```

3. 再由用户手动打开该副本；不要删除系统安全设置或给其他文件批量移除属性。
4. 结束测试时先在菜单栏退出测试版，确认扩展退出后再回到日常账户使用正式版。
   不删除个人 Keychain 项，不将测试 Creator 目录复制回正式旧版；保留测试账户即可回退数据。
5. 遇到“此 WebKit 版本不支持自由代码”请记录系统版本，使用模板模式；不得通过源码改开关绕过。

## 模型连接

在 LM Studio 加载模型并开启服务器；同机使用 `http://127.0.0.1:1234/v1`。
跨机优先 SSH 隧道：在测试 Mac 执行（替换为自己已授权的用户名和局域网主机名）：

```sh
ssh -N -L 1234:127.0.0.1:1234 user@model-host.local
```

也可以将模型服务器显式绑定到可信 LAN，使用 `http://model-host.local:1234/v1`。
在应用中选择 OpenAI-compatible、开启“本地服务模式”、填写实际模型 ID，JSON 模式先选 automatic。
支持 RFC1918、IPv6 ULA/link-local 和 .local；公网 HTTP 仍被拒绝。空 Key 仅适合无需鉴权的显式
本地服务。LAN HTTP 不加密，不应向不可信网络暴露模型服务。主机或配置代次改变后重新绑定凭据。
测试连接前核对弹窗中的目标和模型；顶部成功横幅应显示协商模式及耗时。
自动协商 schema → object → prompt 共用真实请求/token 预算，不是免费重试。

## 可照单执行的场景

| 编号 | 操作 | 通过判据 |
|---|---|---|
| S3-C01 | automatic 接支持 schema 的本地模型，再接只支持 JSON object/文本的服务 | 自动协商，横幅显示实际模式；失败可取消；不超过预算 |
| S3-C02 | token 留空，保存后重新打开；更改主机 | 使用明确默认上限；旧 Key 不被带到新主机 |
| S3-V01 | 模板渐变 aurora/ember、星空 quiet/voyage、时钟 dawn/terminal，依次预览 | 三套 WebGL 视觉明显不同；滑块全量响应、历史模板不改写；封面不是空黑图 |
| S4-C01 | 自由代码提示“纯黑背景，随鼠标移动晕染的紫色流体水墨，无文字” | 通过校验，预览指针互动；保存和应用须分别点击 |
| S4-C02 | 追问“保留构图，减慢流动，改为青绿色”；切回第一版 | 生成新版本，旧版字节不变；显式回退可继续修改 |
| S4-C03 | 限制最多两次修复；诱发语法错误/白屏或中途停止 | 最多三次请求，错误分类可查看；失败不替换当前壁纸 |
| S4-D01 / AC-11 | 双屏分别应用；16:9 60 Hz 与 16:10 144 Hz，改变目标屏 | 每屏独立互动、≤30 Hz 指针与动画目标；非目标屏不串坐标 |
| S3-D02 / AC-11 | clock bottomRight + clockScale 1.5，横竖屏/16:10 切换 | 字体清楚、完整安全边距，无贴边裁切 |
| S4-D03 | 遮挡桌面、暂停、显示器休眠，再恢复 | 指针监听停止，恢复后无白屏/卡住；失效页面有明确错误/重试，不无限重启 |
| S3-O01 / AC-08 | 断开外网后重启播放已发布壁纸；本机回环模型保留 | 已保存资源可播放，播放不请求模型；回环服务可生成，外网模型失败可取消 |
| S3-P01 / AC-11 | `pmset displaysleepnow` 后唤醒；另用 Apple 菜单“睡眠”再唤醒 | 分别记录显示器休眠和系统睡眠；双屏布局与画面恢复，不把两者混为一次验收 |
| S3-E01 | Release 构建运行 ≥30 分钟，比较关闭/开启每类壁纸 | 记录宿主、WebContent、GPU 的 CPU/footprint 与系统能耗；注明 GPU 共享、不可直接归属 |

不要在自己的正式环境运行恶意探针。自动化的死循环/下载/文件探针仅在临时数据和隔离离屏宿主执行。
S4 开放不等于所有硬件验收完成；本轮没有再次调用真实模型，也没有新版本 1800 秒/GPU 能耗实测。
反馈时只提交系统版本、模板/模式、复现步骤、固定错误分类和脱敏指标，勿上传 Key、完整日志、私人路径或项目素材。

## Connection and composer preview update

Use the newest `creator-artifacts-preview-20261111` prerelease for the connection/workspace
update. In Settings → AI models, enable Local server mode, enter the server Base URL,
and choose Fetch models. Confirm the displayed target and select a returned model ID;
then save. Empty local credentials never require Keychain access. A protected local
server can use an explicitly entered key. Remote keys may need one macOS permission
approval per new Ad-hoc build; subsequent requests reuse a process-only cache.

Verify the following on the test account: local numeric-IP HTTP after granting macOS
local-network permission, cancelling model discovery, 25-second unreachable-target
feedback, continued thinking/content progress without a short total timeout, and
accurate usage. A non-stream endpoint gets one budgeted fallback; all negotiation and
repairs still share at most three requests. No real-model testing was performed for
this UI update.

Check project auto naming and pencil rename, sidebar search/context menus, failed-turn
Retry/Edit and resend, and model/mode selection from the composer. Enter sends;
Shift-Enter adds a line; confirming an IME candidate must not send. Paste a long prompt
and verify three-to-eight-line growth and internal scrolling at narrow window sizes.
Save and Apply remain separate. Physical visual/focus/LAN and macOS 15 device behavior
remain manual checks; automated views are hosted offscreen.


## 本轮流式产物验收

- 本地服务表单：Base URL、Model ID、可选 API Key 始终可编辑。输入合法 LAN 地址后，不保存即可点击获取模型列表；弹窗确认当前地址后才请求。若系统阻止本地网络，在系统设置的隐私与安全性中允许测试构建。
- Token 留空为服务器原生最大值；显式输入上限 131,072。每次回退/修复仍占一个请求预算，最多三次；服务器上下文不足时一次适配不能保证所有网关接受。
- 自由代码直接输出完整 HTML / html 围栏（最大 256 KiB），观察思考折叠面板与源码实时滚动。完成后思考自动折叠，可以展开；只在当前面板会话内保留最多八轮/8 MiB。
- 完成静态、离屏运行及封面校验后，切换内嵌渲染并测试指针互动。源码/渲染可来回切换，可复制源码，也可打开独立预览。检查源代码行数、字节数与 Token 用量；未返回用量显示未知。
- 切换到源码、离开创作页、隐藏窗口或切换工程，确认旧预览停止。失败保留上一已验证修订，部分源码绝不运行；保存与应用仍是独立动作。
- macOS 15 实机 LAN 授权、可见界面/输入法与异构双屏/睡眠/能耗仍需设备验收；常规门禁仅使用 Mock 模型与离屏 WebKit。
