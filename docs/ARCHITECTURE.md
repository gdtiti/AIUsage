# Architecture

## Overview

AIUsage is a macOS menu bar + windowed application for monitoring AI tool quota usage across multiple providers (Cursor, Codex, Gemini CLI, Copilot, Amp, etc.).

It has two layers:

- **`AIUsage`** — macOS SwiftUI frontend (menu bar popover + main window)
- **`QuotaBackend`** — Swift Package for data collection, credential management, and normalization

The same backend can run:

- embedded inside the app in **Local** mode
- as an HTTP service through `QuotaServer` in **Remote** mode

## Project Structure

```
AIUsage/
├── AIUsageApp.swift          # App entry, Sparkle updater, AppDelegate (menu bar)
├── Models/
│   ├── AppState.swift        # Global state coordinator (UI, accounts, refresh)
│   └── ProviderModels.swift  # Display models, grouping, catalog metadata
├── Views/
│   ├── ContentView.swift     # NavigationSplitView shell
│   ├── DashboardView.swift   # Overview cards grid
│   ├── MenuBarView.swift     # Menu bar popover (quota rings, account switching)
│   ├── ProviderCard.swift    # Individual provider card with quota indicators
│   ├── SettingsView.swift    # Preferences (theme, backend, Sparkle updates)
│   └── ...
├── Services/
│   ├── APIService.swift      # HTTP client for remote backend
│   ├── SecureAccountVault.swift  # Keychain storage for account records
│   └── ProviderAuthManager.swift # Account import/activation workflows
└── Resources/
    ├── Assets.xcassets/      # App icon, provider icons
    └── {Base,zh_CN}.lproj/   # Custom Sparkle localization strings

QuotaBackend/
├── Sources/QuotaBackend/
│   ├── ProviderProtocol.swift    # ProviderFetcher, CredentialAcceptingProvider protocols
│   ├── Engine/
│   │   ├── ProviderEngine.swift       # Concurrent fetcher + result merger
│   │   ├── ProviderRegistry.swift     # Static provider catalog (cached dict)
│   │   ├── AccountCredentialStore.swift # Keychain credential vault (v2)
│   │   └── BrowserDiscovery.swift     # Dynamic Chromium profile discovery
│   ├── Normalizer/
│   │   ├── UsageNormalizer.swift  # Raw → normalized summary
│   │   └── ProviderSummary.swift  # Normalized data types
│   └── Providers/
│       ├── CursorProvider.swift   # Cookie-based
│       ├── CodexProvider.swift    # Auth file + token
│       ├── GeminiProvider.swift   # OAuth + token refresh
│       ├── CopilotProvider.swift  # GitHub token
│       └── ...                    # Amp, Antigravity, Claude, Droid, Kiro, Warp
└── Sources/QuotaServer/          # Standalone HTTP server (Remote mode)
```

## Main Frontend Types

### `AppState`

File: `AIUsage/Models/AppState.swift`

Central coordinator. Responsibilities:

- Global UI state (selected section, loading flags, theme mode)
- Provider account registry and Keychain credential coordination
- Scan scope management (first-run selection, source toggling)
- Per-account visibility (hidden-account tombstones for removed cards)
- Local vs. remote backend selection
- Dashboard and provider data refresh orchestration
- Account activation for Codex CLI and Gemini CLI (auth file format conversion)
- Active account detection (`detectActiveCodexAccount`, `detectActiveGeminiAccount`)

> **Known technical debt**: This is a large file (~2700 lines). Future work should split it into focused coordinators: `AccountStore`, `ProviderRefreshCoordinator`, `AppSettings`.

### `ProviderData` And Related Models

File: `AIUsage/Models/ProviderModels.swift`

- App-facing display model with computed labels (`cardTitle`, `cardSubtitle`, `footerAccountLabel`)
- `ProviderAccountEntry` / `ProviderAccountGroup` for grouped provider display
- `CostSummary` / `CostPeriod` for cost tracking data
- Provider catalog metadata for onboarding and filtering

### Menu Bar (`MenuBarView`)

File: `AIUsage/Views/MenuBarView.swift`

- `NSPopover`-based menu bar UI shown on left-click of status item
- Grouped by provider with `MenuBarProviderSection` and `MenuBarAccountRow`
- `MiniQuotaRing` for compact quota visualization
- One-click account switching for supported providers (Codex, Gemini CLI)
- Active account badge display

## Backend Core

### `ProviderRegistry`

Uses a static dictionary for O(1) provider lookup (no per-call allocation).

### `ProviderEngine`

Actor-based concurrent fetcher. Key behaviors:

- `fetchAll(ids:)` — full dashboard refresh with overview generation
- `fetchMultiAccountProvider(id:)` — per-provider account-aware refresh
- Merges auto-discovered accounts with credential-backed accounts
- Deduplicates results when multiple discovery paths resolve to the same account
- Uses `os.Logger` for structured logging (no credential paths in production logs)

### `UsageNormalizer`

Maps raw `ProviderUsage` → normalized `ProviderSummary` with status, headline, metrics, quota windows (including `resetAt`), and cost information.

### `AccountCredentialStore`

Keychain-backed credential vault (v2 format — single vault entry instead of per-credential items). Supports deduplication and canonical credential selection based on scoring.

### `BrowserDiscovery`

Dynamically discovers Chromium-based browser profiles by enumerating directories under each browser's Application Support path. Supports Chrome, Arc, Edge, Brave, and Cursor. No longer limited to hardcoded profile names.

## Data Flow

### Local Mode

1. `ContentView` triggers refresh → `AppState`
2. `AppState` → `ProviderEngine.fetchAll()`
3. Each provider fetches raw usage concurrently
4. `UsageNormalizer` creates summaries and overview
5. `AppState` localizes, converts to `ProviderData`, groups into `ProviderAccountGroup`
6. SwiftUI renders dashboard, provider groups, menu bar popover, and cost tracking

### Remote Mode

1. `ContentView` triggers refresh → `AppState` → `APIService`
2. `APIService` → `QuotaServer` (HTTP)
3. `QuotaServer` → `ProviderEngine` (same pipeline)
4. App decodes the remote snapshot and renders it

## Multi-Account Architecture

Identity layers:

1. Stable account ID (from provider API)
2. Normalized email or label
3. Locally stored account records + Keychain credentials
4. Hidden-account tombstones (suppress rediscovered cards user removed)

Matching priority: stable ID → email → limited fallback to unmatched credential.

## Account Activation

Supported providers for file-based account switching:

- **Codex CLI**: Converts `cli-proxy-api` flat JSON → nested `tokens` format in `~/.codex/auth.json`
- **Gemini CLI**: Converts token format to `~/.gemini/oauth_creds.json`, preserves `client_id`/`client_secret` for token refresh

Antigravity IDE relies on Chromium browser profiles and is not activatable via file replacement.

## Storage Boundaries

### `SecureAccountVault`

App-side Keychain storage for account records (provider ID, email, note, credential linkage). Logs Keychain errors via `os.Logger`.

### `AccountCredentialStore`

Backend-side Keychain vault for secrets (cookies, tokens, auth file references, API keys). Uses a single vault entry (v2 format) to avoid repeated Keychain access prompts.

## Auto-Updates

Uses [Sparkle](https://sparkle-project.org/) framework with EdDSA signing:

- Custom localized strings injected during release packaging (`scripts/package-release.sh`)
- `appcast.xml` updated via CI after each tagged release
- Supports both automatic background checks and manual "Check for Updates"

## CI/CD

GitHub Actions workflow (`release.yml`):

1. Validates version consistency (Info.plist, project.pbxproj, git tag)
2. Resolves SPM dependencies
3. Builds Release configuration with `package-release.sh`
4. Injects custom Sparkle strings, signs with EdDSA
5. Publishes `.zip` + `.dmg` to GitHub Releases
6. Updates `appcast.xml` via PR (not direct push to main)

## Extension Points

### Add A New Provider

1. Create a fetcher in `QuotaBackend/Sources/QuotaBackend/Providers/`
2. Register it in `ProviderRegistry.all` array
3. Add normalization rules in `UsageNormalizer`
4. Add frontend catalog metadata in `AppState.providerCatalogItems`
5. Add icon assets and any provider-specific UI
6. Add browser discovery capability if cookie-based
7. Update tests

### Add Credential Support

1. Conform provider to `CredentialAcceptingProvider`
2. Implement `supportedAuthMethods` and `fetchUsage(with:)`
3. Ensure consistent account identity in results

### Add Multi-Account Auto Discovery

1. Conform provider to `MultiAccountProviderFetcher`
2. Return one `AccountFetchResult` per account with strongest available stable identity
