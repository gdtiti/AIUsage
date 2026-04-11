# Authentication And Multi-Account Design

Last updated: 2026-04-11

This document describes the public design goals behind authentication, account persistence,
and multi-account monitoring in AIUsage.

It is intentionally written as a public-facing technical note, not as an internal incident log.

## What This Document Covers

- how AIUsage thinks about saved accounts
- what “managed credentials” means
- how refresh behavior is scoped
- what rules new providers should follow
- what public-repo guardrails apply to auth-related code

## Design Goals

AIUsage treats account stability as a product feature.

That means:

1. a newly connected account should remain available after relaunch
2. multiple accounts under one provider should remain distinct
3. a refresh for one account should not unexpectedly mutate another account
4. imported credentials should be managed by AIUsage instead of depending entirely on fragile shared upstream session state
5. public source code should not contain vendor OAuth secrets

## Managed Credential Model

AIUsage uses a managed-account model instead of relying only on whatever a provider happens to expose at runtime.

In practice:

- providers may discover candidate sessions from local apps, browser state, CLI logins, or local auth files
- once a candidate is validated, AIUsage promotes it into its own managed credential layer
- managed credentials are stored in macOS Keychain
- file-based imports are copied into app-managed storage when needed so future upstream logins do not silently overwrite them

This gives the app a stable identity anchor for each monitored account.

## Account Identity Principles

When possible, AIUsage prefers stronger identities over weaker labels.

Typical priority:

1. managed credential id
2. provider-native account id
3. email or login
4. provider-specific fallback label

The goal is to keep cards stable even when one discovery path is temporarily missing.

## Refresh Scope

AIUsage supports three refresh levels:

### Card-level refresh

- refreshes a single monitored account
- should prefer the saved credential for that account

### Provider-level refresh

- refreshes all accounts under one provider
- should preserve healthy managed-account snapshots instead of replacing them with weaker transient discovery results

### Global refresh

- refreshes every selected provider and account
- should behave as a fan-out of provider-level refreshes, not as a destructive reset of account state

## Provider Categories

Different providers expose auth state in different shapes:

- browser-backed sessions
- CLI login state
- file-backed sessions
- token-based credentials
- local-log-only sources

AIUsage does not force every provider into one raw storage format.
Instead, it enforces one consistent lifecycle:

1. discover
2. validate
3. persist
4. refresh by stable identity
5. delete cleanly

## Storage Boundaries

AIUsage separates metadata from secrets:

- account metadata:
  stored as a registry of monitored accounts
- credentials:
  stored in macOS Keychain

This separation helps with:

- safe UI state recovery
- account hiding and restoration
- credential rotation without rewriting all visible account metadata

## What Makes A Provider “Multi-Account Ready”

A provider is ready for AIUsage multi-account monitoring when it can do all of the following:

1. expose one stable identity per account
2. validate discovered sessions before promoting them
3. refresh one account without implicitly refreshing all accounts
4. survive app relaunch without collapsing back into a singleton shared session
5. delete accounts cleanly without leaving zombie cards behind
