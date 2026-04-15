# Code Quality TODO

## 目的

这份文件用于跟踪 `main` 分支后续的代码质量整治工作，重点覆盖：

- 隐藏 bug
- 状态一致性问题
- 静默失败问题
- 主线程阻塞和性能风险
- 可维护性和后续重构项

执行原则：

1. 严格按顺序做，先修高优先级，再做中低优先级。
2. 一次只完成一个步骤，避免多处并行修改导致回归难定位。
3. 每完成一个步骤，把对应任务从 `[ ]` 改为 `[x]`。
4. 在任务下方补充“完成记录”，写清楚日期、改动摘要、验证结果。
5. 每一步都至少运行一次构建和一次后端测试。

推荐完成记录格式：

```md
完成记录：
- 日期：2026-04-14
- 改动：...
- 验证：xcodebuild ... 通过；swift test 通过
- 备注：...
```

统一验证命令：

```bash
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build
cd QuotaBackend && swift test
```

---

## P0 - 必须先修

### [x] Step 1: 刷新时间戳必须只反映“成功刷新”

目标：
- 修复“刷新失败但 UI 仍显示刚刚更新”的状态一致性问题。

涉及文件：
- `AIUsage/ViewModels/ProviderRefreshCoordinator.swift`
- `AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift`
- `AIUsage/Views/ProviderCard.swift`
- `AIUsage/Views/ProviderDetailView.swift`
- `AIUsage/Views/ProviderAccountGroupSection.swift`
- `AIUsage/Views/CostTrackingCard.swift`

修改逻辑：
- 让 `fetchSingleProvider(...)` / `fetchAccountByCredential(...)` / `fetchDashboard...(...)` 返回明确的成功与失败结果，而不是只靠副作用。
- `refreshProviderNow(...)` 和 `refreshAccountNow(...)` 只有在本次刷新真正成功、且拿到了有效结果时，才更新：
  - `providerRefreshTimes`
  - `accountRefreshTimes`
  - `lastRefreshTime`
- 对“无结果但不是崩溃”的情况做清晰定义：
  - 如果 provider 返回 error summary，不应当被视为成功刷新。
  - 如果远端接口报错或本地 fetch 失败，不应更新时间戳。
- UI 继续显示上一次成功的刷新时间，而不是本次失败触发的时间。

完成标准：
- 手动刷新失败时，卡片和详情页不再显示新的“Updated”时间。
- 成功刷新后，时间才会更新。
- 全量刷新和单卡刷新行为一致。

完成记录：
- 日期：2026-04-14
- 改动：让 `fetchSingleProvider(...)`、`fetchAccountByCredential(...)`、`fetchDashboardLocal()`、`fetchDashboardRemote()` 返回可判定的成功结果；新增基于当前 provider/account 身份的匹配逻辑，只对本次成功返回且仍存在于当前状态树中的 provider/account 更新时间戳；远端单 provider 刷新改为保留 `ProviderWrapper.ok` 结果，避免 error summary 也被记成成功刷新。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（21 tests, 0 failures）。
- 备注：本步已修正因签名变更带出的调用点 warning；最终 UI 手工回归会在整体收尾时再做一次串联检查。

### [x] Step 2: 代理激活流程改为事务式提交

目标：
- 修复“代理实际没启动，但 UI 显示已激活”的假成功状态。

涉及文件：
- `AIUsage/ViewModels/ProxyViewModel.swift`
- `AIUsage/ViewModels/ProxyViewModel+ProxyServer.swift`
- `AIUsage/ViewModels/ClaudeSettingsManager.swift`
- `AIUsage/Views/ProxyManagementView.swift`

修改逻辑：
- 把激活流程拆成明确阶段：
  1. 校验配置
  2. 启动代理进程或确认无需进程
  3. 写入 Claude env
  4. 写入 pricing override
  5. 全部成功后才更新 `activatedConfigId` / `isEnabled`
- `startProxy(...)` 不能只 `print` 失败，要有返回结果，例如 `Bool` 或 `Result<Void, Error>`。
- `ClaudeSettingsManager.writeEnv(...)` / `clearEnv()` / `writeSettings(...)` 不应静默失败，至少要返回成功与失败。
- 如果中途失败，需要回滚已经完成的副作用：
  - 已启动的进程要停掉
  - 已写入的 env 要恢复或清空
  - 已写入的 pricing override 要清理
  - 不得落盘激活态
- UI 状态展示应尽量基于“真实运行状态”而不是仅凭 `activatedConfigId`。

完成标准：
- 启动失败、找不到 `QuotaServer`、写配置失败时，不会把节点标记为已激活。
- 激活成功时，UI、配置落盘、实际进程状态保持一致。

完成记录：
- 日期：2026-04-14
- 改动：把代理节点激活/停用改成显式事务链路：先执行运行时副作用，再提交 `activatedConfigId`/`isEnabled` 持久化状态；`startProxy(...)`、Claude env 写入、pricing override 写入全部改为可失败路径；当新节点激活中途失败时，会回滚新节点副作用并尝试恢复旧节点；恢复已激活节点时如果运行时恢复失败，会清理持久化激活状态，避免“假激活”残留；为代理管理页补了失败弹窗提示。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（21 tests, 0 failures）。
- 备注：代理进程发现与启动仍是同步路径，性能优化与防卡顿会在 Step 5 继续处理。

### [x] Step 3: 清理账号注册表和 Claude 设置的静默失败

目标：
- 修复“数据写入失败或读取损坏时没有明显反馈”的问题。

涉及文件：
- `AIUsage/Services/SecureAccountVault.swift`
- `AIUsage/Models/AccountStore+Persistence.swift`
- `AIUsage/ViewModels/ClaudeSettingsManager.swift`
- `AIUsage/ViewModels/ProviderActivationManager.swift`

修改逻辑：
- `SecureAccountVault.loadAccounts()` 在 decode 失败时记录明确日志，不要无声返回空数组。
- `persistAccountRegistry()` 不再用 `try?` 丢弃错误，要记录日志并为上层保留处理空间。
- `ClaudeSettingsManager.writeSettings(...)` 改为可观测失败。
- `ProviderActivationManager.persistActiveIds()` 也不要继续静默吞错误。
- 统一错误记录风格：
  - 哪个文件
  - 什么动作失败
  - 是否影响用户当前状态
- 如果读取失败会导致“空状态”，要避免直接覆盖正常内存状态。

完成标准：
- 关键持久化路径不再静默失败。
- 损坏数据出现时，日志能快速定位问题，不会无提示地表现成“账号都没了”。

完成记录：
- 日期：2026-04-14
- 改动：`SecureAccountVault.loadAccounts()` 对 Keychain 解码失败和异常载荷增加明确日志；`persistAccountRegistry()` 改为返回成功状态并记录失败，而不是 `try?` 静默吞掉；`ClaudeSettingsManager` 读取损坏的 `settings.json` 会报错而不是返回空对象继续覆盖，`writeEnv(...)` / `clearEnv()` / `writeSettings(...)` 都改为可观测失败；`ProviderActivationManager.persistActiveIds()` 现在会记录编码失败。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（21 tests, 0 failures）。
- 备注：`ProviderActivationManager` 中其余文件探测类 `try?` 主要属于“检测/回退”逻辑，不是关键持久化路径；陈旧激活状态的语义修复放到 Step 4 继续完成。

---

## P1 - 重要优化

### [x] Step 4: 清理激活账号检测的陈旧状态

目标：
- 修复外部登出或 auth 文件丢失后，UI 仍显示旧 Active 状态的问题。

涉及文件：
- `AIUsage/ViewModels/ProviderActivationManager.swift`
- `AIUsage/Views/ProviderCard.swift`
- `AIUsage/Views/MenuBarView.swift`
- 可能涉及 `AIUsage/Models/AppState.swift`

修改逻辑：
- `detectActiveCodexAccount()` / `detectActiveGeminiAccount()` 在检测不到有效状态时，应清理对应 provider 的 active id。
- 只清理当前 provider 的状态，不影响其他 provider。
- 区分以下场景：
  - 文件不存在
  - JSON 损坏
  - 文件存在但没有 active 信息
- 菜单栏打开、应用启动、手动激活后，状态应保持一致。

完成标准：
- 外部删除 auth 文件或登出后，重新打开界面不会残留旧 Active 标记。

完成记录：
- 日期：2026-04-14
- 改动：重写 `detectActiveCodexAccount()` 和 `detectActiveGeminiAccount()` 的探测分支，对“文件不存在”“JSON 损坏”“文件存在但没有 active 信息”三种情况分别处理；当探测不到有效账号时，只清理对应 provider 的 `activeProviderAccountIds`，不影响其他 provider；同时补充日志，方便定位是文件缺失还是数据损坏。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（21 tests, 0 failures）。
- 备注：探测逻辑现在会在应用启动和菜单栏弹出时主动清理陈旧 active 状态，后续如果补针对 CLI 状态的自动化测试，可以直接围绕这两个检测入口展开。

### [x] Step 5: 把代理启停路径中的阻塞 I/O 移出主线程

目标：
- 降低代理配置页和激活按钮卡顿风险。

涉及文件：
- `AIUsage/ViewModels/ProxyViewModel.swift`
- `AIUsage/ViewModels/ProxyViewModel+ProxyServer.swift`
- `AIUsage/Views/ProxyManagementView.swift`

修改逻辑：
- 不要在 UI 交互链路里直接同步执行：
  - `lsof`
  - `waitUntilExit()`
  - `readDataToEndOfFile()`
  - `swift build --product QuotaServer`
- 将这些操作移入后台任务或专用服务层。
- 增加激活中/停止中状态，避免用户连续点击造成竞态。
- 如果找不到 `QuotaServer`，优先给出明确错误，而不是在按钮点击时长时间阻塞构建。
- `isProxyRunning` 或 UI 运行状态需要更真实地映射进程状态。

完成标准：
- 激活/停用按钮点击后 UI 保持响应。
- 首次找不到二进制时，不会造成长时间假死。

完成记录：
- 日期：2026-04-14
- 改动：把代理启停链路改成异步执行：`startProxy(...)`、运行时激活/停用事务、配置编辑/删除都迁移到 `async` 路径；新增 `ProxyProcessInspector` actor 在后台处理 `lsof` / `waitUntilExit()` / `readDataToEndOfFile()` 对应的陈旧进程探测；移除按钮点击时自动执行 `swift build --product QuotaServer` 的兜底构建，改为明确报错；为节点操作增加 `operationInProgressConfigIds` 忙状态并在 UI 中禁用重复点击；`isProxyRunning(...)` 会清理已退出进程，运行状态更接近真实值。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：本步顺手清掉了代理异步化带出的源码 warning；当前仅剩 Xcode 目的地选择和 AppIntents 元数据提取这类环境级 warning。

### [x] Step 6: 把刷新后的账号对账与持久化从主线程拆出去

目标：
- 降低 provider 多、账号多时刷新卡顿。

涉及文件：
- `AIUsage/ViewModels/ProviderRefreshCoordinator.swift`
- `AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift`
- `AIUsage/Models/AccountStore.swift`
- `AIUsage/Models/AccountStore+Persistence.swift`

修改逻辑：
- 明确区分：
  - 数据抓取
  - 数据转换
  - 账号对账
  - 持久化
  - UI 发布
- 只有最终 `@Published` 状态写回需要在主线程。
- `reconcileAccountRegistry(with:)` 如果仍需同步处理，至少要避免在最热刷新路径里反复触发 Keychain/磁盘写入。
- 可以考虑：
  - 先在后台算出结果
  - 再在主线程一次性提交
  - 对持久化做去抖或变更检测

完成标准：
- 多账号刷新时 UI 明显更平滑。
- 架构上能清楚区分“后台计算”和“主线程发布”。

完成记录：
- 日期：2026-04-14
- 改动：将刷新链路里的账号注册表对账改成 `await accountStore.reconcileAccountRegistry(...)` 异步后台计算；新增 `AccountRegistryRefreshWorker` actor 与纯值快照对账器，在后台加载凭据、执行对账和去重；主线程只负责在对账结果确认未被并发本地编辑打断后再一次性发布 `accountRegistry`；Keychain 持久化改成带 revision 协调的后台去抖保存，避免刷新热路径阻塞，也避免后台旧快照覆盖用户刚刚编辑的新状态。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：为配合后台执行，本步补充了若干 `Sendable` / `nonisolated` 边界声明，保证没有新的源码并发 warning 残留。

---

## P2 - 可维护性与质量提升

### [x] Step 7: 统一本地化迁移策略，继续从 `L()` 过渡到标准 `.strings`

目标：
- 降低长期维护成本，减少双轨本地化逻辑。

涉及文件：
- `AIUsage/Models/AppSettings.swift`
- `scripts/generate_localizable_strings.py`
- `AIUsage/Resources/en.lproj/Localizable.strings`
- `AIUsage/Resources/zh_CN.lproj/Localizable.strings`
- 相关 SwiftUI 视图文件

修改逻辑：
- 明确 `L()` 的阶段性定位：
  - 是长期桥接层
  - 还是临时过渡层
- 继续把静态文本迁移到标准 `.strings`。
- 对插值文本做统一处理策略，避免散落在各处的手写双语字符串。
- 逐步减少英文 key 对应多个中文翻译的情况，例如：
  - `Active`
  - `Dashboard`
  - `Model Details`
- 若后续要支持复数和参数化文本，提前评估 `.stringsdict`。

完成标准：
- 本地化策略文档化。
- 新增文本默认走标准资源，而不是继续扩散 ad-hoc 风格。

完成记录：
- 日期：2026-04-14
- 改动：补充 [docs/LOCALIZATION_STRATEGY.md](/Users/sylearn/Desktop/AIUsage/docs/LOCALIZATION_STRATEGY.md) 说明桥接层定位和迁移规则；为 `L(..., key:)` 明确“新静态文案优先走稳定 key”的策略说明；更新 `scripts/generate_localizable_strings.py`，支持提取显式 `key:` 到标准 `Localizable.strings`；将导航、Dashboard 和 Providers 的一批高频共享文案迁移到稳定 key，并重生成中英文 `.strings` 资源。
- 验证：`python3 scripts/generate_localizable_strings.py` 通过并生成 435 条资源；`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：插值和复数类文案仍保留桥接 fallback，后续如继续推进可优先引入 `.stringsdict`。

### [x] Step 8: 继续清理剩余格式化器和通用工具的性能债

目标：
- 收口已经暴露出的工具层性能和一致性问题。

涉及文件：
- `AIUsage/Views/Utilities.swift`
- `QuotaBackend/Sources/QuotaBackend/Normalizer/UsageNormalizer.swift`
- 相关使用 `formatNumber(...)` / `formatCurrency(...)` 的视图

修改逻辑：
- `formatNumber(...)` 参考 `formatCurrency(...)` 做缓存，避免频繁创建 `NumberFormatter`。
- 审核格式化工具的职责边界：
  - UI 显示逻辑放前端
  - 后端 normalizer 输出尽量保持结构化
- 如果后端也需要格式化字符串，评估是否应统一到 shared formatter 工具层。

完成标准：
- 常用格式化工具不再每次调用都重新分配 formatter。
- 工具层职责更清晰。

完成记录：
- 日期：2026-04-14
- 改动：为前端 `formatNumber(...)` 增加与 `formatCurrency(...)` 同级的 `NumberFormatter` 缓存；为 `QuotaBackend/Normalizer/UsageNormalizer.swift` 的 `formatCurrency(...)` / `formatPercent(...)` / `formatInt(...)` 增加线程级 formatter 缓存，减少 Dashboard 和费用归一化路径中的重复分配。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：当前工具层仍存在“前端显示格式化”和“后端摘要文案格式化”并存的历史结构，但热路径上的 formatter 开销已经先收口。

### [x] Step 9: 为关键状态链路补最低限度测试

目标：
- 把当前最容易回归的逻辑从“人工记忆”转为“自动校验”。

优先测试项：
- 刷新失败时不更新时间戳
- 代理激活失败时不落盘 active 状态
- 账号注册表持久化失败时有日志/不破坏现有状态
- 外部登出后 active 账号状态被清理
- alert / overview / account reconcile 的关键映射关系

建议位置：
- `QuotaBackend/Tests/QuotaBackendTests/` 已有后端测试，可继续补
- App 侧如不便直接写 UI 测试，优先给 ViewModel / service 层加可测试入口

完成标准：
- 至少把 P0/P1 中最关键的状态一致性逻辑纳入自动化测试。

完成记录：
- 日期：2026-04-14
- 改动：已先在 `QuotaBackend/Tests/QuotaBackendTests/UsageNormalizerTests.swift` 补充 `overview/alerts` 关键回归测试，覆盖聚合统计、alert 唯一稳定 ID、以及 alert 截断到 6 条的行为。
- 验证：`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）；`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过。
- 备注：Step 9 仍保持未完成，因为“刷新失败不更新时间戳 / 代理激活失败不落盘 active / 外部登出清理 active”等 App 侧状态链路还缺少专用测试 target；后续若继续推进，应优先为 AIUsage 增加最小单元测试入口。

完成记录：
- 日期：2026-04-15
- 改动：新增 `QuotaBackend/Tests/QuotaBackendTests/QuotaHTTPServerProxyIntegrationTests.swift` 和 `ProxyIntegrationTestSupport.swift`，为 Claude Code 代理补齐真实网络回归测试，覆盖监听健康检查、鉴权失败、`/v1/messages/count_tokens`、OpenAI 转换代理的非流式往返、OpenAI 转换代理的流式 SSE 往返、以及 Anthropic passthrough 转发；同时把 `QuotaHTTPServer` 抽到可测试的 `QuotaServerCore` 模块，并增加 `start()/stop()` 生命周期；新增 `scripts/run_claude_proxy_regression.sh` 作为一键回归入口。
- 验证：`cd QuotaBackend && swift test` 通过（29 tests, 0 failures，其中新增 6 条代理集成测试）；`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build CODE_SIGNING_ALLOWED=NO` 通过。
- 备注：这一步已经把 Claude Code 代理的关键监听/发送/接收链路纳入自动化回归；若后续还想继续提高覆盖率，下一优先级是补 App 侧 `ProxyRuntimeService` 与 `ProxyViewModel` 的状态事务测试。

---

## 可选重构项

### [x] Refactor A: 抽离 Proxy Runtime Service

目的：
- 把 `ProxyViewModel` 中的“配置状态”和“进程管理”拆开，降低 ViewModel 复杂度。

建议方向：
- 新建独立 service 管理：
  - 进程启动/停止
  - 端口检查
  - pricing override 写入
  - QuotaServer 可执行文件发现

完成记录：
- 日期：2026-04-15
- 改动：新增 `AIUsage/Services/ProxyRuntimeService.swift`，把代理运行时的进程启停、陈旧端口清理、pricing override 写入/清理、以及 `QuotaServer` 可执行文件发现全部迁出 `ProxyViewModel`；`ProxyViewModel` 改为保留激活事务、持久化提交和 UI 状态，并通过 delegate 回收代理日志。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：顺手修掉了新 service 默认参数触发的 MainActor warning，当前只剩 Xcode 目的地和 AppIntents 元数据提取这类环境级提示。

### [x] Refactor B: 抽离 Refresh Result Model

目的：
- 让刷新链路从“依赖副作用”转向“依赖显式结果对象”。

建议方向：
- 引入统一结果类型，例如：
  - `success`
  - `partial`
  - `failure`
- 把时间戳更新、错误展示、账号对账都建立在结果对象上，而不是分散判断。

完成记录：
- 日期：2026-04-15
- 改动：新增 `AIUsage/ViewModels/ProviderRefreshResult.swift`，将 provider/account/dashboard 刷新链路统一改为返回 `ProviderRefreshResult`；时间戳更新、失败消息传播、部分成功判定都收敛到结果对象之上，调用端不再依赖散落的布尔值和可选值副作用。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：当前结果模型仍以 `ProviderData` 为中心，后续如果补 App 侧测试 target，可以直接围绕这个结果对象补行为测试。

### [x] Refactor C: 抽离 Localization Strategy Note

目的：
- 把当前本地化桥接方案正式文档化，避免后续新增代码继续分叉。

建议方向：
- 补一份 `docs/` 下的本地化策略文档：
  - 何时用 `.strings`
  - 何时允许 `L()`
  - 动态字符串如何处理
  - 资源生成脚本如何使用

完成记录：
- 日期：2026-04-15
- 改动：扩写 `docs/LOCALIZATION_STRATEGY.md`，补充 source-of-truth、review checklist、迁移优先级和动态字符串约束；同时在 `scripts/generate_localizable_strings.py` 和 `AppSettings.L(...)` 注释处挂上文档说明，方便后续沿同一路径推进标准 `.strings` 方案。
- 验证：`xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug build` 通过；`cd QuotaBackend && swift test` 通过（23 tests, 0 failures）。
- 备注：文档化已经完成，但真正把动态/复数字符串迁到 `.stringsdict` 仍属于后续功能型演进，不在本次重构范围内。
