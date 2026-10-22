#!/usr/bin/env python3
"""Build Godot PO catalogs from the JSON translation sources.

Godot loads .po files at runtime; the JSON files are the editable source of
truth because they are easier to diff and validate than hand-written PO.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
I18N_DIR = ROOT / "client" / "i18n"


def escape_po(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
    )


def build_locale(locale: str) -> None:
    source = I18N_DIR / f"{locale}.json"
    if not source.exists():
        raise SystemExit(f"missing translation source: {source}")
    messages = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(messages, dict):
        raise SystemExit(f"{source} must contain a JSON object")
    lines = [
        'msgid ""',
        'msgstr ""',
        f'"Language: {locale}\\n"',
        '"MIME-Version: 1.0\\n"',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        '"Content-Transfer-Encoding: 8bit\\n"',
        '"Plural-Forms: nplurals=1; plural=0;\\n"',
        "",
    ]
    for key in sorted(messages):
        value = messages[key]
        if not isinstance(value, str):
            raise SystemExit(f"{source}: translation for {key!r} must be a string")
        lines.append(f'msgid "{escape_po(key)}"')
        lines.append(f'msgstr "{escape_po(value)}"')
        lines.append("")
    target = I18N_DIR / f"{locale}.po"
    target.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"wrote {target.relative_to(ROOT)} ({len(messages)} entries)")


def main() -> None:
    sources = sorted(I18N_DIR.glob("*.json"))
    if not sources:
        raise SystemExit("no translation sources found")
    for source in sources:
        build_locale(source.stem)


if __name__ == "__main__":
    main()
