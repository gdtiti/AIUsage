#!/usr/bin/env python3

import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "AIUsage"
OUTPUTS = {
    "en": SOURCE_ROOT / "Resources" / "en.lproj" / "Localizable.strings",
    "zh_CN": SOURCE_ROOT / "Resources" / "zh_CN.lproj" / "Localizable.strings",
}

PATTERN = re.compile(
    r'L\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*(?:,\s*key:\s*"((?:[^"\\]|\\.)*)")?\s*\)',
    re.S,
)


def decode_swift_literal(value: str) -> str:
    value = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda match: chr(int(match.group(1), 16)), value)
    replacements = {
        r"\\": "\\",
        r"\"": "\"",
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
    }
    for source, target in replacements.items():
        value = value.replace(source, target)
    return value


def escape_strings_value(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
    )


def should_skip(value: str) -> bool:
    return "\\(" in value


def collect_pairs() -> list[tuple[str, str, str]]:
    entries: dict[str, tuple[str, str, str]] = {}

    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        relative = path.relative_to(SOURCE_ROOT).as_posix()
        source = path.read_text()

        for english_raw, chinese_raw, explicit_key_raw in PATTERN.findall(source):
            if should_skip(english_raw) or should_skip(chinese_raw):
                continue

            english = decode_swift_literal(english_raw)
            chinese = decode_swift_literal(chinese_raw)
            explicit_key = decode_swift_literal(explicit_key_raw) if explicit_key_raw else None
            key = explicit_key or f"AIUsage/{relative}::{english}"
            entries.setdefault(key, (relative, english, chinese))

    return sorted((key, relative, english, chinese) for key, (relative, english, chinese) in entries.items())


def write_strings(entries: list[tuple[str, str, str, str]], language: str) -> None:
    output = OUTPUTS[language]
    output.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        "/* Generated from static L(en, zh) calls. */",
        "/* Dynamic interpolation-based strings still use the runtime fallback path. */",
        "",
    ]

    for key, relative, english, chinese in entries:
        value = english if language == "en" else chinese
        lines.append(f"/* {relative} */")
        lines.append(f"\"{escape_strings_value(key)}\" = \"{escape_strings_value(value)}\";")
        lines.append("")

    output.write_text("\n".join(lines))


def main() -> None:
    entries = collect_pairs()
    for language in OUTPUTS:
        write_strings(entries, language)
    print(f"Generated {len(entries)} localized string entries.")


if __name__ == "__main__":
    main()
