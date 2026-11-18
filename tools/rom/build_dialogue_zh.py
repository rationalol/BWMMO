#!/usr/bin/env python3
"""Build zh_CN NPC dialogue from a PokeMMO Chinese storyline dump.

Inputs:
  the BW ROM used by extract_dialogues.py (for the canonical English text tables)
  a PokeMMO language-mod XML dumped from the same text archive
    (ns_strings_zh_white.xml: <string block_id entry_id table_id>)
  server/content/rom/npc_dialogues.json  (English profiles, from extract_dialogues.py)
  server/content/rom/zone_entities.json  (zone id -> script ids)

Output:
  server/content/i18n/zh_CN/dialogue.json

Why this works: PokeMMO's storyline dump keeps the ROM's own text table ids.
table_id is the text archive member, block_id/entry_id locate the string inside
it, so a translated segment maps 1:1 onto the segment the field script prints.
`format_pages` splits the English segment on its <PAGE> markers; the Chinese
translation reflows those into a single page, so one Chinese entry becomes one
dialogue page while the English profile may have several.

Keys in the output are the canonical English dialogue (lines joined with
newlines), matching how names.json is keyed by canonical English names. The
server keeps canonical English content and only swaps display text.
"""

from __future__ import annotations

import argparse
import itertools
import json
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extract_dialogues import (  # noqa: E402
    MAX_VARIANT_FLAGS,
    decrypt_text_sections,
    detect_script_archive,
    detect_text_archive,
    format_pages,
    infer_speaker,
    read_script_table,
    referenced_flags,
    run_script,
    static_messages,
)
from nds_fs import ZONE_HEADER, NintendoDSRom, detect_zone_header_archive  # noqa: E402

ZH_ENTRY = re.compile(
    r'<string block_id="(\d+)" entry_id="(\d+)" table_id="(\d+)">(.*?)</string>',
    re.S,
)
EN_PLACEHOLDER = re.compile(r"\{(?:name|rival|nickname)?\}")
ZH_PLACEHOLDER = re.compile(r"\{(\d+)\}")
# PokeMMO dumps dialogue as `Speaker『text` or `Speaker: text`.
ZH_SPEAKER = re.compile(r"^([^\s『:：\n]{1,16})[『:：]\s*")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--zh",
        action="append",
        default=[],
        help="PokeMMO Chinese storyline XML; later files only fill gaps "
        "(default: .tools/pokemmo-zh/mod/custom-strings/ns_strings_zh_white.xml)",
    )
    parser.add_argument("--entities", default="server/content/rom/zone_entities.json")
    parser.add_argument("--dialogues", default="server/content/rom/npc_dialogues.json")
    parser.add_argument("--out", default="server/content/i18n/zh_CN/dialogue.json")
    parser.add_argument(
        "--report", default=".tools/pokemmo-zh/alignment-report.json"
    )
    return parser.parse_args()


def locate_rom(root: Path, value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        path = (root / value).resolve()
    if path.is_dir():
        candidates = sorted(path.glob("*.nds"))
        if not candidates:
            raise FileNotFoundError(f"no .nds file found in {path}")
        return candidates[0]
    return path


def load_zh_sections(paths: list[Path]) -> dict[tuple[int, int, int], str]:
    sections: dict[tuple[int, int, int], str] = {}
    for path in paths:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
        for block, entry, table, body in ZH_ENTRY.findall(text):
            key = (int(table), int(block), int(entry))
            if key in sections:
                continue
            sections[key] = body
    return sections


def clean_zh(raw: str) -> str:
    text = raw.replace("\\r", "\n").replace("\\n", "\n")
    text = text.replace("\r", "\n")
    # The panel shows the speaker from the NPC name, so drop a leading
    # "Name『" the pack left inside the segment.
    match = ZH_SPEAKER.match(text)
    if match:
        text = text[match.end():]
    lines = [line.rstrip() for line in text.split("\n")]
    text = "\n".join(lines).strip()
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


TERM_FIXES = (
    # The pack writes 精灵 and 训练师; the rest of the project uses the
    # official 宝可梦/训练家 naming. Poké Ball stays 精灵球, as in the games.
    ("精灵球", "\x00BALL\x00"),
    ("精灵中心", "宝可梦中心"),
    ("精灵图鉴", "宝可梦图鉴"),
    ("精灵", "宝可梦"),
    ("训练师", "训练家"),
    ("\x00BALL\x00", "精灵球"),
)


def normalize_terms(text: str) -> str:
    for source, target in TERM_FIXES:
        text = text.replace(source, target)
    return text


def normalize_punctuation(text: str) -> str:
    """Use full-width punctuation after Chinese, like the rest of the UI.

    The pack mixes ASCII punctuation into Chinese sentences ("好了!",
    "不过, ..."), which reads as a typesetting error next to the client's own
    labels.
    """
    text = text.replace("...", "……")
    boundary = r"[\u4e00-\u9fff」』）】…]"
    text = re.sub(rf"(?<={boundary}),[ \t]*", "，", text)
    text = re.sub(rf"(?<={boundary})!", "！", text)
    text = re.sub(rf"(?<={boundary})\?", "？", text)
    text = re.sub(rf"(?<={boundary})\.", "。", text)
    text = re.sub(rf"(?<={boundary}):", "：", text)
    # The pack leaves a space after punctuation; Chinese text does not.
    text = re.sub(r"([，。！？：；、…])[ \t]+", r"\1", text)
    return text


def paginate(text: str, max_lines: int) -> list[str]:
    """Split a translated segment into dialogue pages the panel can show.

    The ROM uses multi-line pages; the PokeMMO translation reflows the same
    text into one block. Three lines keep the 150px dialogue panel readable
    without autowrap pushing text past its bottom edge.
    """
    pages: list[str] = []
    for paragraph in re.split(r"\n\s*\n", text):
        lines = [line.strip() for line in paragraph.split("\n") if line.strip()]
        start = 0
        while start < len(lines):
            end = min(start + max_lines, len(lines))
            # Keep a sentence together: drop the last line into the next page
            # when the split would cut mid-sentence.
            if (
                end < len(lines)
                and end - start > 1
                and not lines[end - 1].endswith(tuple("。！？…!?.”」』)，,、；;：:"))
            ):
                end -= 1
            pages.append("\n".join(lines[start:end]))
            start = end
    return pages


def map_placeholders(english_raw: str, text: str) -> tuple[str, bool]:
    tokens = EN_PLACEHOLDER.findall(english_raw)
    overflow = False

    def replace(match: re.Match[str]) -> str:
        nonlocal overflow
        index = int(match.group(1))
        if index < len(tokens):
            return tokens[index]
        # The pack references an argument the English segment does not print
        # (PokeMMO numbers arguments differently); keep the same neutral
        # placeholder the English renderer leaves for unknown arguments.
        overflow = True
        return "{}"

    return ZH_PLACEHOLDER.sub(replace, text), overflow


def text_lines(message_ids: list[int], sections: list[str]) -> list[str]:
    lines: list[str] = []
    for message_id in message_ids:
        if 0 <= message_id < len(sections):
            raw = sections[message_id]
            lines.extend(format_pages(raw, infer_speaker(raw)))
    return lines


def profile_messages(script: bytes, start: int, end: int, sections: list[str]):
    """Default plus conditional message ids in profile_for_script order."""
    flags = sorted(referenced_flags(script, start, end))
    defaults = run_script(script, start, end, {})
    if not defaults.messages:
        return [static_messages(script, start, end, len(sections))]

    groups = [defaults.messages]
    seen = {tuple(text_lines(defaults.messages, sections))}
    if 0 < len(flags) <= MAX_VARIANT_FLAGS:
        for values in itertools.product((0, 1), repeat=len(flags)):
            if all(value == 0 for value in values):
                continue
            run = run_script(script, start, end, dict(zip(flags, values)))
            lines = text_lines(run.messages, sections)
            if not lines:
                continue
            key = tuple(lines)
            if key in seen:
                continue
            seen.add(key)
            groups.append(run.messages)
    return groups


def placeholder_alignment(
    english: list[str],
    entries: dict[int, str],
    mapping: dict[int, int],
) -> bool:
    """Reject an ordinal mapping whose argument counts do not line up.

    The pack's story text is adapted for PokeMMO, so a few tables no longer
    follow the ROM line by line. A translation keeps the number of runtime
    arguments, so a table where almost none of the argument-bearing lines
    agree is not trustworthy.
    """
    pairs = matches = 0
    for entry, section in mapping.items():
        source = english[section] if section < len(english) else ""
        target = entries[entry]
        source_args = len(EN_PLACEHOLDER.findall(source))
        target_args = len(ZH_PLACEHOLDER.findall(target))
        if source_args == 0 and target_args == 0:
            continue
        pairs += 1
        if source_args == target_args:
            matches += 1
    return pairs < 5 or matches / pairs >= 0.3


def zh_sections_for_file(
    text_file: int,
    raw: bytes,
    zh_sections: dict[tuple[int, int, int], str],
    issues: dict,
) -> dict[int, str]:
    """Map ROM section index -> Chinese text for one text archive member.

    The dump is not always a byte-for-byte copy of our ROM's table: some
    versions leave a slot empty where the pack has text and vice versa. Per
    block, pick the reading that matches the dump's entry count:

    - same count as the block's declared entries: entry ids are section ids;
    - same count as the block's non-empty entries: the dump skipped empties;
    - anything else: the tables differ, so skip the block instead of guessing.
    """
    num_blocks, entries_per_block, _, _ = struct.unpack_from("<HHII", raw, 0)
    if num_blocks == 0 or entries_per_block == 0:
        return {}
    sections = decrypt_text_sections(raw)
    out: dict[int, str] = {}
    for block in range(num_blocks):
        entries = {
            entry: text
            for (table, entry_block, entry), text in zh_sections.items()
            if table == text_file and entry_block == block
        }
        if not entries:
            continue
        chunk = sections[
            block * entries_per_block:(block + 1) * entries_per_block
        ]
        non_empty = [index for index, text in enumerate(chunk) if text.strip()]
        ordinal = False
        if len(entries) == entries_per_block:
            mapping = {entry: entry for entry in entries}
        elif len(entries) == len(non_empty):
            ordinal = True
            mapping = {
                entry: non_empty[entry]
                for entry in entries
                if entry < len(non_empty)
            }
        else:
            issues["ambiguousTables"].append(text_file)
            continue
        if ordinal and not placeholder_alignment(chunk, entries, mapping):
            issues["misalignedTables"].append(text_file)
            continue
        for entry, section in mapping.items():
            out[block * entries_per_block + section] = entries[entry]
    return out


def zh_pages(
    message_ids: list[int],
    english_sections: list[str],
    zh_by_section: dict[int, str],
    issues: dict,
) -> list[str] | None:
    pages: list[str] = []
    for message_id in message_ids:
        raw = zh_by_section.get(message_id, "")
        if not raw.strip():
            return None
        english_raw = english_sections[message_id] if message_id < len(english_sections) else ""
        text = clean_zh(raw)
        if not text:
            return None
        text, overflow = map_placeholders(english_raw, text)
        if overflow:
            issues["placeholderOverflow"] += 1
        pages.extend(paginate(normalize_punctuation(normalize_terms(text)), 3))
    return pages


def main() -> int:
    args = parse_arguments()
    root = Path(__file__).resolve().parents[2]
    rom = NintendoDSRom.open(locate_rom(root, args.rom))
    _, script_archive = detect_script_archive(rom)
    _, text_archive = detect_text_archive(rom)
    scripts = script_archive.files
    texts = text_archive.files

    zh_paths = [Path(p) for p in args.zh]
    if not zh_paths:
        zh_paths = [
            root / ".tools/pokemmo-zh/mod/custom-strings/ns_strings_zh_white.xml"
        ]
    zh_paths = [p if p.is_absolute() else root / p for p in zh_paths]
    missing = [str(p) for p in zh_paths if not p.exists()]
    if missing:
        print("missing Chinese dump:", ", ".join(missing), file=sys.stderr)
        return 1
    zh_sections = load_zh_sections(zh_paths)

    entities = json.loads((root / args.entities).read_text(encoding="utf-8"))
    profiles = json.loads((root / args.dialogues).read_text(encoding="utf-8"))
    zone_npcs = {zone["id"]: zone["npcs"] for zone in entities["zones"]}
    _, headers = detect_zone_header_archive(
        rom,
        max(zone_npcs) + 1,
        len(scripts),
        len(texts),
    )

    dialogues: dict[str, list[str]] = {}
    collided: set[str] = set()
    issues = {
        "zones": 0,
        "profiles": 0,
        "translated": 0,
        "variants": 0,
        "variantsTranslated": 0,
        "skipped": [],
        "collisions": [],
        "placeholderOverflow": 0,
        "missingZones": [],
        "ambiguousTables": [],
        "misalignedTables": [],
    }

    def add_dialogue(key: str, pages: list[str], ref: str) -> bool:
        """Store a translation; drop keys two profiles translate differently.

        Short reaction pages ("...") occur in several scenes with different
        translations, and a text-keyed table cannot tell them apart, so those
        keys stay English instead of showing the wrong line.
        """
        if key in collided:
            return False
        previous = dialogues.get(key)
        if previous is None:
            dialogues[key] = pages
            return True
        if previous != pages:
            del dialogues[key]
            collided.add(key)
            issues["collisions"].append(ref)
        return False

    for zone_key, zone in profiles["zones"].items():
        zone_id = int(zone_key)
        if zone_id * ZONE_HEADER.size + ZONE_HEADER.size > len(headers):
            issues["missingZones"].append(zone_id)
            continue
        header = ZONE_HEADER.unpack_from(headers, zone_id * ZONE_HEADER.size)
        script_file, text_file = header[4], header[6]
        if script_file >= len(scripts) or text_file >= len(texts):
            issues["missingZones"].append(zone_id)
            continue
        script = scripts[script_file]
        offsets = read_script_table(script)
        text_blocks, entries_per_block, _, _ = struct.unpack_from(
            "<HHII", texts[text_file], 0
        )
        if not offsets or text_blocks == 0 or entries_per_block == 0:
            issues["missingZones"].append(zone_id)
            continue
        english_sections = decrypt_text_sections(texts[text_file])
        zh_by_section = zh_sections_for_file(
            text_file, texts[text_file], zh_sections, issues
        )
        if not zh_by_section:
            issues["skipped"].append(f"zone:{zone_id}")
            continue
        npc_scripts = zone_npcs.get(zone_id, [])
        issues["zones"] += 1

        for npc_key, profile in zone["npcs"].items():
            index = int(npc_key)
            if index >= len(npc_scripts):
                continue
            script_id = npc_scripts[index].get("script", 0)
            if script_id <= 0 or script_id > len(offsets):
                continue
            start = offsets[script_id - 1]
            end = min([offset for offset in offsets if offset > start] + [len(script)])

            groups = profile_messages(script, start, end, english_sections)
            if not groups or not groups[0]:
                continue
            issues["profiles"] += 1

            default = zh_pages(
                groups[0],
                english_sections,
                zh_by_section,
                issues,
            )
            if default is None:
                issues["skipped"].append(f"{zone_id}/{npc_key}")
                continue
            key = "\n".join(profile["lines"])
            if add_dialogue(key, default, f"{zone_id}/{npc_key}"):
                issues["translated"] += 1

            variants = profile.get("variants", [])
            for position, variant in enumerate(variants):
                if position + 1 >= len(groups):
                    break
                issues["variants"] += 1
                pages = zh_pages(
                    groups[position + 1],
                    english_sections,
                    zh_by_section,
                    issues,
                )
                if pages is None:
                    issues["skipped"].append(f"{zone_id}/{npc_key}#{position}")
                    continue
                variant_key = "\n".join(variant["lines"])
                if add_dialogue(
                    variant_key, pages, f"{zone_id}/{npc_key}#{position}"
                ):
                    issues["variantsTranslated"] += 1

    out_path = root / args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "locale": "zh_CN",
        "source": (
            "PokeMMO zh_CN storyline strings aligned to the Black/White text "
            "tables; keyed by canonical English dialogue"
        ),
        "dialogues": dict(sorted(dialogues.items())),
    }
    out_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    issues["ambiguousTables"] = sorted(set(issues["ambiguousTables"]))
    issues["misalignedTables"] = sorted(set(issues["misalignedTables"]))
    report = {
        "zhSources": [str(p.relative_to(root)) for p in zh_paths],
        "dialogues": len(dialogues),
        **issues,
    }
    report_path = root / args.report
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(
        f"{issues['translated']}/{issues['profiles']} profiles translated, "
        f"{issues['variantsTranslated']}/{issues['variants']} variants, "
        f"{len(dialogues)} dialogue keys -> {out_path.relative_to(root)}"
    )
    if issues["skipped"]:
        print(f"skipped: {len(issues['skipped'])} (see {report_path})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
