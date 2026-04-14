# Localization Strategy

## Current approach

AIUsage is in a transition phase between:

- inline bilingual bridge calls such as `L("Dashboard", "仪表盘")`
- standard `Localizable.strings` resources

The bridge stays in place for compatibility, but `.strings` is now the source of truth for new static UI copy.

## Rules

1. New static UI strings should prefer:

```swift
L("Dashboard", "仪表盘", key: "nav.dashboard")
```

2. Reused copy should share a stable key instead of relying on the call-site-derived fallback key.

3. Dynamic interpolation strings may keep using the fallback bridge temporarily:

```swift
L("\(count) selected", "已选 \(count) 项")
```

Reason:
- they are harder to extract safely with regex
- they should eventually move to parameterized `.stringsdict` or dedicated formatting helpers

4. Avoid adding new plain `L(en, zh)` calls for repeated static labels unless there is a good reason.

## Generation workflow

Static `L(...)` calls are exported with:

```bash
python3 scripts/generate_localizable_strings.py
```

The script now prefers the explicit `key:` argument when present. If no explicit key is supplied, it falls back to the legacy contextual key format:

```text
AIUsage/<relative-file>::<english-text>
```

## Migration guidance

- Use stable keys for navigation, section titles, shared actions, and other repeated UI chrome first.
- Keep one English meaning per key. If translations differ by context, split into separate keys.
- When adding parameterized or pluralized strings, plan for `.stringsdict` instead of expanding the ad-hoc bilingual bridge.

## Short-term goal

- Keep the app fully functional with the bridge.
- Stop expanding file-path-derived keys for new shared UI text.
- Gradually migrate repeated static copy to stable localization keys.
