#!/usr/bin/env python3
"""Check that UI translation keys exist and keep their format placeholders."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "client" / "scripts"
I18N = ROOT / "client" / "i18n" / "zh_CN.json"

CALL_PATTERNS = [
    re.compile(
        r'(?:Loc\.(?:t|tf|make_label|make_bold_label|bind|bind_tooltip)|TranslationServer\.translate)'
        r'\(\s*"((?:[^"\\]|\\.)*)"'
    ),
    re.compile(
        r'Loc\.(?:make_label|make_bold_label|bind|bind_tooltip)'
        r'\(\s*[^,\n]+,\s*"((?:[^"\\]|\\.)*)"'
    ),
    re.compile(r'_section_label\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'_add_setting_toggle\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'set_connection\(\s*"((?:[^"\\]|\\.)*)"'),
]

PLACEHOLDER = re.compile(r"%(?!%)[-+0-9.]*[sd]")

def decode(value: str) -> str:
    return value.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")

def main() -> None:
    messages = json.loads(I18N.read_text(encoding="utf-8"))
    used: set[str] = set()
    for script in SCRIPTS.glob("*.gd"):
        text = script.read_text(encoding="utf-8")
        for pattern in CALL_PATTERNS:
            for match in pattern.finditer(text):
                key = decode(match.group(1))
                if key and not key.endswith("."):
                    used.add(key)

    missing = sorted(key for key in used if key not in messages)
    mismatched: list[str] = []
    for key in sorted(used & set(messages)):
        source = Counter(PLACEHOLDER.findall(key))
        target = Counter(PLACEHOLDER.findall(messages[key]))
        if source != target:
            mismatched.append(
                f"{key!r}: placeholders {dict(source)} -> {dict(target)}"
            )

    if missing:
        print("Missing translations:")
        for key in missing:
            print(f"  - {key!r}")
    if mismatched:
        print("Placeholder mismatches:")
        for item in mismatched:
            print(f"  - {item}")
    if missing or mismatched:
        raise SystemExit(1)
    print(f"i18n catalog covers {len(used)} source keys")

if __name__ == "__main__":
    main()
