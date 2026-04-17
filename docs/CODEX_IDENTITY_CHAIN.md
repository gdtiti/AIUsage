# Codex 账号身份链：去重与全链路逻辑

## 核心原则

Codex 与其他 Provider 的本质区别：**同一 email 可属于多个空间（个人/不同 Team），同一 Team 可包含多个 email**。

因此对 Codex，**email 不能作为唯一标识**。代码中通过 `AccountIdentityPolicy.isMultiWorkspace(_:)` 判断（当前包含 `"codex"`），multi-workspace provider 的所有匹配、去重、关联逻辑只使用 **credentialId** 和 **sourceFilePath** 两个维度，不依赖 accountId 或 email。

## 已知的 accountId 问题

| 现象 | 原因 |
|------|------|
| Plus 和 Team 返回相同的 `user-xxx` | API 的 `account_id` 是**用户个人 ID**，不区分 workspace |
| API 失败后 accountId 变为 workspace UUID | 引擎回退使用 credential 中的值，格式不同 |

因此 **accountId 也不能单独作为 Codex 账号的唯一标识**。

## 唯一性策略

| 标识 | 稳定性 | 来源 | 对 Codex 的用途 |
|------|--------|------|----------------|
| credentialId | 绝对稳定 | 凭证创建时生成的 UUID | **首选**：匹配、去重、关联 |
| sourceFilePath | 绝对稳定 | auth 文件路径（归一化后） | **核心匹配键**：每个 workspace 对应唯一路径 |
| authFile path | 绝对稳定 | 导入时的文件路径（归一化后） | 凭证去重的 key |
| providerResultId | 稳定 | `provider:cred:<credentialId>` | credentialId 的载体 |
| accountId | **不稳定** | API 或 credential | **Codex 不使用** |
| email | **不可靠** | JWT 解码 | **Codex 不使用** |

## sourceFilePath 全链路贯穿

从数据采集到存储的完整链路：

```
AuthContext.url → AccountFetchResult.sourceFilePath → ProviderSummary.sourceFilePath
    → ProviderData.sourceFilePath → StoredProviderAccount.sourceFilePath
    → reconcile（路径 1:1 匹配）
```

每个 Codex workspace 的 auth 文件路径天然是唯一的（如 `~/.cli-proxy-api/workspace-abc/auth.json`），所以 sourceFilePath 可以做到 1:1 精确匹配。

路径归一化通过 `AccountCredentialStore.normalizedAuthFilePath` 实现：`expandTilde → resolvingSymlinksInPath → standardizedFileURL → lowercased`。

## 统一策略实现 — `AccountIdentityPolicy`

**文件**: `AccountStore+Persistence.swift`

所有核心逻辑统一在 `AccountIdentityPolicy` 中：

- `identityKey(for:)` — 账号去重 key
- `matchesLive(_:provider:)` — 存储→活跃匹配
- `bestStoredAccountIndex(for:...)` — 结果→存储匹配链
- `bestCredentialMatch(for:candidates:)` — 凭证→账号关联
- `normalizedSourceFilePath(_:)` — 路径归一化
- `sourceFilePathsMatch(_:_:)` — 归一化路径比较

## 全链路身份检查

### 1. 凭证去重 — `credentialIdentityKey`

**文件**: `AccountCredentialStore.swift`

对 Codex：authFile 路径归一化优先。非 authFile 的 Codex 凭证用 `accountId:handle` 组合，无 accountId 时降级为 `raw:uuid`。

### 2. 账号去重 — `identityKey`

对 Codex：

```
credentialId 存在 → codex:cred:<credentialId>
sourceFilePath 存在 → codex:path:<normalized_path>
均缺失 → codex:stored:<uuid>（不合并）
```

### 3. 结果→账号匹配 — `bestStoredAccountIndex`

对 Codex：

```
Step 0:   credentialId 精确匹配
Step 0.5: sourceFilePath 归一化路径匹配 → 命中即返回
未命中 → 返回 nil（不继续 fallback）
```

对其他 Provider：

```
Step 0: credentialId
Step 1: accountId
Step 2: matchesLive（providerResultId / email）
Step 3: allowUnseenCredentialFallback
```

### 4. 活跃匹配 — `matchesLive`

对 Codex：credentialId → sourceFilePath → 未命中返回 false（不走 accountId/email）

对其他 Provider：credentialId → providerResultId → accountId → email

### 5. 凭证→账号关联 — `bestCredentialMatch`

对 Codex：仅通过 `providerResultId` 中提取的 credentialId 直接匹配，无 fallback。

### 6. 协调 dupe check

对 Codex：credentialId 匹配 → sourceFilePath 匹配 → 均不匹配则创建新账号。

### 7. 登录去重 — `existingAuthenticatedCredential`

Codex 三层防御：

1. accountId 匹配时 → **追加 sourceIdentifier 匹配**，防止同 user-xxx 的 Plus/Team 互相覆盖
2. accountId 不一致 → return false
3. accountId 一侧缺失（multi-ws） → return false

### 关键保护

- API 失败时不覆盖 stored accountId
- 删除凭证后清理悬空 credentialId 引用
- reconcile 全路径存入 sourceFilePath（成功/失败均写入）
- normalizeAccountRegistryAgainstCredentials 从 credential 的 sourceIdentifier 回填

## Codex 专属禁止项

| 行为 | 状态 | 原因 |
|------|------|------|
| email 作为匹配/去重依据 | 禁止 | 同 email 不同 workspace |
| accountId 作为匹配/去重依据 | 禁止 | API 返回相同 user-xxx（Plus/Team 共享） |
| allowUnseenCredentialFallback | 禁止 | 可能跨 workspace 收养 |
| removeAutoDiscoveredDuplicates 按 email 删除 | 禁止 | 误删不同 workspace |
| API 失败时覆盖 stored accountId | 禁止 | 格式漂移 |

## 场景验证矩阵

| # | 场景 | 凭证去重 | 账号去重 | 匹配 | 协调 |
|---|------|---------|---------|------|------|
| 1 | 多email同Team | authFile不同 | sourceFilePath不同 | Step 0.5各自命中 | 路径不同 |
| 2 | 同email不同Team | authFile不同 | sourceFilePath不同 | Step 0.5各自命中 | 路径不同 |
| 3 | 个人+Team(同email) | authFile不同 | sourceFilePath不同 | Step 0.5各自命中 | 路径不同 |
| 4 | API失败accountId变 | 不涉及 | sourceFilePath不变 | Step 0.5命中 | 路径稳定 |
| 5 | 同user-xxx两空间(Plus+Team) | authFile不同 | sourceFilePath不同 | Step 0.5精确命中 | 路径唯一 |
| 5b | 同user-xxx先Plus后Team登录 | sourceIdentifier不同→不覆盖 | credentialId各自创建 | existingAuthenticatedCredential区分 | 各自独立 |
| 6 | 删除凭证后 | - | credentialId清空 | 不悬空引用 | 孤儿清理 |
| 7 | 自动发现(无credentialId) | - | sourceFilePath 1:1匹配 | Step 0.5直接命中 | 无需email猜测 |
