# Codex 账号身份链：去重与全链路逻辑

## 核心原则

Codex 与其他 Provider 的本质区别：**同一 email 可属于多个空间（个人/不同 Team），同一 Team 可包含多个 email**。

因此 Codex 的唯一性由 **email + workspace（空间 ID）** 双维度决定，而其他 Provider 仅需 email 单维度。

代码中通过 `multiWorkspaceProviders: Set<String> = ["codex"]` 标记此类 Provider。

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

## 全链路身份检查（4 个环节）

### 1. 凭证去重 — `credentialIdentityKey`

**文件**: `AccountCredentialStore.swift`

对 Codex（multiWorkspaceProviders），**authFile 路径优先于 accountId**：

```
优先级:
1. codex + authFile → codex:authfile:<文件路径>   ← Codex 走这里
2. accountId       → provider:account:<id>
3. email/handle    → provider:handle:<email>
4. authFile        → provider:authfile:<path>
5. credential id   → provider:raw:<id>
```

| 场景 | 文件A | 文件B | Identity Key | 结果 |
|------|-------|-------|-------------|------|
| 同Team不同email | pathA | pathB | 不同路径 | 不合并 |
| 同email不同Team | pathA | pathB | 不同路径 | 不合并 |
| 个人+Team | pathA | pathB | 不同路径 | 不合并 |

### 2. 账号去重 — `storedAccountIdentityKey`

**文件**: `AccountStore+Persistence.swift`（两处：`AccountRegistryRefreshSnapshot` 和 `AccountStore` 扩展）

对 Codex，identity key = `accountId + email` 组合：

```
codex + normalizedAccountId 存在:
  → codex:account:<accountId>:email:<email>

其他 Provider + normalizedAccountId 存在:
  → provider:account:<accountId>
```

| 场景 | accountId | email | Identity Key | 结果 |
|------|-----------|-------|-------------|------|
| 同Team不同email | org-X | emailA vs emailB | 不同 | 不合并 |
| 同email不同Team | org-X vs org-Y | emailA | 不同 | 不合并 |
| 个人+Team | user-xxx vs org-Y | emailA | 不同 | 不合并 |

### 3. 存储匹配 — `storedAccountMatchesLive`

**文件**: `AccountStore+Persistence.swift` 和 `AccountStore+Matching.swift`

当 accountId 匹配后，对 Codex 追加 email 校验：

```swift
if storedAccountId == liveAccountId {
    if isMultiWorkspace && 双方都有 email {
        return stored.email == live.email  // 追加校验
    }
    return true
}
```

### 4. 协调检查 — reconcile dupe check

**文件**: `AccountStore+Persistence.swift`（`reconcileProviderAccounts` 方法内）

新账号入库前检查是否重复，对 Codex 同样双维度：

```swift
if accountId 匹配 {
    if isMultiWs { return email 也匹配 }
    return true
}
```

## 其他 Provider 不受影响

| Provider | 唯一性维度 | 逻辑 |
|----------|-----------|------|
| Codex | email + workspace | 双维度 |
| Gemini | email | 单维度 |
| Cursor | email | 单维度 |
| Kiro | email (如有) | 单维度 |

## 场景验证矩阵

| # | 场景 | 凭证去重 | 账号去重 | 匹配 | 协调 |
|---|------|---------|---------|------|------|
| 1 | 多email + 同Team | authFile路径不同 → 分开 | wsUUID相同 + email不同 → 分开 | email不同 → 不误匹配 | email不同 → 不误合并 |
| 2 | 同email + 不同Team | authFile路径不同 → 分开 | wsUUID不同 → 分开 | accountId不同 → 不误匹配 | accountId不同 → 不误合并 |
| 3 | 个人 + Team（同email） | authFile路径不同 → 分开 | accountId不同(user vs org) → 分开 | accountId不同 → 不误匹配 | accountId不同 → 不误合并 |
