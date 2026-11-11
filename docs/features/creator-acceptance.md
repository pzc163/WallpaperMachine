# S2.3：创作稳定性验收与基准测试

本轮以 `35594fb9`（S2.2，本地 `feat/ai-creator`，未 push）为干净基线。
仅补齐无界面恢复、正式播放事务边界、凭据落盘检查与验收工具；不进入 S3/S4。
2026-11-11 最终收口已核对用户完成的真实 smoke、30 样本生成基准和 1800 秒离屏长稳报告；本次不重发真实模型请求。
修复前用户报告的 20% 首次/70% 最终通过率属于历史；Prompt 与 Schema 修复后的本次固定配置为 100% 首次/最终通过。
最终常规门禁已通过，S2.3 收口完成；按用户指令本地提交并暂停，不 push，不自动进入 S3。

## 真实实测与脱敏归档（2026-11-11）

持久证据为[脱敏聚合指标](../testing/creator-s23-results.json)。已读取原始结构化附件并交叉核对三个 XCTest 结果摘要，均为 1 passed、0 failed、0 skipped。
只保留模型公开名称、固定语料/协议/模式与数值；不保留机器路径、地址、设备标识、凭据、原始提示词或模型输出。

| 验收 | 已核实结果 |
|---|---|
| 单次真实生成 | `CreatorLiveSmokeTests` 1 passed；一次生成、运行检查、封面与临时入库闭环通过 |
| 真实 10×3 基准 | qwen3.8-flash-next，openaiCompatible，schema；30/30 全部首次通过，首次/最终均 100%；30 次请求，无修复；结果包总耗时约 159 秒 |
| 模板匹配 | 渐变 9、星空 12、时钟 9；30/30 与请求模板一致 |
| 每样本耗时 | min 4.586、p50 5.051、p95 6.229、max 6.231 秒；包含生成、完整验证及临时入库 |
| 已报告用量 | 输入 90,588，输出 5,800，总计 96,388 token；未知/不完整用量次数均为 0；预留输出 61,440 不代表实际计费 |
| 真实长稳 | 三个页面连续运行 1800.093 秒；XCTest 约 1803 秒；每模板 180 次、共 540 次采样全部响应正常，结束停止 3 个页面 |
| 生命周期/外连 | 暂停/恢复及横屏、16:10、竖屏轮换；外连尝试和 WebContent 终止计数最大值均为 0 |
| 宿主内存 | 基线 37,668,016、峰值 37,733,552、结束及停止后 32,916,800 bytes；峰值比基线高 65,536，结束差值 −4,751,216 bytes |

固定配置/固定语料的可运行率已达到 PRD ≥80% 目标；不能推导任意提示词或其他模型成功率，也不代表用户视觉满意率。
内存仅为宿主 footprint，不包括 WebContent/GPU；未建立“无泄漏”、可见桌面帧率、电池/能耗或物理断网结论。
AC-11 的真实双屏/睡眠，以及其他 AC 的桌面/可见 UI 子项仍待 S3；自由代码 AC-05/06 仍待 S4。

## 无界面恢复与正式播放

`BridgeStore.bootstrapAsync()` 在 `bridge.bootstrap()` 恢复播放前调用
`CreatorStartupRecovery`；菜单栏启动无需实例化 PanelController。
`CreatorRecoveryCoordinator` 合并同一工程根目录的并发恢复，先恢复发布事务，再清理未完成
Jobs/对话并恢复有效修订。恢复不解析凭据、不调用模型。被取消的调用者不能中断共享回滚；
活跃发布/生成仍由原来的租约保护，不被当作崩溃任务清理。

`CreatorRuntimeRegistry.readForPlayback` 在 Publisher 的 `.lock` 下读取不可变字节快照。
播放采用共享锁，发布采用排他锁；读取期间不能准备/安装/确认/恢复发布。发现 `active`
事务即拒绝播放，即使 candidate 字节与新登记完全一致也不能提前执行。
Publisher 的内部候选核验直接使用重建与 binding 校验，不绕过此门禁启动页面。
confirmed 后清理失败的事务仍先恢复，再放行。损坏日志、外部修改、未知策略保持拒绝并保留证据。
原生错误明确区分未完成发布、未知策略/数据版本及失效验证，三条提示覆盖现有六种语言，不显示原始记录或路径。

生产默认入口统一使用 ClientPaths；注入自定义注册表时必须显式传入匹配的发布日志根目录。
播放列表通过 `activateWallpaperAsync → WallpaperPlaybackPreflight` 进入同一门禁，Web 页面
首次加载和重载也重新检查。快照交给 `CreatorWebResources` 后只从内存提供可信模板。
已有页面继续使用自己的完整快照；不会因磁盘上正在替换而读取混合版本。

单个全局发布事务期间，新启动的 AI 页面暂时全部拒绝；这是保守策略，未增加自动重试或桌面替换。
备份/恢复/存储搬迁继续执行 S2.2 的明确拒绝边界，尚未实现携带 Creator 数据的可搬迁格式。

## 凭据落盘补强

严格 JSON 校验不等于元数据无秘密。生成器现在对已解析标题/摘要执行当前 Profile 凭据检查与
敏感文本检查；若存在回显 Key、Steam Cookie 字段或敏感路径，按 `policyViolation` 拒绝封装。
修复仍受同一个最多三次请求预算约束，错误只保留原生分类，不转抄被拒绝文本。
对话脱敏补齐 `steamLoginSecure/steamLogin/steamRememberLogin/sessionid/cookie/set-cookie`。

自动测试使用合成凭据扫描整个临时工程、修订、设置、正式库、注册表及日志；真实个人 Keychain
和 Steam 凭据均未读取。已存在的不可变历史不做静默改写。

## AC-01～AC-14 证据矩阵

下表区分自动化证据与尚需授权的真机体验。类/方法名可直接用于 `--only 类/方法`；
测试位于 `Tests/Unit/Creator/`，控制器测试位于 `Tests/Unit/Panel/`。
S4 的自由代码部分没有被模板模式的前置拒绝替代。

| AC | 本轮可核验的自动化证据 | 结论与剩余边界 |
|---|---|---|
| AC-01 生成/保存/应用 | `CreatorOrchestratorTests/testThreeProtocolsAndTemplatesCompleteRealSnapshotImportAndCoverRead`；`CreatorPanelTests/testControllerGeneratesReadyWithoutImportOrDesktopAndShowsUsage` | Mock→真实离屏渲染→临时入库通过；真实 smoke 及固定模型 30 个样本完整闭环已通过；手动应用/视觉效果待 S3 |
| AC-02 迭代历史 | `CreatorGeneratorTests/testExplicitBaseRevisionCreatesNewHistoryAndKeepsPreviousBytesAndReports`；`CreatorIterationTests/testFailedSecondVersionAndRestartKeepLastFullyValidatedVersion` | 不可变历史、指定父版本、失败保留上一版；不替换桌面 |
| AC-03 有限修复 | `CreatorRepairTests/testMalformedThenMissingParameterRepairsTwiceWithoutCommittingInvalidDrafts`；`CreatorRepairTests/testThreeInvalidResponsesExhaustOneBudgetAndNeverSendFourthRequest` | 最多首次+两次修复，完整重新校验；截断/401/超时/取消有独立回归 |
| AC-04 路径/体积 | `CreatorDraftTests/testSymlinksHardlinksExtraFilesAndForeignDirectoriesAreRejected`；`CreatorOutputValidatorTests/testCodeAssetsCapabilitiesAndPathKeysArePolicyViolations`；`CreatorOutputValidatorTests/testByteLimitAppliesBeforeWhitespaceAndFenceRemoval` | 模型不能输出路径/资源包；链接、额外文件、超大输出拒绝 |
| AC-05 越权 | `CreatorDraftTests/testNetworkDownloadAllocationAndLogPayloadsNeverReachPreview`；`CreatorPreviewTests/testNetworkAPIsAndRemoteResourcesAreBlockedBeforeReachingLocalServer` | 模板前置拒绝及部分 WebKit 探针通过；S0 三项失败探针仍跳过，S4 未解锁 |
| AC-06 资源/停止 | `CreatorTemplateRenderingTests/testCombinedWorstCaseUsesBoundedParticlesTrailsPixelsAndFrameRate`；`CreatorTemplateRenderingTests/testPauseResizeResumeAndStopAcrossEveryTemplate` | 固定模板边界及 1800 秒三页面长稳通过；不能据此声称任意死循环可终止，S4 待验证 |
| AC-07 取消/重启 | `CreatorRevisionStoreTests/testRestartCleansInterruptedJobsAndRecoversLastValidSelection`；`CreatorAcceptanceTests/testHeadlessAndPanelRecoveryShareOneOperationAndPreserveValidRevision`；`CreatorAcceptanceTests/testBridgeBootstrapWaitsForRecoveryBeforeEnteringEngine` | 任务恢复、共享恢复和启动顺序通过；取消不发布半成品 |
| AC-08 离线播放 | `CreatorSoakTests/testShortSoakStartsSavedTemplatesOfflineAndSamplesPauseResizeMemoryAndStop`；`CreatorSoakTests/testNetworkAttemptObserverHasPositiveControlWithoutExternalConnection` | 三个已保存模板以离屏页面新加载，不创建模型客户端；短测及真实 1800 秒/540 次采样的 API/DOM/CSP/资源观察中外连尝试均为 0；正向对照检出回环请求；物理断网桌面待 S3 |
| AC-09 存储故障 | `CreatorAcceptanceTests/testUnavailableLibraryRetainsOldVersionAndRecoverableJournal`；`CreatorStorageFormatTests/testAtomicWriteFailureKeepsOldRecordAndRejectsUnknownOrCorruptedRecords` | 库不可用和原子写失败注入，旧版/日志保留；未填满真实磁盘或拔盘 |
| AC-10 篡改 | `CreatorAcceptanceTests/testSingleByteInEveryInstalledFileRefusesPlaybackAndPlaylistPreflight`；`CreatorRevisionStoreTests/testMetadataAndHostChangesInvalidateReportsWithoutRewritingRevisions` | 四文件各翻转单字节拒绝正式播放/播放列表前检；元数据/策略/宿主版本失配失效 |
| AC-11 双屏/睡眠 | `CreatorAcceptanceTests/testConcurrentPlaybackReadersShareLeaseWhilePublicationWaits` | 仅并行读取边界自动化通过；真实目标屏、睡眠唤醒与画面恢复待 S3，本项未完成真机验收 |
| AC-12 无凭据残留 | `CreatorAcceptanceTests/testCredentialEchoesInValidMetadataAreRejectedBeforeAnyRevisionOrLogWrite`；`CreatorBenchmarkTests/testTenPromptsThreeRoundsUseRealValidationAndDeterministicMockStatistics` | 合成 API Key/Cookie 回显拒绝、全目录/日志扫描无残留；缺失用量为未知，不当作 0 |
| AC-13 更新失败回退 | `CreatorPublicationTests/testPublicationFailuresOnBothSidesOfConfirmationRestoreOrKeepWholeVersion`；`CreatorAcceptanceTests/testUnconfirmedRegistryCannotPlayAndHeadlessRecoveryRestoresPreviousSelection` | 确认前回旧版、确认后保完整新版；显式选中版本保留；真实桌面失败切换待 S3 |
| AC-14 全入口策略 | `CreatorAcceptanceTests/testUnknownPolicyAndMalformedPublicationJournalFailClosed`；`CreatorAcceptanceTests/testUnconfirmedRegistryCannotPlayAndHeadlessRecoveryRestoresPreviousSelection`；`CreatorStorageBoundaryTests/testOldBackupContainingAIWallpaperIsRefused` | 后台 bootstrap、播放列表前检、真实 WK 页面拒绝未确认事务；未知策略/损坏日志拒绝；旧备份拒绝而非降级 |

AC-15～18 继续由 `CreatorTemplateCatalogTests/CreatorTemplateRenderingTests`、`CreatorPosterTests`、
`LLMCodecTests/LLMStreamTransportTests`、`ProviderCredentialStoreTests/ProviderProfileTests` 回归。
这四项的已有自动化没有替代效果偏好、三协议真实端点或设备验收。

## 10×3 基准的统计口径

固定语料 v1 位于 `CreatorBenchmarkHarness.prompts`：G01～G03 渐变，S01～S04 星空，C01～C03 时钟。
覆盖简单布局、多维效果、极值参数以及用安全参数模拟超出能力的意图。
每条提示词独立建工程，共三轮，均经过静态校验、真实离屏 WKWebView、原生 JPEG、封闭修订和临时入库。
记录实际模板 ID；可运行分数不等于遵循所有视觉意图，也不等于用户视觉满意率。

- 每样本最多 3 个请求、每请求 2048 输出 token 预留、每样本预留上限 6144；全批最多 90 次请求。
- 记录首次通过率、最多两次修复后通过率、全部/成功样本耗时分布（min、最近秩 p50/p95、max），包含失败样本。
- `known*Tokens` 仅求已知部分；`unknownUsageAttempts/incompleteUsageAttempts` 分别记录完全缺失和部分缺失。
  语法损坏若在 Codec 结束校验失败，可能无法取得用量；不能凭响应片段补造用量。预留输出不是账单费用。
- 401、配置失效立即结束批次并保留部分报告；取消不继续。未完成 30 个样本时 `complete=false`，不能认定达到 PRD 目标。
- 只有 `mode=live`、30 个样本完整、最终通过率 ≥80% 才有 `targetEstablished=true`。
  Mock 的 60% 首次/90% 最终通过只是预设统计管线对照，不是模型测量。

真实评测默认跳过。临时 Key 仅由 Python 一次性回环服务交给测试进程内存；启动 XcodeGen、Xcode 和任何
子进程前已从环境删除原始 Key。无个人 Keychain，无 Key 文件。完整门禁/其他测试类/多模式同时开启会拒绝。
本次收口复核用户已运行的报告，不再次发起真实请求；以下命令仅供下一次显式授权时复现。

在仓库根目录的 zsh 中运行（将端点和模型换成已批准的配置；输入 Key 时不回显）：

```zsh
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
unset TEST_RUNNER_CREATOR_LIVE_LLM TEST_RUNNER_CREATOR_SOAK TEST_RUNNER_CREATOR_LIVE_API_KEY
unset WALLPAPER_MACHINE_MEDIA_TESTS WALLPAPER_MACHINE_NETWORK_TESTS WALLPAPER_MACHINE_WEB_REFERENCE
read -r -s 'creator_benchmark_key?临时 API Key：'
print
CREATOR_LIVE_API_KEY="$creator_benchmark_key" \
TEST_RUNNER_CREATOR_BENCHMARK=1 \
CREATOR_BENCHMARK_ALLOWANCE=3600 \
CREATOR_LIVE_TIMEOUT=90 \
TEST_RUNNER_CREATOR_LIVE_PROTOCOL=openaiCompatible \
TEST_RUNNER_CREATOR_LIVE_ENDPOINT='https://api.example.com/v1' \
TEST_RUNNER_CREATOR_LIVE_MODEL='填写已批准的模型 ID' \
TEST_RUNNER_CREATOR_LIVE_JSON_MODE=automatic \
TEST_RUNNER_CREATOR_LIVE_LOCAL_MODE=0 \
python3 scripts/test.py --only CreatorBenchmarkLiveTests --serial
unset creator_benchmark_key
```

其他协议分别用 `anthropicMessages`、`geminiGenerateContent` 和该 Profile 端点/模型；Gemini 仍使用
请求头 Key。仅显式本地 openaiCompatible、精确循环回环主机允许 HTTP/空 Key，此时设 `LOCAL_MODE=1`。
基准用例在工作开始前显式设置 `executionTimeAllowance`，由 `CREATOR_BENCHMARK_ALLOWANCE` 配置，默认
3600 秒，允许 600～86400 秒。`CREATOR_LIVE_TIMEOUT` 默认 90 秒，允许 5～600 秒，覆盖原生截止时间和
URLSession/URLRequest 超时；共享传输层的生产默认值仍为 60 秒。两项配置也接受 `TEST_RUNNER_` 前缀，
同一项两种写法冲突、非数值、非有限值或越界会在启动子进程前拒绝，错误不回显原值。
放宽单次请求不会自动延长整批用例时限；大型本地模型需同时增大整批时限。模型和输入 token 也可能收费。

启动器同时显式传入 `-default-test-execution-time-allowance` 和 `-maximum-test-execution-time-allowance`，
取 `max(6000, 用例时限向上取整到整分钟)`，避免默认 600 秒及最大值截断；日常门禁的时限不变。
每个样本结束后向 stderr 立即刷新一行固定格式进度：序号/30、round、passed、attemptCount、耗时秒数、
原生 failure 枚举名（成功为 none）；静默运行器只透传该格式，不打印 URL、模型原始输出或 Key。
JSON 附件记录实际两项时限；进程被系统强杀时仍不能保证 defer 附件写出，进度不等同于完整报告。
`TEST_RUNNER_CREATOR_LIVE_JSON_MODE` 支持 `automatic`（缺省）、`required`、`schema`、`disabled`：
automatic 对模板生成优先发原生 `json_schema`，明确不支持时在同一最多三次预算内降级为纯提示词；
required 发 `json_object`，schema 强制原生 Schema，两者不自动降级；disabled 不发 response_format。
记录实际模式；固定评测条件可显式选 schema 或 disabled。只有结构化错误明确指出 response_format
及受支持的不兼容错误码时才降级，不凭任意错误文案猜测。单次 S1.4 冒烟仍保持 requestBudget=1。
Prompt 的完整扁平时钟示例与请求用 Schema 均来自原生目录，properties 默认空对象；详见
[参数生成合同](creator-generation.md#prompt-and-output-contract)。修复后本次固定模型/schema 的真实通过率为 100%，证据及适用范围见本文开头。

## 长稳入口与可测边界

长稳测试连续保留三个真实离屏 WKWebView，默认每个至少 1800 秒，每 10 秒轮换暂停/恢复及
1920×1080、1920×1200、1080×1920 尺寸；每次采样等待原生属性同步及新的绘制。
外部 Swift 截止时间限制单次响应等待，WebKit 终止回调独立计数；结束/异常/取消均停止所有创建的页面。
最后时刻也采样。报告包括环境、逐样本存活/绘制/暂停/尺寸、宿主内存基线/峰值/结束/停止后值与差额。

使用现有 `ProcessFootprint.current()` 读取宿主 `ri_phys_footprint`；不包括独立 WebContent/GPU 进程，
不能推断单壁纸内存或 GPU 利用率。内存当前为观察指标，未定义校准后的增长阈值，不自动宣称“无内存泄漏”。
离屏 rAF 可能被系统节流；采样通过原生 resize 促成绘制，不能推导可见桌面 30 FPS/能耗。
没有使用私有 WebContent PID API，没有注入任意死循环。S4 的隔离/外部销毁重建关口不变。

```zsh
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
unset TEST_RUNNER_CREATOR_BENCHMARK TEST_RUNNER_CREATOR_LIVE_LLM CREATOR_LIVE_API_KEY TEST_RUNNER_CREATOR_LIVE_API_KEY
unset WALLPAPER_MACHINE_MEDIA_TESTS WALLPAPER_MACHINE_NETWORK_TESTS WALLPAPER_MACHINE_WEB_REFERENCE
TEST_RUNNER_CREATOR_SOAK=1 \
TEST_RUNNER_CREATOR_SOAK_SECONDS=1800 \
TEST_RUNNER_CREATOR_SOAK_INTERVAL=10 \
python3 scripts/test.py --only CreatorSoakLiveTests --serial
```

时长允许 1～86400 秒，间隔 0.1～60 秒且不超过时长，每模板最多 10000 次周期采样加结束采样。
短于 1800 秒的显式运行会报告 `completedThirtyMinutes=false`；不会把短测当作 30 分钟验收。
用例在加载页面前显式设置 `executionTimeAllowance = max(duration + 600, 2400)`（默认 2400 秒）；
启动器的默认/最大时限均为 `max(6000, 用例时限向上取整到整分钟)`，最长配置对应 87000 秒。
日常门禁仅跑约 0.8 秒短测和取消/超时/正向探针。

## 报告位置与复现

两种 opt-in 运行会自动把 XCTest JSON 附件导出到
`artifacts/tests/Tests-时间戳.reports/`，目录名在命令结尾打印；`manifest.json` 对应报告名字和文件。
源 xcresult/log 保留在相邻位置。导出失败会返回非零，原附件仍在 xcresult 中，可重试：

```zsh
xcrun xcresulttool export attachments \
  --path 'artifacts/tests/填写实际结果包.xcresult' \
  --output-path '/tmp/creator-acceptance-reports'
```

XCTest 测试本身只写临时隔离目录与附件，不访问用户 Documents 或真实库；导出由 Python 运行器完成。
批次认证/配置错误保留已完成样本；进程被强制终止时 XCTest 可能来不及保存附件，此时缺失报告就是未完成，
不能把部分运行认定为达标。历史 S1.4 单次真实 smoke 仍保持 requestBudget=1。

## 最终常规门禁（2026-11-11）

完整 `python3 scripts/test.py` 仅运行一次，exit 0：**708 项 Python（34 个模块）、4,994 项原生通过，0 失败、72 跳过（原生总计 5,066）**。
原生结果包约 109 秒，完整命令约 127 秒。执行前清除全部 Creator live/benchmark/soak 以及媒体、网络、参考渲染开关；
结果树再次确认三个真实入口各跳过 1 项，没有重新发送真实模型请求。新增 Prompt/Schema、超时和修复回归均包含在常规门禁中。
72 项跳过还包括 62 项媒体/设备、3 项 Steam 网络、1 项参考渲染和 3 项 S0 自由代码已知失败探针；跳过不是通过。

构建日志有 6 条依赖库部署版本警告（quickjs-ng/libpng/brotli，在 app 与 extension 链接时各出现一次），
以及 1 条未依赖 AppIntents 因而跳过元数据提取的警告。结果包记录 3 条主线程运行时提示，来自
`AppUpdateTests/testSignatureCheckRefusesAnUnsignedOrAlteredCopy`、
`VideoFormatSupportTests/testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne`、
`WebMOpeningTests/testAVp9FileOpensWithItsFormatSizeAndLength`。三个既有测试均通过；本轮未修改这些领域，也未把警告声明为已修复。

完整门禁前后 3,720 个非文档文件的 SHA-256 一致；本轮收口只更新证据与文档，并去掉本地化目录的纯格式重排，
保留全部三条新增提示及六语言译文。最终文档检查单独执行，不重复完整门禁。
未改动 Rust/renderer/FFI，不另跑相关内核门禁；未构建 Release、安装/启动应用或操作真实桌面。
临时附件清理后只将白名单聚合指标留在版本库；原始日志、结果包、报告目录及确认归属的临时测试根目录不提交。

## 初次自动化交付记录（历史）

初次完整 `python3 scripts/test.py` 本轮仅执行一次，exit 0：**701 项 Python、4,978 项原生通过，0 失败、72 跳过（原生总计 5,050）**。
新增 16 项原生验收/统计/短稳测试与 6 项 Python 入口测试全部通过。较广定向回归 105 通过、0 失败、5 跳过；
最后错误提示补充后定向 52 通过、0 失败、3 跳过。全量前后 1,246 个源码/测试/配置文件 SHA-256 一致，
9 个冻结模板/黄金回归源文件与 S2.2 基线一致。文档检查另行记录，不触发第二次完整门禁。

跳过：62 项媒体/设备，3 项 Steam 网络，1 项参考渲染，3 项 S0 自由代码失败探针，
以及 live smoke、真实基准、长时浸泡各 1 项。跳过不是通过。

完整门禁有 2 条原有领域的主线程耗时警告：
`VideoFormatSupportTests/testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne`、
`AppUpdateTests/testSignatureCheckRefusesAnUnsignedOrAlteredCopy`。两个测试均通过，未把警告当作已修复。
最终结果包无编译警告条目；未改动 Rust/renderer/FFI，无须额外 renderer/Rust 门禁。

Mock 基准为 30 样本、48 次模拟请求：首次 60%、两次修复内 90%；已知 token 小计 480，24 次用量未知。
全部样本耗时 p50 0.347 秒、p95 0.470 秒、最大 0.612 秒，**包含本地 Mock 的延迟，不能推导真实模型速度或费用**。
真实目标标识 `targetEstablished=false`。短稳实际 0.825 秒，三个页面正常停止、外连观察值为 0，
`completedThirtyMinutes=false`；宿主内存原始样本与差额已保留，没有作出长期无泄漏或 GPU 结论。

定向迭代记录：初次构建修正可选值与主线程标注；修正 Mock 序列跨样本复用、损坏响应未知用量的错误预期，
并明确自定义存储的日志配对（旧调用意外检查默认日志会报 busy）。这些问题在完整门禁前修正，未删除失败断言、
改动冻结内核或把它们转为跳过。后续发现的凭据回显路径也已加真实生成回归。所有这些均未运行付费模型。


S3 待授权：Release 构建/安装、可见 UI/VoiceOver、真实显示器应用与回退、双屏、睡眠唤醒、物理断网播放、
用户视觉满意率及电池/能耗。真实 10×3 可运行率和 30 分钟离屏长稳证据已在本次收口核对，不能替代这些设备及体验验收。S4 自由代码保持关闭。

初次自动化交付的临时产物清理记录：最后保留的 5 组测试日志/xcresult 已删除，其余 3 组由运行器按规则淘汰；
`artifacts/tests/` 已为空。结构化门禁摘要、完整用例结果、源码摘要及基准/短稳 JSON 已先行保留。
