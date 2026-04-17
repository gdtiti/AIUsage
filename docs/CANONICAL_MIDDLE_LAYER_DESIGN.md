# Canonical Middle Layer Design

## 目的

这份文档定义 Claude API 与 OpenAI API 之间的统一中间层模型，目标是把当前多条“两两协议直连”转换链收口为：

1. Claude API -> Canonical
2. OpenAI `chat/completions` -> Canonical
3. OpenAI `responses` -> Canonical
4. Canonical -> Claude API
5. Canonical -> OpenAI `chat/completions`
6. Canonical -> OpenAI `responses`

这样后续新增字段、工具、文件能力或流式事件时，只需要补：

- 协议到 Canonical 的映射
- Canonical 到协议的映射

而不是继续维护多条互相耦合的协议直连转换。

---

## 设计原则

### 1. 先保 correctness，再追求完全无损

Canonical v1 的第一目标不是“所有供应商字段一比一复制”，而是：

- 不静默丢掉关键语义
- 不把截断/拒绝/暂停错误地伪装成正常完成
- 不把工具调用、文件、thinking/reasoning 的生命周期打乱

### 2. 共享语义进入核心模型

进入核心模型的字段必须满足至少一个条件：

- Claude 与 OpenAI 都有对应语义
- 一侧有强语义，另一侧虽不能无损表达，但必须显式降级
- 它是端到端正确性所必需的控制位

### 3. 供应商特有能力进入扩展槽

像这些字段先不强行“抽象过头”，而是进入扩展位：

- Claude `cache_control`
- Claude `citations`
- Claude `redacted_thinking`
- OpenAI `encrypted_content`
- OpenAI hosted tool 细分 output item
- 未来新增的 provider-specific flags

### 4. 降级必须显式

凡是不能无损桥接的字段，必须通过以下三种方式之一表达：

- 显式 raw extension 保留
- 显式 lossy note 记录
- 显式转换成用户可见的降级文本

不能继续走“静默忽略”。

---

## Canonical v1 范围

### 顶层请求

```swift
CanonicalRequest
- modelHint: String
- system: [CanonicalContentPart]
- items: [CanonicalConversationItem]
- tools: [CanonicalToolDefinition]
- toolConfig: CanonicalToolConfig?
- generationConfig: CanonicalGenerationConfig
- metadata: [String: CanonicalScalar]
- rawExtensions: [CanonicalVendorExtension]
```

### 顶层响应

```swift
CanonicalResponse
- id: String?
- model: String?
- items: [CanonicalConversationItem]
- stop: CanonicalStop
- usage: CanonicalUsage?
- rawExtensions: [CanonicalVendorExtension]
```

### 流式事件

```swift
CanonicalStreamEvent
- messageStarted
- contentPartStarted
- contentPartDelta
- contentPartStopped
- messageDelta
- messageStopped
- error
```

---

## Canonical 核心实体

### 1. `CanonicalConversationItem`

用于统一承载多协议里的“历史项 / 输出项 / 工具回合项”。

```swift
enum CanonicalConversationItem {
  case message(CanonicalMessage)
  case toolCall(CanonicalToolCall)
  case toolResult(CanonicalToolResult)
  case reasoning(CanonicalReasoningItem)
  case compaction(CanonicalCompactionItem)
  case hostedToolEvent(CanonicalHostedToolEvent)
}
```

### 2. `CanonicalMessage`

```swift
CanonicalMessage
- role: system | user | assistant | tool
- phase: commentary | final_answer | nil
- parts: [CanonicalContentPart]
- name: String?
- metadata: [String: CanonicalScalar]
- rawExtensions: [CanonicalVendorExtension]
```

说明：

- Claude `system` 先单独进入 `CanonicalRequest.system`，不混入普通 message。
- OpenAI `assistant.phase` 可直接进入 `phase`。
- `tool` role message 在 Canonical 中优先重写成 `toolResult`，仅在需要保留历史形态时才维持 `message(role: tool)`。

### 3. `CanonicalContentPart`

```swift
enum CanonicalContentPart {
  case text(CanonicalTextPart)
  case image(CanonicalImagePart)
  case document(CanonicalDocumentPart)
  case fileRef(CanonicalFileReference)
  case reasoningText(CanonicalReasoningTextPart)
  case refusal(CanonicalRefusalPart)
  case unknown(CanonicalUnknownPart)
}
```

其中：

```swift
CanonicalTextPart
- text: String

CanonicalImagePart
- source: base64 | url | file_id
- mediaType: String?
- detail: String?

CanonicalDocumentPart
- source: inline_text | content_parts | url | base64 | file_id | unknown
- title: String?
- context: String?
- citations: CanonicalOpaqueValue?

CanonicalFileReference
- fileID: String?
- filename: String?
- mimeType: String?
- downloadable: Bool?
```

说明：

- Claude `document` 不再直接硬映射成 OpenAI `file`，而是先进入 `CanonicalDocumentPart`。
- OpenAI `input_file` / chat `type: "file"` 可以落成 `fileRef`，必要时再提升成 `document(file_id)`。
- `reasoningText` 与 `refusal` 保持独立 part，避免它们在普通 text 中被冲掉。

### 4. `CanonicalToolDefinition`

```swift
CanonicalToolDefinition
- kind: function | hosted | custom | unknown
- name: String?
- description: String?
- inputSchema: CanonicalJSONSchema?
- execution: client | server | hosted | unknown
- vendorType: String?
- flags:
  - eagerInputStreaming: Bool?
  - strict: Bool?
- rawExtensions: [CanonicalVendorExtension]
```

说明：

- Claude 用户定义 tool 和 OpenAI function tool 都进入 `kind: function`。
- OpenAI `file_search` / `web_search` / `computer_use` / `code_interpreter` 等进入 `kind: hosted`。
- `eager_input_streaming` 在 Canonical 中单独保留，不再依赖 Claude-only struct。

### 5. `CanonicalToolConfig`

```swift
CanonicalToolConfig
- choice: auto | required | none | specific(name) | allowed(names) | unknown
- parallelCallsAllowed: Bool?
```

说明：

- Claude `disable_parallel_tool_use` 在进入 Canonical 时转成 `parallelCallsAllowed = false`
- OpenAI `parallel_tool_calls = true/false` 直接映射

### 6. `CanonicalToolCall`

```swift
CanonicalToolCall
- id: String
- name: String
- inputJSON: String
- status: in_progress | completed | incomplete | unknown
- partial: Bool
- rawExtensions: [CanonicalVendorExtension]
```

说明：

- `inputJSON` 统一以字符串存储，避免在 fine-grained streaming / max_tokens 截断时被迫提前做 JSON 验证。
- `partial` 用于标记这是否是未完成 JSON 或中途截断。

### 7. `CanonicalToolResult`

```swift
CanonicalToolResult
- toolCallID: String
- isError: Bool?
- parts: [CanonicalContentPart]
- rawTextFallback: String?
- rawExtensions: [CanonicalVendorExtension]
```

说明：

- Claude `tool_result.content` / `contentBlocks`
- OpenAI `function_call_output.output`

都统一进入这里。

### 8. `CanonicalReasoningItem`

```swift
CanonicalReasoningItem
- summaryText: String?
- fullText: String?
- encryptedContent: String?
- signature: String?
- redacted: Bool?
- rawExtensions: [CanonicalVendorExtension]
```

说明：

- Claude `thinking` / `signature_delta` / `redacted_thinking`
- OpenAI `reasoning.summary` / `content` / `encrypted_content`

都应落到这一层。

### 9. `CanonicalHostedToolEvent`

```swift
CanonicalHostedToolEvent
- vendorType: String
- callID: String?
- status: in_progress | completed | incomplete | failed | unknown
- payload: CanonicalOpaqueValue?
```

说明：

- 这是 v1 保持 OpenAI hosted tools 可表达性的关键。
- Canonical v1 不强行抽象 `file_search` / `computer_use` / `shell` / `mcp` 的全部细节，先保事件身份、状态和原始 payload。

### 10. `CanonicalStop`

```swift
CanonicalStop
- reason: end_turn | tool_use | max_tokens | pause_turn | refusal | model_context_window_exceeded | error | unknown
- sequence: String?
```

说明：

- 这是 correctness 高优先级字段，必须从所有协议中显式保留。

### 11. `CanonicalUsage`

```swift
CanonicalUsage
- inputTokens: Int?
- outputTokens: Int?
- totalTokens: Int?
- cacheCreationInputTokens: Int?
- cacheReadInputTokens: Int?
- reasoningTokens: Int?
```

---

## 第一版字段映射表

### A. Claude `messages` -> Canonical

| Claude | Canonical | 说明 |
|---|---|---|
| `system` string / blocks | `CanonicalRequest.system` | blocks 优先保留为 parts |
| `message.role` | `CanonicalMessage.role` | `user/assistant` 直接映射 |
| `text` | `text` part | 无损 |
| `image.source.base64` | `image` part | 无损 |
| `document.source.file_id` | `document(file_id)` / `fileRef` | 无损 |
| `document.source.text/content` | `document(inline_text/content_parts)` | 基本无损 |
| `document.source.url/base64` | `document(url/base64)` | Canonical 保留，后续出协议时再决定降级 |
| `tool_use` | `CanonicalToolCall` | `input` 先序列化成 JSON string |
| `tool_result` | `CanonicalToolResult` | 保留 `is_error` |
| `thinking` | `CanonicalReasoningItem.fullText` | signature 单独落 extension |
| `redacted_thinking` | `CanonicalReasoningItem.redacted = true` | |
| `tool_choice` | `CanonicalToolConfig.choice` | |
| `disable_parallel_tool_use` | `parallelCallsAllowed = false` | |

### B. OpenAI `chat/completions` -> Canonical

| OpenAI chat | Canonical | 说明 |
|---|---|---|
| `messages[].role` | `CanonicalMessage.role` | |
| string `content` | `text` part | |
| parts `text/image_url/file` | `text/image/fileRef` | |
| `tool_calls[]` | `CanonicalToolCall` | arguments 维持 string |
| `role: tool` + `tool_call_id` | `CanonicalToolResult` | |
| `tools[]` | `CanonicalToolDefinition(kind: function)` | |
| `tool_choice` | `CanonicalToolConfig.choice` | |
| `parallel_tool_calls` | `parallelCallsAllowed` | |
| `finish_reason` | `CanonicalStop.reason` | `tool_calls -> tool_use`, `length -> max_tokens` |

### C. OpenAI `responses` -> Canonical

| OpenAI responses | Canonical | 说明 |
|---|---|---|
| `input[].message` | `CanonicalMessage` | |
| `input_text/input_image/input_file` | `text/image/fileRef` | |
| `function_call` | `CanonicalToolCall` | |
| `function_call_output` | `CanonicalToolResult` | |
| `reasoning` | `CanonicalReasoningItem` | |
| `compaction` | `CanonicalCompactionItem` | v1 raw extension 即可 |
| hosted tool items | `CanonicalHostedToolEvent` | 保留 `vendorType/status/payload` |
| `assistant.phase` | `CanonicalMessage.phase` | |
| `tool_choice` / `allowed_tools` | `CanonicalToolConfig.choice` | |
| `parallel_tool_calls` | `parallelCallsAllowed` | |
| `status: incomplete` | `CanonicalStop.max_tokens` 或 `pause_turn` | 需先判断是否 hosted tool pending |

---

## 显式降级策略

### 必须显式降级的情况

1. Claude `document.source.url/base64`
   - 若目标协议不能表达，保留在 Canonical 中，并在出协议时：
   - 优先转目标支持的 file/url 形态
   - 不支持时转显式文本说明

2. OpenAI hosted tools
   - Claude 当前没有完全对等的 hosted tool schema
   - Canonical 保留 `CanonicalHostedToolEvent`
   - 出 Claude 时优先映射 stop reason / partial output / tool lifecycle
   - 不能表达的细节进入 raw extension

3. Reasoning encrypted payload
   - 先保留 `encryptedContent`
   - 若目标协议没有等价字段，不应丢弃；应保留在 raw extension

4. Citations / cache control / vendor metadata
   - 不进入核心共享字段
   - 必须进入 `rawExtensions`

---

## v1 不做的事

### 1. 不强行统一所有 hosted tool payload

`file_search`、`computer_use`、`shell`、`mcp` 的 payload 结构差异太大，v1 只统一它们的：

- 身份
- 状态
- 原始 payload

### 2. 不在 Canonical 层强制做 JSON 解析

工具输入和输出优先保留 string / raw content，避免：

- fine-grained streaming partial JSON 被提前解析
- max_tokens 截断后的无效 JSON 被误清洗

### 3. 不在 v1 引入 provider-specific execution policy

例如：

- 重试策略
- store / stateless continuation 细分策略
- provider-specific timeout / region 开关

这些先留在 runtime / extension 层。

---

## 第一版落地顺序

### [x] Step C1-1

`Canonical*` value models 已实现于 `QuotaBackend/Sources/QuotaBackend/ClaudeProxy/Canonical/`。

### [x] Step C1-2

已实现非流式映射：

- Claude -> Canonical (`CanonicalClaudeBuilders`)
- OpenAI `chat/completions` -> Canonical (`CanonicalOpenAIBuilders`)
- OpenAI `responses` -> Canonical (`CanonicalOpenAIResponsesBuilders`)

### [x] Step C1-3

已实现反向映射：

- Canonical -> Claude
- Canonical -> OpenAI `chat/completions`
- Canonical -> OpenAI `responses`

### [x] Step C1-4

Streaming event 已抽成 Canonical 层，通过 `CanonicalClaudeStreamBuilder` 和 `CanonicalOpenAIUpstreamStreamMapper` 替换直接 SSE 拼接。

---

## 当前状态 (v0.4.20)

- Canonical v1 全部四步已落地并投入生产使用。
- 测试覆盖：12 个 Canonical 单测 + 33 个 Converter 单测 + 29 个集成测试。
- 后续方向：hosted tool、MCP 协议扩展等新能力在 Canonical 层追加字段即可。
