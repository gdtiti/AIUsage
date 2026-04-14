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
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.0-22c55e?style=flat-square">
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
| `Claude Code stats` | Per-model cost and token breakdown, multi-model comparison charts, and time-period analysis (today / week / month / overall) |
| `Claude Code proxy` | Protocol translation layer with OpenAI-convert and Anthropic-passthrough modes, per-model pricing, usage logging, and proxy stats dashboard |
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
      <img src="docs/images/claude-code-stats.png" alt="Claude Code stats dashboard">
    </td>
    <td width="50%">
      <img src="docs/images/codex-account-detail.png" alt="Account detail view">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Claude Code stats — per-model analytics</strong></td>
    <td align="center"><strong>Detailed account view</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/Claude-Code-Proxy-1.png" alt="Claude Code proxy node management">
    </td>
    <td width="50%">
      <img src="docs/images/Claude-Code-Proxy-2.png" alt="Claude Code proxy configuration">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Proxy node management</strong></td>
    <td align="center"><strong>Proxy node configuration</strong></td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/images/proxy-stats.png" alt="Proxy statistics dashboard">
    </td>
    <td width="50%">
      <img src="docs/images/menu_bar.png" alt="Menu bar quick view">
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Proxy statistics — per-model analytics</strong></td>
    <td align="center"><strong>Menu bar quick view</strong></td>
  </tr>
</table>

## Supported Sources

### Subscription and quota providers

`Codex` · `Copilot` · `Cursor` · `Antigravity` · `Kiro` · `Warp` · `Gemini CLI` · `Amp` · `Droid`

### Claude Code stats

`Claude Code` local spend ledger with per-model breakdown, input/output token split, and multi-period analysis

## Installation

Download the latest macOS package from the `Releases` page.

Available release assets:

- `.dmg`
- `.zip`

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Claude Code Proxy Plan](docs/claude-code-proxy-plan.md)
- [Proxy UI Implementation](docs/proxy-ui-implementation.md)
- [Claude Code Proxy Usage Guide](#claude-code-proxy)

## Claude Code Proxy

AIUsage includes a built-in Claude Code proxy that allows you to use Claude Code CLI with any OpenAI-compatible backend.

### Quick Start

1. Set environment variables:
```bash
export OPENAI_API_KEY=sk-your-openai-key
export OPENAI_BASE_URL=https://api.openai.com/v1  # optional
export BIG_MODEL=gpt-4o                            # maps to opus
export MIDDLE_MODEL=gpt-4o                         # maps to sonnet
export SMALL_MODEL=gpt-4o-mini                     # maps to haiku
```

2. Start the proxy server:
```bash
cd QuotaBackend
swift run QuotaServer --port 4318
```

3. Use Claude Code with the proxy:
```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:4318 claude
```

### Features

- ✅ **OpenAI Proxy** — Translate Claude API to OpenAI-compatible backends (DeepSeek, Azure, Ollama, etc.)
- ✅ **Anthropic Passthrough** — Transparent proxy for Anthropic API with full usage logging
- ✅ **Proxy Stats Dashboard** — Per-model cost/token trends, distribution charts, and data range awareness
- ✅ Full Claude Messages API support (`/v1/messages`) with streaming SSE
- ✅ Tool use / function calling / image support
- ✅ Per-model pricing configuration (USD/CNY) with customizable model matching
- ✅ Multi-node management with one-click activation
- ✅ Client API key authentication for secure access

### Configuration

All configuration is done via environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENAI_API_KEY` | Yes | - | Upstream API key |
| `OPENAI_BASE_URL` | No | `https://api.openai.com/v1` | Upstream base URL |
| `BIG_MODEL` | No | `gpt-4o` | Model for Claude Opus |
| `MIDDLE_MODEL` | No | `gpt-4o` | Model for Claude Sonnet |
| `SMALL_MODEL` | No | `gpt-4o-mini` | Model for Claude Haiku |
| `ANTHROPIC_API_KEY` | No | - | Expected client API key (for auth) |

### Testing

Run the test suite:
```bash
cd QuotaBackend
swift test
```

All 21 tests should pass, including:
- HTTP server enhancements (POST, headers, streaming)
- Model normalization and mapping
- Claude ↔ OpenAI protocol conversion
- Configuration validation
- Token estimation

### Architecture

The proxy consists of:
- **HTTP Server**: Enhanced `QuotaHTTPServer` with POST, headers, and SSE streaming
- **Data Models**: Complete Claude and OpenAI API models
- **Converters**: Bidirectional protocol translation
- **Configuration**: Environment-based setup with validation
- **Upstream Client**: HTTP client for OpenAI-compatible backends
- **Proxy Service**: Orchestrates authentication, conversion, and forwarding

See [Claude Code Proxy Plan](docs/claude-code-proxy-plan.md) for detailed implementation notes.

## Acknowledgements

Inspired by [`CodexBar`](https://github.com/steipete/CodexBar) and [`Quotio`](https://github.com/nguyenphutrong/quotio).

## Friendly Links

- [Linux.do Community](https://linux.do)

## License

This project is licensed under the [Apache License 2.0](LICENSE).
