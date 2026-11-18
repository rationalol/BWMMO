#!/usr/bin/env python3
"""Compile a ROM field script into our story-step JSON.

This is the small end of a ROM -> StoryContent compiler. It replays one script
twice — once with the battle won, once lost — lines the two event streams up,
and turns them into `say`, `setFlag` and `battle` steps. Anything that differs
between the two runs is emitted as a step guarded by the battle's result flag,
which is exactly how `server/src/game/story.ts` reads `when`.

What it does NOT do (yet): choosing a starter (a menu, not a script), map
placement, triggers and NPC registration. Trainer parties come from
`server/content/rom/trainers.json` when `extract_trainers.py` has been run; the
output is a scene fragment meant to be reviewed and merged by hand, not dropped
into `content/story/` as-is.

    python3 tools/rom/compile_story.py --out server/content/rom/rom_prologue.json
    python3 tools/rom/compile_story.py --json | jq .scenes

    # Every dialogue script of every zone, one JSON per zone plus an index.
    python3 tools/rom/compile_story.py --bulk
    python3 tools/rom/compile_story.py --bulk --zones 390,391,396 --out-dir /tmp/bulk
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
import time
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
from trace_script import resolve_entry, script_end

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "server" / "content" / "rom" / "rom_prologue.json"
TRAINERS_PATH = ROOT / "server" / "content" / "rom" / "trainers.json"

_TRAINER_CACHE: dict[int, dict] | None = None


def trainer_table() -> dict[int, dict]:
    """Optional trainer id -> party table, produced by extract_trainers.py."""
    global _TRAINER_CACHE
    if _TRAINER_CACHE is None:
        if TRAINERS_PATH.exists():
            raw = json.loads(TRAINERS_PATH.read_text(encoding="utf-8")).get("trainers", {})
            _TRAINER_CACHE = {int(key): value for key, value in raw.items()}
        else:
            _TRAINER_CACHE = {}
    return _TRAINER_CACHE

# One scene per entry point. `entry` pins the instruction offset when the
# script table points at the preamble; `flags` reproduce the game state the
# script is reached in.
SOURCES = [
    {
        "id": "rom_prologue_bedroom_intro",
        "label": "卧室开场（区域 391 · npc 2）",
        "zone": 391,
        "npc": 2,
        "flags": {},
    },
    {
        "id": "rom_prologue_mom",
        "label": "妈妈（区域 390 · npc 0 · 已选御三家）",
        "zone": 390,
        "npc": 0,
        "flags": {2402: 1},
    },
    {
        "id": "rom_prologue_juniper_pokedex",
        "label": "研究所图鉴（区域 396 · script 1）",
        "zone": 396,
        "scriptId": 1,
        "entry": 0x0119,
        "flags": {2402: 1},
    },
]


def npc_script(zone: int, npc: int) -> int:
    entities = json.loads((ROOT / "server" / "content" / "rom" / "zone_entities.json").read_text(encoding="utf-8"))
    for entry in entities["zones"]:
        if entry["id"] == zone:
            for item in entry["npcs"]:
                if item["id"] == npc:
                    return int(item["script"])
    raise SystemExit(f"no NPC {npc} in zone {zone}")


_ZONE_CACHE: dict[int, tuple[bytes, list[int], list[str]]] = {}
_ARCHIVE_CACHE: dict[str, object] = {}


def archives(rom: NintendoDSRom):
    """Detect the three archives once; detection scans every NARC in the ROM."""
    if not _ARCHIVE_CACHE:
        _fat, scripts = detect_script_archive(rom)
        _tfat, texts = detect_text_archive(rom)
        _hfat, headers = detect_zone_header_archive(rom, 427, len(scripts.files), len(texts.files))
        _ARCHIVE_CACHE.update(scripts=scripts, texts=texts, headers=headers)
    return _ARCHIVE_CACHE["scripts"], _ARCHIVE_CACHE["texts"], _ARCHIVE_CACHE["headers"]


def load_zone(rom: NintendoDSRom, zone: int):
    if zone not in _ZONE_CACHE:
        scripts, texts, headers = archives(rom)
        header = ZONE_HEADER.unpack_from(headers, zone * ZONE_HEADER.size)
        data = scripts.files[header[4]]
        _ZONE_CACHE[zone] = (data, read_script_table(data), decrypt_text_sections(texts.files[header[6]]))
    return _ZONE_CACHE[zone]


def locate_entry(
    rom: NintendoDSRom, source: dict
) -> tuple[bytes, list[int], list[str], int, int, int, int, str]:
    """Find the executable entry once; every replay of the scene reuses it."""
    data, offsets, sections = load_zone(rom, source["zone"])
    script_id = source.get("scriptId") or npc_script(source["zone"], source["npc"])
    table_start = offsets[script_id - 1]
    end = script_end(offsets, table_start, len(data))
    if "entry" in source:
        start, how = source["entry"], "forced"
    else:
        start, how = resolve_entry(data, table_start, end, {}, 1, source.get("flags", {}))
    return data, offsets, sections, script_id, table_start, end, start, how


def run_at(
    data: bytes,
    sections: list[str],
    start: int,
    end: int,
    flags: dict[int, int],
    battle: int,
) -> dict:
    """Replay one entry point and attach speaker/pages to its text events."""
    events: list[dict] = []
    run = run_script(data, start, end, flags, trace=events, battle_result=battle)
    for event in events:
        if event["event"] != "text" or event.get("file") != SCRIPT_MSG_FILE:
            continue
        message_id = event["id"]
        if 0 <= message_id < len(sections):
            raw = sections[message_id]
            speaker = infer_speaker(raw)
            event["speaker"] = speaker
            event["pages"] = format_pages(raw, speaker)
    return {
        "start": start,
        "events": events,
        "unknown": sorted(run.unknown),
        "messages": len(run.messages),
    }


def run_case(rom: NintendoDSRom, source: dict, battle: int, entry: tuple | None = None) -> dict:
    data, offsets, sections, script_id, table_start, end, start, how = entry or locate_entry(rom, source)
    result = run_at(data, sections, start, end, source.get("flags", {}), battle)
    result.update({"how": how, "range": (table_start, end)})
    return result


def signature(event: dict) -> tuple:
    kind = event["event"]
    if kind == "battle_result":
        return ("battle_result", event["var"])
    if kind == "text":
        return ("text", event.get("id"), event.get("speaker"), tuple(event.get("pages") or ()))
    if kind == "flag":
        return ("flag", event["flag"], event["value"])
    if kind == "work":
        return ("work", event["var"], event["value"])
    if kind == "trainer":
        return ("trainer", event["trainer"], tuple(event.get("params") or ()))
    return (kind,)


class Emitter:
    def __init__(self) -> None:
        self.steps: list[dict] = []
        self.warnings: list[str] = []
        self.trainers: dict[str, dict] = {}
        self.last_trainer: int | None = None
        self.last_params: list[int] = []

    def push(self, step: dict) -> None:
        if step["type"] == "say" and not step["lines"]:
            return
        self.steps.append(step)

    def emit(self, event: dict, when: dict | None, next_result_var: int | None) -> None:
        kind = event["event"]
        if kind == "text":
            step = {"type": "say", "speaker": event.get("speaker") or "", "lines": list(event.get("pages") or [])}
            if when:
                step["when"] = dict(when)
            self.push(step)
        elif kind == "flag":
            step = {"type": "setFlag", "flag": str(event["flag"]), "value": event["value"]}
            if when:
                step["when"] = dict(when)
            self.push(step)
        elif kind == "trainer":
            self.last_trainer = event["trainer"]
            self.last_params = list(event.get("params") or [])
        elif kind == "battle":
            trainer = self.last_trainer
            if trainer is None:
                self.warnings.append("battle without a preceding trainer event")
                trainer = 0
            trainer_id = f"rom_{trainer}"
            definition = trainer_table().get(trainer)
            party = []
            if definition:
                party = [
                    {"species": member["species"], "level": member["level"]}
                    for member in definition.get("party", [])
                ]
            if not party:
                self.warnings.append(f"trainer {trainer} has no party data")
            if trainer_id not in self.trainers:
                entry = {
                    "name": f"ROM trainer {trainer}",
                    "sprite": 0,
                    "party": party,
                    "romParams": self.last_params,
                }
                if definition:
                    entry["romClass"] = definition.get("class")
                    entry["romBattleType"] = definition.get("battleType")
                self.trainers[trainer_id] = entry
            step = {"type": "battle", "trainer": trainer_id}
            if next_result_var is not None:
                step["resultFlag"] = f"{next_result_var:x}"
            self.push(step)
        elif kind == "battle_result":
            return
        elif kind == "work":
            # Engine bookkeeping (scratch vars, exit codes), not story state.
            return
        elif kind == "end":
            return

    def group(self) -> list[dict]:
        merged: list[dict] = []
        for step in self.steps:
            previous = merged[-1] if merged else None
            if (
                previous
                and step["type"] == "say"
                and previous["type"] == "say"
                and previous.get("speaker") == step.get("speaker")
                and previous.get("when") == step.get("when")
                and "when" not in step
            ):
                previous["lines"].extend(step["lines"])
                continue
            merged.append(step)
        return merged


def normalize_battle_order(events: list[dict]) -> list[dict]:
    """Some scripts store the result (0x8D) before the battle (0x8E).

    The result is only meaningful once the battle has run, and the flags the
    script sets between the two are the post-battle branch. Move the battle
    ahead of its result so the compiled scene fights first and branches after,
    which is what `battle` + `when` means in our engine.
    """
    out: list[dict] = []
    index = 0
    while index < len(events):
        event = events[index]
        if event["event"] == "battle_result":
            cursor = index + 1
            while cursor < len(events) and events[cursor]["event"] in ("work", "flag"):
                cursor += 1
            if cursor < len(events) and events[cursor]["event"] == "battle":
                out.append(events[cursor])
                out.extend(events[index:cursor])
                index = cursor + 1
                continue
        out.append(event)
        index += 1
    return out


def compile_events(win: dict, lose: dict) -> tuple[list[dict], dict[str, dict], list[str]]:
    """Merge the win and lose event streams into story steps."""
    emitter = Emitter()
    warnings: list[str] = []

    a, b = normalize_battle_order(win["events"]), normalize_battle_order(lose["events"])
    matcher = difflib.SequenceMatcher(None, [signature(e) for e in a], [signature(e) for e in b], autojunk=False)

    # (result var, win value, lose value) of the most recent battle.
    current: tuple[int, int, int] | None = None

    def next_result(events: list[dict], start: int) -> int | None:
        for event in events[start:]:
            if event["event"] == "battle_result":
                return event["var"]
        return None

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            for offset in range(i2 - i1):
                index = i1 + offset
                event = a[index]
                if event["event"] == "battle_result":
                    current = (event["var"], a[index].get("value"), b[j1 + offset].get("value"))
                    continue
                emitter.emit(event, None, next_result(a, index))
            continue

        win_when = lose_when = None
        if current is not None and current[1] != current[2]:
            win_when = {f"{current[0]:x}": current[1]}
            lose_when = {f"{current[0]:x}": current[2]}
        elif current is None:
            warnings.append(f"divergence before any battle: {tag}")

        for index in range(i1, i2):
            if a[index]["event"] == "battle_result":
                continue
            emitter.emit(a[index], win_when, next_result(a, index))
        for index in range(j1, j2):
            if b[index]["event"] == "battle_result":
                continue
            emitter.emit(b[index], lose_when, next_result(b, index))

    steps = emitter.group()
    warnings.extend(emitter.warnings)
    if win["unknown"]:
        warnings.append("win run stopped at unknown opcodes " + ", ".join(hex(op) for op in win["unknown"]))
    if lose["unknown"]:
        warnings.append("lose run stopped at unknown opcodes " + ", ".join(hex(op) for op in lose["unknown"]))

    return steps, emitter.trainers, warnings


def compile_scene(rom: NintendoDSRom, source: dict, entry: tuple) -> tuple[dict, dict, dict]:
    win = run_case(rom, source, 1, entry)
    lose = run_case(rom, source, 0, entry)
    steps, trainers, warnings = compile_events(win, lose)
    scene = {
        "id": source["id"],
        "label": source["label"],
        "steps": steps,
        "trainers": trainers,
        "source": {
            "zone": source["zone"],
            "scriptId": entry[3],
            "entry": f"0x{win['start']:04x}",
            "entryResolved": win["how"],
            "flags": {str(flag): value for flag, value in source.get("flags", {}).items()},
            "range": [f"0x{win['range'][0]:04x}", f"0x{win['range'][1]:04x}"],
        },
        "warnings": warnings,
    }
    return scene, win, lose


def render_steps(steps: list[dict], battle: int) -> list[str]:
    """Flatten a compiled scene the way the engine would play it.

    The compiler only guards steps on the battle result flag, so replaying a
    scene is just "keep the says whose `when` matches this outcome".
    """
    lines: list[str] = []
    for step in steps:
        if step["type"] != "say":
            continue
        if "when" in step and any(value != battle for value in step["when"].values()):
            continue
        lines.extend(step["lines"])
    return lines


def verify_scene(steps: list[dict], win: dict, lose: dict) -> dict:
    """Check that replaying the compiled steps reproduces the ROM dialogue."""
    out = {}
    for result, run in ((1, win), (0, lose)):
        expected = [page for event in run["events"] if event["event"] == "text" for page in (event.get("pages") or [])]
        actual = render_steps(steps, result)
        out[result] = {
            "expected": len(expected),
            "actual": len(actual),
            "match": [normalize(line) for line in expected] == [normalize(line) for line in actual],
        }
    return out


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


BULK_OUT = ROOT / "server" / "content" / "rom" / "story_bulk"
_ENTITIES: dict | None = None


def entities() -> dict:
    global _ENTITIES
    if _ENTITIES is None:
        _ENTITIES = json.loads((ROOT / "server" / "content" / "rom" / "zone_entities.json").read_text(encoding="utf-8"))
    return _ENTITIES


def zone_script_files(rom: NintendoDSRom) -> dict[int, tuple[int, int]]:
    """Map every zone id that has a script file to (scriptFile, textFile)."""
    zones = entities()["zones"]
    scripts, texts, headers = archives(rom)
    out: dict[int, tuple[int, int]] = {}
    for zone in zones:
        zone_id = zone["id"]
        offset = zone_id * ZONE_HEADER.size
        if offset + ZONE_HEADER.size > len(headers):
            continue
        header = ZONE_HEADER.unpack_from(headers, offset)
        if header[4] < len(scripts.files) and header[6] < len(texts.files) and (header[4] or header[6]):
            out[zone_id] = (header[4], header[6])
    return out


def entry_override(zone: int, script_id: int) -> int | None:
    """Entries pinned in SOURCES win over scanning (e.g. scripts with 0x9F)."""
    for source in SOURCES:
        if source["zone"] == zone and source.get("scriptId") == script_id:
            return source.get("entry")
    return None


def bulk_zone(rom: NintendoDSRom, zone: int, script_file: int, text_file: int) -> dict:
    """Compile every dialogue-bearing entry of one zone's script file."""
    data, offsets, sections = load_zone(rom, zone)
    scenes: dict[str, dict] = {}
    trainers: dict[str, dict] = {}
    warnings: list[str] = []
    issues: dict[str, list] = {"fallback": [], "blocked": []}
    stats = {
        "entries": len(offsets),
        "scenes": 0,
        "lines": 0,
        "skipped": 0,
        "fallback": 0,
        "blocked": 0,
        "mismatch": 0,
        "scanned": 0,
    }

    for script_id, table_start in enumerate(offsets, 1):
        end = script_end(offsets, table_start, len(data))
        if end <= table_start + 1:
            continue
        chunk = data[table_start:end]
        if not (b"\x3d\x00" in chunk or b"\x3c\x00" in chunk or b"\x8e\x00" in chunk):
            stats["skipped"] += 1
            continue

        override = entry_override(zone, script_id)
        if override is not None:
            start, how = override, "forced"
        else:
            start, how = resolve_entry(data, table_start, end, {}, 1, {})
        if how == "scanned":
            stats["scanned"] += 1
        win = run_at(data, sections, start, end, {}, 1)
        has_battle = any(event["event"] == "battle" for event in win["events"])
        lose = run_at(data, sections, start, end, {}, 0) if has_battle else win

        steps, scene_trainers, scene_warnings = compile_events(win, lose)
        if not any(step["type"] in ("say", "battle") for step in steps):
            stats["skipped"] += 1
            continue

        checks = verify_scene(steps, win, lose)
        mismatch = not all(check["match"] for check in checks.values())
        scene_id = f"rom_z{zone}_s{script_id}"
        if mismatch:
            stats["mismatch"] += 1
            scene_warnings.append("round-trip mismatch: compiled steps do not reproduce the trace")
        if how == "fallback":
            stats["fallback"] += 1
            issues["fallback"].append(script_id)
            scene_warnings.append("entry could not be resolved; dialogue may be incomplete")
        if win["unknown"] or lose["unknown"]:
            stats["blocked"] += 1
            issues["blocked"].append({"scriptId": script_id, "ops": [hex(op) for op in win["unknown"]]})

        scenes[scene_id] = {
            "id": scene_id,
            "label": f"区域 {zone} 脚本 {script_id}",
            "steps": steps,
            "source": {
                "zone": zone,
                "scriptFile": script_file,
                "scriptId": script_id,
                "entry": f"0x{start:04x}",
                "entryResolved": how,
                "range": [f"0x{table_start:04x}", f"0x{end:04x}"],
            },
            "verify": checks,
            "warnings": scene_warnings,
        }
        trainers.update(scene_trainers)
        warnings.extend(f"{scene_id}: {warning}" for warning in scene_warnings)
        stats["scenes"] += 1
        stats["lines"] += checks[1]["expected"]

    return {
        "zone": zone,
        "scriptFile": script_file,
        "textFile": text_file,
        "scenes": scenes,
        "trainers": trainers,
        "stats": stats,
        "issues": issues,
        "warnings": warnings,
    }


def bulk_main(rom: NintendoDSRom, out_dir: Path, zones: list[int] | None) -> int:
    mapping = zone_script_files(rom)
    targets = sorted(zones if zones is not None else mapping)
    missing = [zone for zone in targets if zone not in mapping]
    if missing:
        print(f"zones without a script file: {missing[:10]}{'...' if len(missing) > 10 else ''}")

    out_dir.mkdir(parents=True, exist_ok=True)
    index: dict[str, dict] = {}
    totals = {"zones": 0, "entries": 0, "scenes": 0, "lines": 0, "fallback": 0, "blocked": 0, "mismatch": 0, "scanned": 0}
    started = time.time()

    for position, zone in enumerate(targets, 1):
        if zone not in mapping:
            continue
        script_file, text_file = mapping[zone]
        payload = bulk_zone(rom, zone, script_file, text_file)
        payload["_generated"] = {"tool": "tools/rom/compile_story.py --bulk", "zone": zone}
        stats = payload["stats"]
        index[str(zone)] = {
            "scriptFile": script_file,
            "textFile": text_file,
            **stats,
            "issues": payload["issues"],
        }
        for key in ("entries", "scenes", "lines", "fallback", "blocked", "mismatch", "scanned"):
            totals[key] += stats[key]
        if payload["scenes"]:
            (out_dir / f"zone_{zone}.json").write_text(
                json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            totals["zones"] += 1
        if position % 50 == 0:
            elapsed = time.time() - started
            print(f"  {position}/{len(targets)} zones, {totals['scenes']} scenes, {round(elapsed)}s", flush=True)

    report = {
        "_generated": {
            "tool": "tools/rom/compile_story.py --bulk",
            "note": "按区域编译的剧情片段：仅 say/setFlag/battle；flag 从默认值（全 0）起跑，"
            "需要特定 flag 才出现的分支需用单场景模式补。",
        },
        "totals": totals,
        "zones": index,
    }
    (out_dir / "_index.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    elapsed = time.time() - started
    print(
        f"{totals['zones']} zones with scenes, {totals['scenes']} scenes, {totals['lines']} lines; "
        f"fallback {totals['fallback']}, blocked {totals['blocked']}, mismatch {totals['mismatch']}, scanned {totals['scanned']}; "
        f"{round(elapsed)}s -> {out_dir}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rom", help="path to the .nds ROM")
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    parser.add_argument("--json", action="store_true", help="print instead of writing")
    parser.add_argument("--bulk", action="store_true", help="compile every dialogue script of every zone")
    parser.add_argument("--zones", help="comma-separated zone ids, with --bulk")
    parser.add_argument("--out-dir", default=str(BULK_OUT), help="output directory for --bulk")
    args = parser.parse_args()

    rom = NintendoDSRom.open(locate_rom(ROOT, args.rom or "."))

    if args.bulk:
        zones = [int(value, 0) for value in args.zones.split(",")] if args.zones else None
        return bulk_main(rom, Path(args.out_dir), zones)

    scenes = {}
    trainers = {}
    warnings: list[str] = []
    for source in SOURCES:
        entry = locate_entry(rom, source)
        scene, win, lose = compile_scene(rom, source, entry)
        checks = verify_scene(scene["steps"], win, lose)
        scene["verify"] = checks
        if not all(checks[result]["match"] for result in checks):
            scene["warnings"].append("round-trip mismatch: compiled steps do not reproduce the trace")
        warnings.extend(f"{scene['id']}: {warning}" for warning in scene["warnings"])
        scenes[scene["id"]] = {key: scene[key] for key in ("id", "label", "steps", "source", "verify", "warnings")}
        trainers.update(scene["trainers"])

    payload = {
        "_generated": {
            "tool": "tools/rom/compile_story.py",
            "note": (
                "ROM 脚本编译出的场景片段：say/setFlag/battle 由回放事件生成，"
                "选择御三家、训练家队伍、地图放置和触发器不在编译范围内。"
            ),
            "sources": [source["id"] for source in SOURCES],
        },
        "scenes": scenes,
        "trainers": trainers,
        "todo": [
            "battle 的 trainer 是 ROM 训练家 id，party 为空：队伍数据在别的档案里，"
            "需要从手写剧情（bianca_*/cheren_*）里挑或者另外抽取。",
            "chooseStarter 是菜单不是脚本，编译器不会生成这一步。",
        ],
        "warnings": warnings,
    }

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for scene in scenes.values():
        totals = sum(checks["expected"] for checks in scene["verify"].values())
        ok = all(checks["match"] for checks in scene["verify"].values())
        print(f"{scene['id']}: {len(scene['steps'])} steps, {totals} ROM lines, round-trip {'ok' if ok else 'MISMATCH'}")
    if warnings:
        print(f"{len(warnings)} warning(s):")
        for warning in warnings:
            print(f"  - {warning}")
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
