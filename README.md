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
  <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-22c55e?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square">
</p>

<p align="center">
  <img src="docs/images/dashboard-overview.png" alt="AIUsage dashboard" width="100%">
</p>

AIUsage is a macOS app for monitoring AI subscription quotas, account status, refresh windows, and local usage cost.

## Features

| Feature | Description |
| --- | --- |
| `Provider dashboard` | View quota status for Codex, Copilot, Cursor, Antigravity, Kiro, Warp, Gemini CLI, Amp, Droid, and local Claude Code spend in one app |
| `Multi-account management` | Keep multiple accounts under one provider and refresh them independently |
| `Refresh scopes` | Refresh a single card, all accounts for one provider, or the full app |
| `Cost tracking` | View hourly and daily cost and token trends from local usage data |
| `Source management` | Add, hide, restore, pause, or remove monitored sources |
| `Credential handling` | Store managed credentials in macOS Keychain and keep file-based imports under app-managed storage |
| `Backend modes` | Support local mode and remote backend mode |

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
