# Localization Strategy

## Goal

AIUsage is in a controlled migration from inline bilingual bridge calls to standard Apple localization resources.

Current reality:

- the app still supports `L("Dashboard", "仪表盘")`
- static UI copy should progressively move into `Localizable.strings`
- the bridge remains as a compatibility layer so we can migrate incrementally without breaking existing screens

Target direction:

- `.strings` becomes the source of truth for reusable static UI copy
- `L()` becomes a thin compatibility and lookup bridge, not the long-term storage format
- dynamic and pluralized strings eventually move to dedicated formatting helpers or `.stringsdict`

## Decision Rules

### Prefer `.strings`-backed `L(..., key:)`

New static UI strings should usually be written as:

```swift
L("Dashboard", "仪表盘", key: "nav.dashboard")
```

Use this for:

- navigation labels
- section headers
- shared button titles
- repeated empty-state copy
- reusable status text

Why:

- the key stays stable even if the call site moves
- the generated `Localizable.strings` output remains reviewable
- translators do not need to care about source file layout

### Temporary bridge-only `L(en, zh)` is still allowed

Bridge-only calls without `key:` are still acceptable when all of the following are true:

- the string is local to one screen
- it is not expected to be reused
- extracting a stable key right now would add more churn than value

Even then, avoid adding new bridge-only calls for common actions like `Save`, `Cancel`, `Refresh`, `Settings`, or shared status labels.

### Dynamic interpolation stays out of the generator for now

These may keep using the fallback bridge temporarily:

```swift
L("\(count) selected", "已选 \(count) 项")
```

Reason:

- regex extraction is intentionally conservative
- dynamic strings need parameter-aware localization
- plural rules should ultimately be handled by `.stringsdict`, not ad-hoc duplicated phrases

### One meaning per key

If two English strings look identical but mean different things in UI context, split them into separate keys. Do not over-share keys just because the English source text matches.

## Source Of Truth

For static copy, the effective source of truth is:

1. explicit `key:` in `L(...)`
2. generated `Localizable.strings`
3. runtime fallback to inline English/Chinese pair

This means:

- the inline bilingual pair is still required during migration
- the stable key defines identity
- generated `.strings` files are the artifact we review and ship

## Generation Workflow

Run:

```bash
python3 scripts/generate_localizable_strings.py
```

Behavior:

- the script scans static `L("en", "zh", key: "...")` calls
- if `key:` exists, that stable key is used
- if `key:` is omitted, the script falls back to the legacy contextual key format

Legacy fallback format:

```text
AIUsage/<relative-file>::<english-text>
```

That fallback remains supported for compatibility, but it should stop expanding for new shared copy.

## Reviewer Checklist

When reviewing localization changes, check:

- does new static shared copy use `key:`?
- is the key stable and meaning-based rather than screen-position-based?
- are repeated phrases reusing the same key intentionally?
- did the change avoid introducing new file-path-derived keys for shared UI text?
- if the string is dynamic or pluralized, is there a note or helper instead of forcing it into a static extractor path?

## Migration Priorities

Move these first:

- navigation
- dashboard section titles
- settings labels
- proxy management shared actions
- common alert titles and button text

Leave for later:

- dynamic quota/status sentences
- pluralized copy
- strings assembled from runtime data

## Practical Constraints

- keep the app fully functional while both systems coexist
- do not block feature work on a full localization rewrite
- prefer small, reviewable migrations over bulk churn
- update generated strings in the same change when adding new stable keys

## Short-Term Success Criteria

- new static shared UI text uses stable keys
- `Localizable.strings` keeps growing in a controlled, key-based way
- bridge-only usage trends toward local or temporary cases only
- future contributors can follow one documented path instead of inventing a third system
