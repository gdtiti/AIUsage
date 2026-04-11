# AIUsage

<p align="center">
  <img src="docs/images/app-icon.png" alt="AIUsage icon" width="120">
</p>

<p align="center">
  <strong>A local-first macOS dashboard for AI quotas, multi-account monitoring, and spend visibility.</strong>
</p>

<p align="center">
  <a href="README.zh-CN.md">中文说明</a> · <strong>English</strong>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native%20App-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="Version" src="https://img.shields.io/badge/version-0.2.6-22c55e?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square">
</p>

<p align="center">
  <img src="docs/images/dashboard-overview.png" alt="AIUsage dashboard" width="100%">
</p>

AIUsage is a macOS app for monitoring AI subscription quotas, account status, refresh windows, and local usage cost.

## Features

| Feature | Description |
| --- | --- |
| `10+ AI providers` | Codex, Copilot, Cursor, Antigravity, Kiro, Warp, Gemini CLI, Amp, Droid, and Claude Code — all in one dashboard |
| `Multi-account` | Multiple accounts per provider with independent refresh and one-click CLI switching (Codex, Gemini) |
| `Codex dual quota` | 5-hour and weekly remaining shown side by side, each with its own reset countdown |
| `Cost tracking` | Hourly and daily spend and token trends from local usage data |
| `Menu bar` | Mini progress rings, cost data, active account badges, and account switching without opening the main window |
| `Credential vault` | Managed credentials stored in macOS Keychain; file-based imports kept under app-managed storage |

## Preview

<table>
  <tr>
    <td width="50%">
      <img src="docs/images/dashboard-overview.png" alt="Overview dashboard">
    </td>
    <td width="50%">
      <img src="docs/images/provider-monitoring.png" alt="Provider and account monitoring">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Overview dashboard</strong></td>
    <td align="center"><strong>Provider and multi-account monitoring</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/cost-tracking.png" alt="Cost tracking charts">
    </td>
    <td width="50%">
      <img src="docs/images/codex-account-detail.png" alt="Account detail view">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Spend and token trends</strong></td>
    <td align="center"><strong>Detailed account view</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/menu_bar.png" alt="Menu bar quick view">
    </td>
    <td width="50%"></td>
  </tr>
  <tr>
    <td align="center"><strong>Menu bar quick view</strong></td>
    <td></td>
  </tr>
</table>

## Supported Sources

### Subscription and quota providers

`Codex` · `Copilot` · `Cursor` · `Antigravity` · `Kiro` · `Warp` · `Gemini CLI` · `Amp` · `Droid`

### Cost tracking

`Claude Code` local spend ledger

## Installation

Download the latest macOS package from the `Releases` page.

Available release assets:

- `.dmg`
- `.zip`

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)

## Acknowledgements

Inspired by [`CodexBar`](https://github.com/steipete/CodexBar) and [`Quotio`](https://github.com/nguyenphutrong/quotio).

## Friendly Links

- [Linux.do Community](https://linux.do)

## License

This project is licensed under the [Apache License 2.0](LICENSE).
