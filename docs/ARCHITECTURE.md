# Architecture

## Overview

AIUsage has two layers:

- `AIUsage` is the macOS SwiftUI frontend
- `QuotaBackend` is the data collection and normalization layer

The same backend can run:

- embedded inside the app in `Local` mode
- as an HTTP service through `QuotaServer` in `Remote` mode

## Main Frontend Types

### `AppState`

File: `AIUsage/Models/AppState.swift`

Responsibilities:

- holds global UI state
- stores selected providers and account registry
- manages scan scope, including first-run selection and later source toggling
- manages per-account visibility so removed live cards stay hidden until explicitly restored
- chooses local vs remote backend mode
- refreshes dashboard and provider data
- reconciles live provider results with stored accounts

This is the main coordination point of the app.

### `ProviderData` And Related Models

File: `AIUsage/Models/ProviderModels.swift`

Responsibilities:

- defines the app-facing display model
- groups live providers and stored accounts into provider/account sections
- describes provider catalog metadata used by onboarding and filtering

## Backend Core

### `ProviderRegistry`

File: `QuotaBackend/Sources/QuotaBackend/Engine/ProviderRegistry.swift`

Responsibilities:

- owns the canonical list of supported providers
- resolves providers by id

### `ProviderEngine`

File: `QuotaBackend/Sources/QuotaBackend/Engine/ProviderEngine.swift`

Responsibilities:

- fetches all providers concurrently
- supports both single-account and multi-account providers
- merges auto-discovered accounts with credential-backed accounts
- removes duplicate results when multiple discovery paths resolve to the same account

Important behavior:

- `fetchAll(ids:)` is the most complete API because it preserves multi-account results and produces an overview.
- `fetchMultiAccountProvider(id:)` is the best per-provider API for account-aware refreshes.

### `UsageNormalizer`

File: `QuotaBackend/Sources/QuotaBackend/Normalizer/UsageNormalizer.swift`

Responsibilities:

- maps raw `ProviderUsage` to normalized `ProviderSummary`
- assigns status, headline, metrics, windows, and cost information
- builds `DashboardOverview`

Keep provider-specific extraction in providers. Keep cross-provider presentation rules here.

## Data Flow

### Local Mode

1. `ContentView` starts a refresh through `AppState`
2. `AppState` calls `ProviderEngine`
3. Each provider fetches raw usage
4. `UsageNormalizer` creates summaries and overview
5. `AppState` localizes strings and converts summaries into `ProviderData`
6. SwiftUI renders the dashboard, provider groups, and cost tracking views

### Remote Mode

1. `ContentView` starts a refresh through `AppState`
2. `AppState` calls `APIService`
3. `APIService` requests `QuotaServer`
4. `QuotaServer` calls the same `ProviderEngine`
5. The app decodes the remote snapshot and renders it

## Multi-Account Architecture

There are three identity layers:

- live provider result ids
- provider account ids or labels from the source system
- locally stored account records and Keychain credentials
- local hidden-account tombstones used to suppress rediscovered cards the user intentionally removed

Matching order today:

1. stable account id if available
2. normalized email or label
3. limited fallback to a single unmatched credential-backed stored account

This keeps multiple accounts visible even when one account is offline or unauthorized.

## Storage Boundaries

### `SecureAccountVault`

App-side storage for account records such as:

- provider id
- email or display label
- note
- credential id linkage

### `AccountCredentialStore`

Backend-side Keychain storage for secrets such as:

- cookies
- tokens
- auth file references
- API keys

The frontend should never store raw credentials in `UserDefaults`.

## Extension Points

### Add A New Provider

1. Create a new fetcher in `QuotaBackend/Sources/QuotaBackend/Providers/`
2. Register it in `ProviderRegistry`
3. Add normalization rules in `UsageNormalizer`
4. Add frontend catalog metadata in `AppState.providerCatalogItems`
5. Add icon assets and any provider-specific UI polish
6. Add or update tests if normalization or grouping behavior changes

### Add Credential Support

1. Conform the provider to `CredentialAcceptingProvider`
2. Implement `supportedAuthMethods`
3. Implement `fetchUsage(with:)`
4. Make sure account identity is returned consistently

### Add Multi-Account Auto Discovery

1. Conform the provider to `MultiAccountProviderFetcher`
2. Return one `AccountFetchResult` per account
3. Ensure each result has the strongest available stable identity
