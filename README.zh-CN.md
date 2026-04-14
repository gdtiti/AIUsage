# AIUsage

<p align="center">
  <img src="docs/images/app-icon.png" alt="AIUsage 图标" width="120">
</p>

<p align="center">
  <strong>一个本地优先的 macOS AI 用量看板，用来统一查看额度、账号状态和花费趋势。</strong>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>中文说明</strong>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native%20App-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="版本" src="https://img.shields.io/badge/version-0.3.0-22c55e?style=flat-square">
  <img alt="许可证" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square">
</p>

<p align="center">
  <img src="docs/images/dashboard-overview.png" alt="AIUsage 仪表盘预览" width="100%">
</p>

AIUsage 是一个 macOS 应用，用于查看 AI 订阅额度、账号状态、刷新窗口，以及本地 usage 成本。

## 功能

| 功能 | 说明 |
| --- | --- |
| `10+ AI 服务商` | Codex、Copilot、Cursor、Antigravity、Kiro、Warp、Gemini CLI、Amp、Droid、Claude Code — 全部集中在一个看板 |
| `多账号管理` | 同一服务商下多个账号独立刷新，支持 Codex / Gemini CLI 一键切换活跃账号 |
| `Codex 双窗口额度` | 5 小时剩余 + 7 天剩余并排展示，各有独立重置倒计时 |
| `Claude Code 统计` | 按模型拆分费用与 Token（input/output/cache），多模型对比曲线，按时段（今日/本周/本月/全部）分析 |
| `Claude Code 代理` | 协议转换层，支持 OpenAI 转换和 Anthropic 透传两种模式，含模型定价、用量日志和代理统计面板 |
| `菜单栏快览` | 迷你进度环 + 费用 + 活跃账号徽标 + 一键切换，无需打开主窗口 |
| `凭证保险库` | 受管凭证存入 macOS Keychain，文件型凭证由应用托管 |

## 界面预览

<table>
  <tr>
    <td width="50%">
      <img src="docs/images/dashboard-overview.png" alt="仪表盘总览">
    </td>
    <td width="50%">
      <img src="docs/images/provider-monitoring.png" alt="服务商与多账号监控">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>仪表盘总览</strong></td>
    <td align="center"><strong>服务商与多账号监控</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/claude-code-stats.png" alt="Claude Code 统计看板">
    </td>
    <td width="50%">
      <img src="docs/images/codex-account-detail.png" alt="账号详情视图">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Claude Code 统计 — 模型级分析</strong></td>
    <td align="center"><strong>账号详情页</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/Claude-Code-Proxy-1.png" alt="Claude Code 代理节点管理">
    </td>
    <td width="50%">
      <img src="docs/images/Claude-Code-Proxy-2.png" alt="Claude Code 代理配置">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>代理节点管理</strong></td>
    <td align="center"><strong>代理节点配置</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/proxy-stats.png" alt="代理统计面板">
    </td>
    <td width="50%">
      <img src="docs/images/menu_bar.png" alt="菜单栏快览">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>代理统计 — 模型级分析</strong></td>
    <td align="center"><strong>菜单栏快览</strong></td>
  </tr>
</table>

## 当前支持

### 订阅 / 配额类来源

`Codex` · `Copilot` · `Cursor` · `Antigravity` · `Kiro` · `Warp` · `Gemini CLI` · `Amp` · `Droid`

### Claude Code 统计

`Claude Code` 本地花费账本，支持模型级费用拆分、input/output Token 细分、多时段分析

## 安装方式

直接从 `Releases` 页面下载最新 macOS 安装包。

提供的发布产物：

- `.dmg`
- `.zip`

## Claude Code Proxy

AIUsage 内置 Claude Code 代理 — 所有配置通过 UI 完成，无需手动设置环境变量。

### 快速开始

1. 打开 AIUsage → **Claude Code 代理** 页面
2. 点击 **新建节点** → 选择 **OpenAI Proxy** 或 **Anthropic Direct**
3. 填入上游 API Key、地址、模型映射
4. 点击 **保存** → **激活** — 完成！`~/.claude/settings.json` 自动更新

### 代理模式

| 模式 | 说明 |
|------|------|
| **OpenAI 代理** | 将 Claude API 翻译为 OpenAI 兼容格式（DeepSeek、GPT、Azure、Ollama 等） |
| **Anthropic 透传** | 请求原样转发到 Anthropic API，记录输入/输出/缓存 Token |

### 功能特性

- ✅ 完整的 Claude Messages API 支持（`/v1/messages`），含流式 SSE
- ✅ Tool use / 函数调用 / 图片支持
- ✅ **代理统计面板** — 按模型的费用/Token 趋势曲线、分布图
- ✅ 按模型配置价格（USD/CNY），支持子串模型匹配
- ✅ 多节点管理，一键激活切换
- ✅ 客户端 API Key 认证
- ✅ 可配置日志保留天数（7–365 天）
- ✅ 仪表盘集成代理统计概览

## 致谢

灵感参考自 [`CodexBar`](https://github.com/steipete/CodexBar) 与 [`Quotio`](https://github.com/nguyenphutrong/quotio)。

## 友链

- [Linux.do 社区](https://linux.do)

## 许可证

本项目使用 [Apache License 2.0](LICENSE) 许可证。
