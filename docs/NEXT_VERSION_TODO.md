# 下一版本计划 (v0.4.21+)

> 上次更新: v0.4.20 发布后
> 维护方式: 完成一项打 `[x]`，新增项追加到对应优先级末尾

---

## P0 — 功能性 Bug（必须在下一版本修复）

当前无已知 P0。

---

## P1 — 架构与健壮性

### 1. JWT 解析集中化
- **现状**: Codex、Gemini、Kiro、Droid 各自实现 JWT base64 解码，存在微妙差异（URL-safe 替换、padding、Codable vs 手动解析）
- **目标**: 抽取 `SharedFormatters.decodeJWT(_:) -> [String: Any]?`
- **涉及文件**:
  - [ ] `QuotaBackend/Sources/QuotaBackend/SharedFormatters.swift` — 新增 `decodeJWT`
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/CodexProvider.swift` — 替换内联 JWT 解析
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/GeminiProvider.swift` — 替换 `GeminiCredentials.jwtEmail()`
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/KiroProvider+Auth.swift` — 替换 token 解析
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/DroidProvider+Helpers.swift` — 替换 `jwtEmail(from:)`
- **验证**: 现有 swift test 全部通过

### 2. Gemini multiWorkspace 评估
- **现状**: Gemini 只读 `~/.gemini/oauth_creds.json` 一个文件，不是 `MultiAccountProviderFetcher`
- **风险**: 同 Google 账号多 GCP 项目场景下，只能监控当前活跃项目
- **决策**: 评估是否有真实用户需求；若有，参考 Codex 模式实现多文件扫描
- **涉及文件**:
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/GeminiProvider.swift` — 评估 / 改造
  - [ ] `QuotaBackend/Sources/QuotaBackend/Engine/AccountCredentialStore.swift` — 若需要，加入 `multiWorkspaceProviders`

### 3. 401/403 → refresh → retry 行为对齐
- **现状**: Codex/Kiro/Gemini/Antigravity 已有 retry，Cursor/Amp/Copilot 因认证方式不同（cookie/token）未实现
- **目标**: 确认 Cursor/Amp/Copilot 是否需要 retry（cookie 过期通常需要重新登录），记录设计决策
- **涉及文件**:
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/CursorProvider.swift`
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/AmpProvider.swift`
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/CopilotProvider.swift`

### 4. `metadata["sourcePath"]` 对齐
- **现状**: Codex 已完整实现原始路径锚点，Gemini/Kiro/Antigravity 部分实现或未实现
- **目标**: 所有 authFile 类 provider 的 credential 都正确存储 `metadata["sourcePath"]`
- **涉及文件**:
  - [ ] `AIUsage/Services/ProviderAuthManager.swift` — 检查各 provider 的 `authenticateCandidate`
  - [ ] 各 provider 的 `fetchUsage(with:)` — 验证 resync 逻辑一致

---

## P2 — 代码质量与可维护性

### 5. 匹配逻辑去重
- **现状**: `bestStoredAccountIndex` / `storedAccountMatchesLive` 在 `AccountStore+Matching.swift` 与 `AccountRegistryRefreshSnapshot` 各一份
- **风险**: 改一处漏改另一处
- **目标**: 抽到 `AccountIdentityPolicy` 的 nonisolated 纯函数
- **涉及文件**:
  - [ ] `AIUsage/Models/AccountStore+Persistence.swift` — `AccountRegistryRefreshSnapshot` 内的匹配逻辑
  - [ ] `AIUsage/Models/AccountStore+Matching.swift` — `AccountStore` 扩展的匹配逻辑
  - [ ] 新建或扩展 `AccountIdentityPolicy` 模块

### 6. `.atomic` 写入全局对齐
- **现状**: Antigravity 已修复，检查是否还有其他 provider 遗漏
- **涉及文件**:
  - [ ] 全局搜索 `.write(to:` 确认无遗漏

### 7. `refreshFromSourceAndRetry` 排除列表对齐
- **现状**: 部分 provider 在 `ProviderEngine` 的 resync 排除列表中，需确认是否正确
- **涉及文件**:
  - [ ] `QuotaBackend/Sources/QuotaBackend/Engine/ProviderEngine.swift`

---

## P3 — 性能优化

### 8. Cursor/Amp sqlite 复制优化
- **现状**: 已复制 WAL/SHM，但仍是完整文件复制
- **可能方案**: 使用 sqlite3 的 backup API 或直接内存读取
- **涉及文件**:
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/CursorProvider.swift`
  - [ ] `QuotaBackend/Sources/QuotaBackend/Providers/AmpProvider.swift`

---

## 已完成（归档）

| 版本 | 项目 | 状态 |
|------|------|------|
| v0.4.20 | Provider 全量审查 20 项修复 | done |
| v0.4.19 | Codex 身份链 13 项修复 | done |
| v0.4.18 | 代理节点拖拽排序 | done |
| v0.4.17 | sourceFilePath 重构 + 激进清理 | done |

---

## 模板说明

新增待办项格式：
```
### N. 简短标题
- **现状**: 当前问题描述
- **目标**: 期望达到的效果
- **涉及文件**:
  - [ ] `路径/文件名` — 具体要做什么
- **验证**: 如何确认修复正确
```

优先级定义：
- **P0**: 影响用户数据正确性或导致崩溃，下一版本必修
- **P1**: 架构隐患或边界条件，近期应修
- **P2**: 代码质量和可维护性，有空时修
- **P3**: 性能优化，按需修
