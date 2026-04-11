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
  <img alt="版本" src="https://img.shields.io/badge/version-0.2.0-22c55e?style=flat-square">
  <img alt="许可证" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square">
</p>

<p align="center">
  <img src="docs/images/dashboard-overview.png" alt="AIUsage 仪表盘预览" width="100%">
</p>

AIUsage 是一个 macOS 应用，用于查看 AI 订阅额度、账号状态、刷新窗口，以及本地 usage 成本。

## 功能

| 功能 | 说明 |
| --- | --- |
| `服务商看板` | 在一个应用里查看 Codex、Copilot、Cursor、Antigravity、Kiro、Warp、Gemini CLI、Amp、Droid 和本地 Claude Code 花费 |
| `多账号管理` | 同一个服务商下保留多个账号，并支持独立刷新 |
| `一键切换账号` | 支持 Codex CLI 和 Gemini CLI 的活跃账号切换 — 认证文件自动转换并替换，无需手动操作 |
| `Codex 双窗口额度` | Codex 卡片同时展示 5 小时剩余和 7 天剩余两条进度条，每条配有独立的重置倒计时 |
| `刷新层级` | 支持单卡刷新、单服务商刷新、全局刷新 |
| `费用追踪` | 查看小时级、天级的费用和 token 趋势 |
| `来源管理` | 支持添加、隐藏、恢复、暂停、移除监控来源 |
| `凭证管理` | 受管凭证保存在 macOS Keychain，文件型登录会复制到应用托管目录 |
| `后端模式` | 支持本地模式和远程后端模式 |

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
      <img src="docs/images/cost-tracking.png" alt="费用追踪图表">
    </td>
    <td width="50%">
      <img src="docs/images/codex-account-detail.png" alt="账号详情视图">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>费用与 Token 趋势</strong></td>
    <td align="center"><strong>账号详情页</strong></td>
  </tr>
</table>

## 当前支持

### 订阅 / 配额类来源

`Codex` · `Copilot` · `Cursor` · `Antigravity` · `Kiro` · `Warp` · `Gemini CLI` · `Amp` · `Droid`

### 费用追踪

`Claude Code` 本地花费账本

## 安装方式

直接从 `Releases` 页面下载最新 macOS 安装包。

提供的发布产物：

- `.dmg`
- `.zip`

## 文档

- [架构总览](docs/ARCHITECTURE.md)

## 致谢

灵感参考自 [`CodexBar`](https://github.com/steipete/CodexBar) 与 [`Quotio`](https://github.com/nguyenphutrong/quotio)。

## 友链

- [Linux.do 社区](https://linux.do)

## 许可证

本项目使用 [Apache License 2.0](LICENSE) 许可证。
