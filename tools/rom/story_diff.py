#!/usr/bin/env python3
"""Compare hand-authored story scenes with the ROM scripts that inspired them.

`trace_script.py` replays one ROM script and prints its dialogue. This tool
replays the scripts behind the prologue, lines the output up against
`server/content/story/nuvema.json`, and reports what differs: lines the ROM has
that the story does not, lines the story invents, and text that appears in both
but is split into pages differently (usually harmless).

    python3 tools/rom/story_diff.py            # markdown report on stdout
    python3 tools/rom/story_diff.py --json     # machine-readable
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from pathlib import Path

from extract_dialogues import (
    SCRIPT_MSG_FILE,
    decrypt_text_sections,
    detect_text_archive,
    format_pages,
    infer_speaker,
    locate_rom,
    read_script_table,
    run_script,
)
from nds_fs import ZONE_HEADER, NintendoDSRom, detect_script_archive, detect_zone_header_archive
from trace_script import resolve_entry

ROOT = Path(__file__).resolve().parents[2]
STORY = ROOT / "server" / "content" / "story" / "nuvema.json"

# One entry per passage worth replaying. `entry` pins the instruction offset
# when the script table points at a preamble the VM does not decode; `flags`
# reproduce the game state the scene is triggered in.
SCENARIOS = [
    {
        "scene": "prologue_bedroom_intro",
        "label": "卧室 · 切磋胜",
        "zone": 391,
        "npc": 2,
        "flags": {},
        "battle": 1,
    },
    {
        "scene": "prologue_bedroom_intro",
        "label": "卧室 · 切磋负",
        "zone": 391,
        "npc": 2,
        "flags": {},
        "battle": 0,
    },
    {
        "scene": "prologue_mom",
        "label": "妈妈 · 已选御三家（flag 2402=1）",
        "zone": 390,
        "npc": 0,
        "flags": {2402: 1},
        "battle": 1,
    },
    {
        "scene": "prologue_mom",
        "label": "妈妈 · 未选御三家（flag 2402=0）",
        "zone": 390,
        "npc": 0,
        "flags": {2402: 0},
        "battle": 1,
    },
    {
        "scene": "prologue_juniper_pokedex",
        "label": "研究所 · 图鉴事件",
        "zone": 396,
        "scriptId": 1,
        "entry": 0x0119,
        "flags": {2402: 1},
        "battle": 1,
    },
]


def normalize(text: str) -> str:
    text = text.replace("—", "-").replace("’", "'")
    return re.sub(r"\s+", " ", text).strip().lower()


def zone_script(rom: NintendoDSRom, zone: int) -> tuple[bytes, list[int], list[str]]:
    _fat, scripts = detect_script_archive(rom)
    _tfat, texts = detect_text_archive(rom)
    _hfat, headers = detect_zone_header_archive(rom, zone + 1, len(scripts.files), len(texts.files))
    header = ZONE_HEADER.unpack_from(headers, zone * ZONE_HEADER.size)
    data = scripts.files[header[4]]
    return data, read_script_table(data), decrypt_text_sections(texts.files[header[6]])


def npc_script(zone: int, npc: int) -> int:
    entities = json.loads((ROOT / "server" / "content" / "rom" / "zone_entities.json").read_text(encoding="utf-8"))
    for entry in entities["zones"]:
        if entry["id"] == zone:
            for item in entry["npcs"]:
                if item["id"] == npc:
                    return int(item["script"])
    raise SystemExit(f"no NPC {npc} in zone {zone}")


def rom_messages(rom: NintendoDSRom, scenario: dict) -> tuple[list[dict], str]:
    zone = scenario["zone"]
    data, offsets, sections = zone_script(rom, zone)
    script_id = scenario.get("scriptId") or npc_script(zone, scenario["npc"])
    table_start = offsets[script_id - 1]
    end = min([offset for offset in offsets if offset > table_start] + [len(data)])
    if "entry" in scenario:
        start = scenario["entry"]
    else:
        start, _how = resolve_entry(
            data, table_start, end, {}, scenario.get("battle", 1), scenario.get("flags", {})
        )

    events: list[dict] = []
    run = run_script(
        data,
        start,
        end,
        scenario.get("flags", {}),
        trace=events,
        battle_result=scenario.get("battle", 1),
    )
    messages = []
    for event in events:
        if event["event"] != "text" or event.get("file") != SCRIPT_MSG_FILE:
            continue
        message_id = event["id"]
        if not 0 <= message_id < len(sections):
            continue
        raw = sections[message_id]
        speaker = infer_speaker(raw)
        messages.append(
            {
                "id": message_id,
                "speaker": speaker,
                "pages": format_pages(raw, speaker),
            }
        )
    stopped = ""
    if run.unknown:
        stopped = "未识别指令 " + ", ".join(hex(op) for op in sorted(run.unknown))
    return messages, stopped


def story_units(scene: dict, battle: int) -> list[dict]:
    """Group a scene into dialogue boxes: one unit per say step, battle, prompt."""
    units: list[dict] = []
    for index, step in enumerate(scene["steps"]):
        kind = step["type"]
        if kind == "say":
            when = step.get("when", {})
            if "8010" in when and when["8010"] != battle:
                continue
            units.append(
                {
                    "step": index,
                    "kind": "say",
                    "speaker": step.get("speaker", ""),
                    "text": "\n".join(step["lines"]),
                }
            )
        elif kind == "notice":
            units.append({"step": index, "kind": "notice", "speaker": "", "text": step["text"]})
        elif kind == "battle":
            key = "win" if battle else "lose"
            units.append(
                {
                    "step": index,
                    "kind": "battle-" + key,
                    "speaker": step.get("speaker", ""),
                    "text": "\n".join(step.get(key, [])),
                }
            )
        elif kind == "chooseStarter":
            if step.get("prompt"):
                units.append({"step": index, "kind": "prompt", "speaker": "", "text": "\n".join(step["prompt"])})
            for option in step.get("options", []):
                if option.get("lines"):
                    units.append(
                        {
                            "step": index,
                            "kind": "option:" + option["id"],
                            "speaker": "",
                            "text": "\n".join(option["lines"]),
                        }
                    )
    return [unit for unit in units if unit["text"].strip()]


def compare(rom_messages: list[dict], story: list[dict]) -> dict:
    rom_texts = ["\n".join(message["pages"]) for message in rom_messages]
    story_texts = [line["text"] for line in story]
    matcher = difflib.SequenceMatcher(
        None, [normalize(text) for text in rom_texts], [normalize(text) for text in story_texts], autojunk=False
    )

    pairs: list[dict] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            for offset in range(i2 - i1):
                pairs.append(
                    {
                        "status": "same",
                        "rom": rom_texts[i1 + offset],
                        "romId": rom_messages[i1 + offset]["id"],
                        "story": story_texts[j1 + offset],
                        "storyStep": story[j1 + offset]["step"],
                    }
                )
            continue
        rom_slice = list(range(i1, i2))
        story_slice = list(range(j1, j2))
        used: set[int] = set()
        # Pair near-identical lines first: same wording, different pagination.
        scored = []
        for ri in rom_slice:
            for sj in story_slice:
                ratio = difflib.SequenceMatcher(
                    None, normalize(rom_texts[ri]), normalize(story_texts[sj]), autojunk=False
                ).ratio()
                scored.append((ratio, ri, sj))
        for ratio, ri, sj in sorted(scored, reverse=True):
            if ratio < 0.85 or ri in used or sj in used:
                continue
            used.add(ri)
            used.add(sj)
            pairs.append(
                {
                    "status": "repaged",
                    "ratio": round(ratio, 3),
                    "rom": rom_texts[ri],
                    "romId": rom_messages[ri]["id"],
                    "story": story_texts[sj],
                    "storyStep": story[sj]["step"],
                }
            )
        for ri in rom_slice:
            if ri not in used:
                pairs.append({"status": "rom-only", "rom": rom_texts[ri], "romId": rom_messages[ri]["id"]})
        for sj in story_slice:
            if sj not in used:
                pairs.append(
                    {
                        "status": "story-only",
                        "story": story_texts[sj],
                        "storyStep": story[sj]["step"],
                        "kind": story[sj]["kind"],
                    }
                )
    return {
        "same": sum(1 for pair in pairs if pair["status"] == "same"),
        "repaged": sum(1 for pair in pairs if pair["status"] == "repaged"),
        "romOnly": sum(1 for pair in pairs if pair["status"] == "rom-only"),
        "storyOnly": sum(1 for pair in pairs if pair["status"] == "story-only"),
        "pairs": pairs,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rom", help="path to the .nds ROM")
    parser.add_argument("--story", default=str(STORY))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    rom = NintendoDSRom.open(locate_rom(ROOT, args.rom or "."))
    story = json.loads(Path(args.story).read_text(encoding="utf-8"))

    report = []
    for scenario in SCENARIOS:
        scene = story["scenes"][scenario["scene"]]
        messages, stopped = rom_messages(rom, scenario)
        lines = story_units(scene, scenario["battle"])
        result = compare(messages, lines)
        report.append(
            {
                "scene": scenario["scene"],
                "label": scenario["label"],
                "romMessages": len(messages),
                "storyLines": len(lines),
                "stopped": stopped,
                **result,
            }
        )

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    for item in report:
        print(f"## {item['label']} — `{item['scene']}`")
        print()
        print(
            f"ROM {item['romMessages']} 条消息 / 剧情 {item['storyLines']} 段 · "
            f"完全一致 {item['same']}，分页不同 {item['repaged']}，ROM 独有 {item['romOnly']}，剧情独有 {item['storyOnly']}"
        )
        if item["stopped"]:
            print(f"\n> 轨迹在 `{item['stopped']}` 处中断，后面的台词没有回放到。")
        print()
        for pair in item["pairs"]:
            if pair["status"] == "same":
                continue
            if pair["status"] == "repaged":
                print(f"- 分页不同（相似度 {pair['ratio']}）")
                print(f"  - ROM #{pair['romId']}: {' / '.join(pair['rom'].splitlines())}")
                print(f"  - 剧情 step {pair['storyStep']}: {' / '.join(pair['story'].splitlines())}")
            elif pair["status"] == "rom-only":
                print(f"- ROM 独有 #{pair['romId']}: {' / '.join(pair['rom'].splitlines())}")
            else:
                print(f"- 剧情独有（step {pair['storyStep']}, {pair['kind']}）: {' / '.join(pair['story'].splitlines())}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
