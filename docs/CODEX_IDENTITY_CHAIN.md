# Codex 账号身份链：去重与全链路逻辑

## 核心原则

Codex 与其他 Provider 的本质区别：**同一 email 可属于多个空间（个人/不同 Team），同一 Team 可包含多个 email**。

因此对 Codex，**email 不能作为唯一标识**。所有依赖 email 的匹配/去重路径都必须被禁止或追加维度。

代码中通过 `AccountIdentityPolicy.isMultiWorkspace(_:)` 判断（当前包含 `"codex"`），所有涉及 email 的逻辑通过此函数分流。

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
| authFile path | 绝对稳定 | 导入时的文件路径（归一化后） | 凭证去重的 key |
| providerResultId | 稳定 | `provider:cred:<credentialId>` | 匹配的第二选择 |
| accountId + email | 组合稳定 | API + JWT | credentialId 缺失时的去重兜底 |
| accountId | **不稳定** | API 或 credential | 仅在 credentialId 缺失时辅助 |
| email | **不可靠** | JWT 解码 | **Codex 禁止单独使用** |

## 统一策略实现 — `AccountIdentityPolicy`

**文件**: `AccountStore+Persistence.swift`

所有核心逻辑统一在 `AccountIdentityPolicy` 结构体中，`AccountRegistryRefreshSnapshot` 和 `AccountStore` 扩展共用，消除双份代码漂移：

- `identityKey(for:)` — 账号去重 key
- `matchesLive(_:provider:)` — 存储→活跃匹配
- `bestStoredAccountIndex(for:...)` — 结果→存储匹配链
- `bestCredentialMatch(for:candidates:)` — 凭证→账号关联
- `matchingStoredAccountIndices(...)` — 删除时的安全匹配

## 全链路身份检查

### 1. 凭证去重 — `credentialIdentityKey`

**文件**: `AccountCredentialStore.swift`

对 Codex：authFile 路径归一化（`standardizedFileURL` + `resolvingSymlinksInPath`）优先。
非 authFile 的 Codex 凭证用 `accountId:handle` 组合，无 accountId 时降级为 `raw:uuid`。

### 2. 账号去重 — `AccountIdentityPolicy.identityKey`

对 Codex：

```
credentialId 存在 → codex:cred:<credentialId>          ← 绝对稳定
credentialId 缺失 + accountId + email 存在 → codex:account:<id>:email:<email>  ← 组合维度
以上都缺失 → codex:stored:<uuid>                       ← 不合并
```

### 3. 结果→账号匹配 — `bestStoredAccountIndex`

```
Step 0: credentialId 精确匹配（最优先）
Step 1: accountId 匹配（Codex 追加 email 校验）
Step 2: matchesLive 模糊匹配
  → credentialId → providerResultId → accountId + Codex email 守卫
  → email 兜底（Codex 禁用）
Step 3: allowUnseenCredentialFallback（Codex 禁用）
```

### 4. 凭证→账号关联 — `bestCredentialMatch`

Codex 多 workspace 场景：
- accountId 匹配时追加 email 守卫（同 user-xxx 的 Plus/Team 通过 email 区分）
- accountId 不能精确锚定时，不走 email 回退，直接返回 nil

### 5. 协调 dupe check

Codex + credentialId 存在 → 按 credentialId 判重
Codex + credentialId 缺失 → 按 accountId 判重（不走 email 回退）

### 6. 自动发现去重 — `removeAutoDiscoveredDuplicates`

Codex 跳过 email 删除逻辑。

### 7. 登录去重 — `existingAuthenticatedCredential`

Codex 三层防御（由上至下依次判断）：

1. accountId 匹配时 → **追加 sourceIdentifier 匹配**（authFile 路径或会话指纹），防止同 user-xxx 的 Plus/Team 互相覆盖
2. accountId 不一致 → 直接 return false
3. accountId 一侧缺失（multi-ws） → 直接 return false，不走 email 回退

### 关键保护

- API 失败时不覆盖 stored accountId
- 删除凭证后清理悬空 credentialId 引用
- 菜单栏固定项自动清理 stale IDs

## Codex 专属禁止项

| 行为 | 状态 | 原因 |
|------|------|------|
| email 单独作为匹配/去重依据 | 禁止 | 同 email 不同 workspace |
| accountId 单独作为匹配依据 | 禁止 | API 返回相同 user-xxx（Plus/Team 共享） |
| allowUnseenCredentialFallback | 禁止 | 可能跨 workspace 收养 |
| removeAutoDiscoveredDuplicates 按 email 删除 | 禁止 | 误删不同 workspace |
| API 失败时覆盖 stored accountId | 禁止 | 格式漂移 |

## 场景验证矩阵

| # | 场景 | 凭证去重 | 账号去重 | 匹配 | 协调 |
|---|------|---------|---------|------|------|
| 1 | 多email同Team | authFile不同 | credentialId不同 | Step 0各自命中 | credentialId不同 |
| 2 | 同email不同Team | authFile不同 | credentialId不同 | Step 0各自命中 | credentialId不同 |
| 3 | 个人+Team(同email) | authFile不同 | credentialId不同 | Step 0各自命中 | credentialId不同 |
| 4 | API失败accountId变 | 不涉及 | credentialId不变 | Step 0命中 | accountId不被覆盖 |
| 5 | 同user-xxx两空间(Plus+Team) | authFile不同 | credentialId不同 | Step 0精确命中 | credentialId不同 |
| 5b | 同user-xxx先Plus后Team登录 | sourceIdentifier不同→不覆盖 | credentialId各自创建 | existingAuthenticatedCredential区分 | 各自独立 |
| 6 | credentialId缺失 | - | accountId+email组合 | Step 1+email守卫 | accountId匹配 |
| 7 | 删除凭证后 | - | credentialId清空 | 不悬空引用 | 孤儿清理 |
