# Codex 账号身份链：去重与全链路逻辑

## 核心原则

Codex 与其他 Provider 的本质区别：**同一 email 可属于多个空间（个人/不同 Team），同一 Team 可包含多个 email**。

因此对 Codex，**email 不能作为唯一标识**。所有依赖 email 的匹配/去重路径都必须被禁止或追加维度。

代码中通过 `multiWorkspaceProviders: Set<String> = ["codex"]` 标记此类 Provider，所有涉及 email 的逻辑通过此集合分流。

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
| authFile path | 绝对稳定 | 导入时的文件路径 | 凭证去重的 key |
| providerResultId | 稳定 | `provider:cred:<credentialId>` | 匹配的第二选择 |
| accountId | **不稳定** | API 或 credential | 仅在 credentialId 缺失时辅助 |
| email | **不可靠** | JWT 解码 | **Codex 完全禁止单独使用** |

## 数据来源

```
~/.cli-proxy-api/AuthImports/codex/
├── codex-orgXXX-emailA-161410.json   ← Team-X, emailA
├── codex-orgXXX-emailB-204530.json   ← Team-X, emailB (同 Team 不同 email)
├── codex-orgYYY-emailA-182200.json   ← Team-Y, emailA (同 email 不同 Team)
└── codex-personal-emailA-150000.json ← 个人空间, emailA
```

## 全链路身份检查（7 个环节）

### 1. 凭证去重 — `credentialIdentityKey`

**文件**: `AccountCredentialStore.swift`

对 Codex（multiWorkspaceProviders），进入独立分支：

```
Codex + authFile:
  → codex:authfile:<文件路径>                    ← 每个文件独立

Codex + 非 authFile + accountId 存在:
  → codex:account:<accountId>:handle:<email>     ← 双维度
  → codex:account:<accountId>                    ← 无 email 时

Codex + 非 authFile + accountId 缺失:
  → codex:raw:<credentialUUID>                   ← 不合并，安全兜底

其他 Provider:
  → provider:account:<accountId>
  → provider:handle:<email>
  → provider:authfile:<path>
  → provider:raw:<id>
```

### 2. 账号去重 — `storedAccountIdentityKey`

**文件**: `AccountStore+Persistence.swift`

对 Codex，**credentialId 优先**：

```
codex + credentialId → codex:cred:<credentialId>
codex + email only  → codex:email:<email>        ← 临时账号兜底
codex + 都没有      → codex:stored:<uuid>
```

### 3. 结果→账号匹配 — `bestStoredAccountIndex`

匹配优先级链（每步命中即返回）：

```
Step 0: credentialId 精确匹配
  → 从 provider.id 提取 credentialId → 匹配 stored.credentialId
  → 最精确，同 email 不同空间各自命中

Step 1: accountId 匹配
  → Codex: 追加 email 校验（防止同 user-xxx 匹配错）
  → 其他 Provider: accountId 相同即返回

Step 2: storedAccountMatchesLive 模糊匹配
  → credentialId 构造 expectedId
  → providerResultId 匹配
  → accountId + Codex 追加 email 校验
  → email 兜底（Codex 禁用）

Step 3: allowUnseenCredentialFallback（Codex 禁用）
  → 防止把 Team-A 的结果绑到 Personal 的孤儿上
```

### 4. 凭证→账号关联 — `bestCredentialMatch`

仅在 `credentialId == nil` 时调用：

```
1. providerResultId 包含 :cred:<id> → 直接匹配凭证
2. accountId 匹配
3. email 匹配（兜底，Codex 不受影响因为 credentialId 通常已设置）
```

### 5. 协调 dupe check — `reconcileProviderAccounts`

新账号入库前检查是否重复：

```
Codex + credentialId 存在:
  → 只按 credentialId 判断重复
  → 同 email 不同空间有不同 credentialId → 不合并

Codex + credentialId 缺失（auto-discovered）:
  → 只按 accountId 判断重复（两端都存在且相等）
  → 不走 email 回退

其他 Provider:
  → accountId 匹配 / email 匹配
```

### 6. 自动发现去重 — `removeAutoDiscoveredDuplicates`

```
Codex: 跳过 email 删除逻辑
  → 防止同 email 不同 workspace 的无 credential 账号被误删

其他 Provider:
  → 有 credential 的 email → 删除同 email 的无 credential 账号
```

### 7. 登录去重 — `existingAuthenticatedCredential`

```
Codex: 必须 accountId 双端存在且相等
  → 防止把新 workspace 的凭证误判为"已存在"

其他 Provider:
  → sourceIdentifier → fingerprint → accountId → email
```

### 关键保护: API 失败时不覆盖 accountId

```swift
if provider.status != .error, updated.accountId != provider.accountId {
    updated.accountId = provider.accountId
}
```

### 关键保护: 删除凭证后清理悬空引用

```swift
guard let credential = credentialLookup[credentialId] else {
    account.credentialId = nil
    account.providerResultId = nil
    continue
}
```

## 其他 Provider 不受影响

| Provider | 唯一性维度 | 匹配策略 |
|----------|-----------|---------|
| Codex | credentialId（每文件唯一） | credentialId → accountId+email → providerResultId |
| Gemini | email | accountId → email |
| Cursor | email | accountId → email |
| Kiro | email (如有) | accountId → email |

## Codex 专属禁止项

| 行为 | 状态 | 原因 |
|------|------|------|
| email 单独作为匹配依据 | 禁止 | 同 email 不同 workspace |
| email 单独作为去重依据 | 禁止 | 同上 |
| accountId 单独作为匹配依据 | 禁止 | API 返回相同 user-xxx |
| allowUnseenCredentialFallback | 禁止 | 可能跨 workspace 收养 |
| removeAutoDiscoveredDuplicates 按 email 删除 | 禁止 | 误删不同 workspace |
| API 失败时覆盖 stored accountId | 禁止 | 格式漂移 |

## 场景验证矩阵

| # | 场景 | 凭证去重 | 账号去重 | 匹配 | 协调 | 清理 |
|---|------|---------|---------|------|------|------|
| 1 | 多email同Team | authFile不同 | credentialId不同 | Step 0 各自命中 | credentialId不同 | 不误删 |
| 2 | 同email不同Team | authFile不同 | credentialId不同 | Step 0 各自命中 | credentialId不同 | Codex跳过email删除 |
| 3 | 个人+Team(同email) | authFile不同 | credentialId不同 | Step 0 各自命中 | credentialId不同 | Codex跳过email删除 |
| 4 | API失败accountId变 | 不涉及 | credentialId不变 | Step 0 命中 | accountId不被覆盖 | - |
| 5 | 同user-xxx两空间 | authFile不同 | credentialId不同 | Step 0 精确命中 | credentialId不同 | - |
| 6 | auto-discovered同email | - | email兜底 | Step 1 accountId+email | accountId匹配(不走email) | Codex跳过 |
| 7 | 删除凭证后 | - | credentialId清空 | 不再悬空引用 | - | 孤儿清理 |
| 8 | 新workspace导入 | raw:uuid不合并 | - | - | accountId双端匹配 | - |
