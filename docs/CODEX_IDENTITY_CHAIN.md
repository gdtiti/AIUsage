# Codex 账号身份链：去重与全链路逻辑

## 核心原则

Codex 与其他 Provider 的本质区别：**同一 email 可属于多个空间（个人/不同 Team），同一 Team 可包含多个 email**。

因此 Codex 的唯一性由 **credential（每个 auth 文件 = 一个凭证 = 一个账号）** 决定，而其他 Provider 仅需 email 或 accountId 单维度。

代码中通过 `multiWorkspaceProviders: Set<String> = ["codex"]` 标记此类 Provider。

### 已知的 accountId 问题

Codex API 返回的 `account_id` 是**用户个人 ID** (`user-xxx`)，不是 workspace 特有 ID。
同一个用户的 Plus 和 Team 账号返回**完全相同**的 `user-xxx`。
因此 **accountId 不能作为 Codex 账号的唯一标识**。

API 失败时，引擎回退使用 credential 中的 workspace UUID 作为 accountId，格式又不同。

### 设计决策

| 标识 | 稳定性 | 来源 | 用途 |
|------|--------|------|------|
| credentialId | 绝对稳定 | 凭证创建时生成的 UUID | 账号匹配、去重的**首选** |
| providerResultId | 稳定 | `provider:cred:<credentialId>` | 账号匹配的第二选择 |
| accountId | **不稳定** | API 返回 `user-xxx` / 失败回退 workspace UUID | 仅在 credentialId 缺失时使用 |
| email | 部分稳定 | JWT 解码 | 最后兜底，但同 email 不同空间会冲突 |

## 数据来源

```
~/.cli-proxy-api/AuthImports/codex/
├── codex-orgXXX-emailA-161410.json   ← Team-X, emailA
├── codex-orgXXX-emailB-204530.json   ← Team-X, emailB (同 Team 不同 email)
├── codex-orgYYY-emailA-182200.json   ← Team-Y, emailA (同 email 不同 Team)
└── codex-personal-emailA-150000.json ← 个人空间, emailA
```

每个 JSON 文件包含：
- `account_id`: workspace UUID（个人空间为 `user-xxx`，Team 为 `org-xxx`）
- `id_token`: JWT，可从中解码出 email
- 认证 token 用于调用 API

## 全链路身份检查（5 个环节）

### 1. 凭证去重 — `credentialIdentityKey`

**文件**: `AccountCredentialStore.swift`

对 Codex（multiWorkspaceProviders），**authFile 路径优先于 accountId**：

```
优先级:
1. codex + authFile → codex:authfile:<文件路径>   ← 每个文件独立
2. accountId       → provider:account:<id>
3. email/handle    → provider:handle:<email>
4. authFile        → provider:authfile:<path>
5. credential id   → provider:raw:<id>
```

### 2. 账号去重 — `storedAccountIdentityKey`

**文件**: `AccountStore+Persistence.swift`

对 Codex，**credentialId 优先**（绝对稳定）：

```
codex + credentialId 存在:
  → codex:cred:<credentialId>           ← 每个凭证唯一

codex + credentialId 不存在 + email 存在:
  → codex:email:<email>                 ← 临时账号兜底

其他 Provider:
  → provider:account:<accountId>        ← accountId 可靠
```

### 3. 结果→账号匹配 — `bestStoredAccountIndex`

**文件**: `AccountStore+Persistence.swift` 和 `AccountStore+Matching.swift`

匹配优先级链（每步命中即返回）：

```
Step 0: credentialId 精确匹配
  → 引擎结果 id 包含 credentialId → 匹配存储账号的 credentialId
  → 最精确，不受 accountId 格式影响
  → 同 email 不同空间：各自凭证不同，正确匹配

Step 1: accountId 精确匹配
  → 对非 Codex 足够
  → 对 Codex 可能误匹配（同 user-xxx）
  → 但 Step 0 已处理 credential-backed 账号

Step 2: storedAccountMatchesLive 模糊匹配
  → 检查 credentialId 构造的 expectedId
  → 检查 providerResultId
  → 检查 accountId + Codex 追加 email 校验
  → 最后 email 兜底
```

### 4. 凭证→账号关联 — `bestCredentialMatch`

**文件**: `AccountStore+Persistence.swift` 和 `AccountStore+Matching.swift`

仅在 `credentialId == nil` 时调用。优先从 `providerResultId` 提取 credentialId：

```
1. providerResultId 包含 :cred:<id> → 直接匹配凭证
2. accountId 匹配
3. email 匹配（兜底）
```

### 5. 协调检查 — reconcile dupe check

**文件**: `AccountStore+Persistence.swift`（`reconcileProviderAccounts` 方法内）

新账号入库前检查是否重复：

```
Codex (multiWs + credentialId 存在):
  → 用 credentialId 判断重复（不用 accountId/email）
  → 同 email 不同空间的凭证有不同 credentialId → 不合并

其他 Provider:
  → accountId 匹配 → 重复
  → accountId 都存在但不同 → 不重复
  → email 匹配 → 重复
```

### 关键保护: API 失败时不覆盖 accountId

```swift
// 只在 API 成功 (status != .error) 时更新 accountId
if isLiveSuccess, updated.accountId != provider.accountId {
    updated.accountId = provider.accountId
}
```

## 其他 Provider 不受影响

| Provider | 唯一性维度 | 匹配策略 |
|----------|-----------|---------|
| Codex | credentialId（每文件唯一） | credentialId → accountId → email |
| Gemini | email | accountId → email |
| Cursor | email | accountId → email |
| Kiro | email (如有) | accountId → email |

## 场景验证矩阵

| # | 场景 | 凭证去重 | 账号去重 | 匹配 | 协调 |
|---|------|---------|---------|------|------|
| 1 | 多email + 同Team | authFile不同 → 分开 | credentialId不同 → 分开 | credentialId不同 → 各自正确匹配 | credentialId不同 → 不误合并 |
| 2 | 同email + 不同Team | authFile不同 → 分开 | credentialId不同 → 分开 | credentialId不同 → 各自正确匹配 | credentialId不同 → 不误合并 |
| 3 | 个人 + Team（同email） | authFile不同 → 分开 | credentialId不同 → 分开 | credentialId不同 → 各自正确匹配 | credentialId不同 → 不误合并 |
| 4 | API失败后accountId格式变化 | 不涉及 | credentialId不变 → 正确合并 | Step 0 credentialId → 正确匹配 | accountId 不被覆盖 |
| 5 | 同 user-xxx 两个空间 | authFile不同 → 分开 | credentialId不同 → 分开 | Step 0 credentialId 精确命中 → 不互串 | credentialId不同 → 不误合并 |
