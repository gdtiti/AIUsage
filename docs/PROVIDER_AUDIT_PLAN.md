# Provider 全量审查修复计划

## 🔴 真实 Bug

- [x] 1. **Copilot 除零** — `CopilotProvider.swift` monthly_quotas 百分比 `lChat / mChat * 100`，mChat=0 时 NaN
- [x] 2. **Cursor 百分比逻辑** — `CursorProvider.swift` 只有 autoPercent 或 apiPercent 其一时，主窗口用量被算成 0
- [x] 3. **Claude 去重计数器** — `ClaudeProvider.swift` `duplicatesRemoved` 恒为 0，`scanFiles` 去重但未递增
- [x] 4. **Antigravity 401 不重试** — 无 401→refresh→retry 路径
- [x] 5. **Antigravity 写盘无 .atomic** — `persistRefreshedToken` 断电可损坏
- [x] 6. **Kiro 跨账号覆写 IDE 文件** — `syncToKiroIDEAuthFile` 未校验 profileArn，B 刷新后覆盖 A
- [x] 7. **Cursor sqlite 空转** — `querySQLite` 前半段查询结果未被使用，第二次 hexTask 覆盖

## 🟡 潜在隐患

- [x] 8. **Kiro expires_at 毫秒/秒** — 毫秒时间戳导致 needsRefresh 恒 false
- [x] 9. **Kiro 刷新静默失败** — `try?` 吞错误，由下游 401 重试兜底（设计合理）
- [x] 10. **Antigravity 刷新静默失败** — 同上，由 401 catch 重试兜底（设计合理）
- [x] 11. **Antigravity Codable 严格解析** — `accessToken` 已 non-optional，已足够严格
- [x] 12. **Gemini 403 当成功** — 配额请求仅 401 映射为 not_logged_in，已加 403
- [x] 13. **Gemini usageAccountId 未设** — 自动扫描 id 恒为 `gemini:auto:default`，已设为 projectId
- [x] 14. **Cursor/Amp/Copilot authMethod 不校验** — 已添加 guard 校验

## 🔵 一致性改进

- [x] 15. **Gemini resync email 比对** — 换 Google 账号后 resync 被拒，已移除 email 守卫
- [x] 16. **Droid wos-session** — `bearerToken(fromCookieHeader:)` 遗漏 wos-session cookie 名
- [x] 17. **Droid Base64 URL-safe** — `loadFactoryKeyFile` / `loadFactoryKeyringKey` / `decryptFactoryCredentials` 未做 URL-safe 转换
- [x] 18. **Droid refreshStoredSession cookie 丢失** — 刷新后 cookieHeader 被置 nil，已保留原始 cookie
- [x] 19. **Cursor/Amp sqlite 复制竞争** — 未复制 WAL/SHM 文件，已添加
- [x] 20. **Claude JSONL 全量加载** — 改为 FileHandle 逐行流式读取
