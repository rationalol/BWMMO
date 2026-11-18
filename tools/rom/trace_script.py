#!/usr/bin/env python3
"""Dump an execution trace of a field script from the BW ROM.

The story layer is hand-authored JSON; the ROM is the oracle. This tool runs a
single ROM script with a deterministic starting state and prints every event the
script would produce: which text ids it asks for, which flags and work values it
writes, which trainer it sets up, when the battle starts and how it ends.

The extractor's VM already executes control flow. Here we add the three battle
opcodes (0x85 set trainer, 0x8E battle, 0x8D store result) and a trace sink, and
we drive the run twice when a battle can be won or lost, because the ROM stores
the outcome in a work variable and branches on it afterwards.

Examples:
    # Everything the bedroom opening does when the player picked Tepig (work
    # 0x4030 = 0) and won both battles.
    python3 tools/rom/trace_script.py --zone 391 --npc 2 \
        --work 0x4030=0 --battle 1

    # Both outcomes, as JSON, ready for diffing against a scene.
    python3 tools/rom/trace_script.py --zone 391 --npc 2 \
        --work 0x4030=0 --battle both --json

    # What is in script file 782?
    python3 tools/rom/trace_script.py --script-file 782 --list
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from extract_dialogues import (
    SCRIPT_MSG_FILE,
    detect_text_archive,
    format_pages,
    infer_speaker,
    locate_rom,
    read_script_table,
    decrypt_text_sections,
    run_script,
)
from nds_fs import (
    ZONE_HEADER,
    NintendoDSRom,
    detect_script_archive,
    detect_zone_header_archive,
)

DEFAULT_ENTITIES = Path(__file__).resolve().parents[2] / "server" / "content" / "rom" / "zone_entities.json"


def parse_value(text: str) -> int:
    return int(text, 0)


def parse_assignments(pairs: list[str]) -> dict[int, int]:
    result: dict[int, int] = {}
    for pair in pairs:
        if "=" not in pair:
            raise SystemExit(f"--work expects VAR=VALUE, got {pair!r}")
        name, value = pair.split("=", 1)
        result[parse_value(name)] = parse_value(value)
    return result


def zone_files(rom: NintendoDSRom, zone: int) -> tuple[int, int, list[bytes]]:
    """Return (script file id, text file id, text sections) for a zone."""
    _script_fat, scripts = detect_script_archive(rom)
    _text_fat, texts = detect_text_archive(rom)
    _header_fat, headers = detect_zone_header_archive(
        rom, zone + 1, len(scripts.files), len(texts.files)
    )
    header = ZONE_HEADER.unpack_from(headers, zone * ZONE_HEADER.size)
    script_file, text_file = header[4], header[6]
    if script_file >= len(scripts.files) or text_file >= len(texts.files):
        raise SystemExit(
            f"zone {zone} points at script file {script_file} / text file {text_file}, "
            f"outside the archives ({len(scripts.files)} / {len(texts.files)})"
        )
    return script_file, text_file, decrypt_text_sections(texts.files[text_file])


def script_id_for_npc(zone: int, npc: int, entities_path: Path) -> int:
    data = json.loads(entities_path.read_text(encoding="utf-8"))
    for entry in data.get("zones", []):
        if entry.get("id") != zone:
            continue
        for item in entry.get("npcs", []):
            if item.get("id") == npc:
                return int(item["script"])
    raise SystemExit(f"zone {zone} has no NPC {npc} in {entities_path}")


def script_end(offsets: list[int], start: int, length: int) -> int:
    return min([offset for offset in offsets if offset > start] + [length])


def execute(
    data: bytes,
    start: int,
    end: int,
    work: dict[int, int],
    battle_result: int,
    flags: dict[int, int] | None = None,
):
    events: list[dict] = []
    run = run_script(
        data,
        start,
        end,
        flags or {},
        trace=events,
        battle_result=battle_result,
        initial_work=work,
    )
    return run, events


def ends_cleanly(events: list[dict]) -> bool:
    """True when the run stopped for a reason the script itself chose.

    Falling off the end of the entry's range counts as clean: some scripts are
    laid out so the last instruction simply runs into the next table offset.
    Unknown opcodes, a truncated read and the step budget do not count.
    """
    if not events:
        return True
    last = events[-1]
    if last["event"] != "end":
        return True
    return last.get("reason") not in ("unknown", "budget", "invalid-pc")


def resolve_entry(
    data: bytes,
    start: int,
    end: int,
    work: dict[int, int],
    battle_result: int,
    flags: dict[int, int] | None = None,
) -> tuple[int, str]:
    """Return (entry point, how it was found).

    The table entry is not always executable: some script files put a preamble
    the VM does not decode in front of the first instruction, so the offset
    points a few dozen bytes early. When the entry does not run cleanly we scan
    the entry's own range for the start that yields the most dialogue with no
    unknown opcodes.
    """
    try:
        run, events = execute(data, start, end, work, battle_result, flags)
    except Exception:
        run, events = None, []
    if run and run.messages and not run.unknown and ends_cleanly(events):
        return start, "table"

    best: tuple[tuple[int, int], int] | None = None
    for candidate in range(start + 2, end - 2, 2):
        try:
            probe, probe_events = execute(data, candidate, end, work, battle_result, flags)
        except Exception:
            continue
        if not probe.messages or probe.unknown or not ends_cleanly(probe_events):
            continue
        score = (len(probe.messages), -candidate)
        if best is None or score > best[0]:
            best = (score, candidate)
    if best is None:
        return start, "fallback"
    return best[1], "scanned"


def render(events: list[dict], sections: list[str]) -> list[dict]:
    """Attach speaker and pages to text events."""
    for event in events:
        if event["event"] != "text":
            continue
        message_id = event.get("id")
        if event.get("file") != SCRIPT_MSG_FILE or not isinstance(message_id, int):
            continue
        if 0 <= message_id < len(sections):
            raw = sections[message_id]
            speaker = infer_speaker(raw)
            event["speaker"] = speaker
            event["pages"] = format_pages(raw, speaker)
    return events


def format_event(index: int, event: dict) -> str:
    kind = event["event"]
    if kind == "text":
        pages = event.get("pages") or []
        text = " / ".join(pages) if pages else f"<text {event.get('id')}>"
        return f"[{index:3d}] text   id={event.get('id'):<4} {event.get('speaker') or '?'}: {text}"
    if kind == "trainer":
        return f"[{index:3d}] train  id={event.get('trainer')} params={event.get('params')}"
    if kind == "battle":
        return f"[{index:3d}] battle start"
    if kind == "battle_result":
        return f"[{index:3d}] result work 0x{event.get('var', 0):04x} = {event.get('value')}"
    if kind == "flag":
        return f"[{index:3d}] flag   0x{event.get('flag', 0):04x} = {event.get('value')}"
    if kind == "work":
        return f"[{index:3d}] work   0x{event.get('var', 0):04x} = {event.get('value')}"
    if kind == "end":
        reason = event.get("reason")
        extra = f" op=0x{event['op']:x}" if "op" in event else ""
        return f"[{index:3d}] end    {reason}{extra}"
    return f"[{index:3d}] {kind} {event}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rom", help="path to the .nds ROM (default: first one in the project root)")
    parser.add_argument("--zone", type=int, help="zone id; resolves the script and text file from the zone header")
    parser.add_argument("--npc", type=int, help="NPC id inside the zone; resolves the script id from zone_entities.json")
    parser.add_argument("--entities", default=str(DEFAULT_ENTITIES), help="zone_entities.json for --npc")
    parser.add_argument("--script-id", type=int, help="1-based script index (the value stored on the NPC)")
    parser.add_argument("--script-file", type=int, help="script file id, when not using --zone")
    parser.add_argument("--text-file", type=int, help="text file id, when not using --zone")
    parser.add_argument("--work", action="append", default=[], metavar="VAR=VALUE",
                        help="initial work value, e.g. --work 0x4030=0 (repeatable)")
    parser.add_argument("--flag", action="append", default=[], metavar="ID=VALUE",
                        help="initial story flag, e.g. --flag 2402=1 (repeatable)")
    parser.add_argument("--battle", choices=["1", "0", "both"], default="1",
                        help="battle outcome to inject at 0x8D (default: 1, win)")
    parser.add_argument("--entry", type=parse_value,
                        help="force the entry offset instead of resolving it from the table")
    parser.add_argument("--list", action="store_true", help="list the scripts in the file and exit")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    parser.add_argument("--out", help="write output to this file instead of stdout")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = locate_rom(root, args.rom or ".")
    rom = NintendoDSRom.open(rom_path)

    script_file = args.script_file
    text_file = args.text_file
    sections: list[str] = []
    if args.zone is not None:
        script_file, text_file, sections = zone_files(rom, args.zone)
    elif script_file is None:
        raise SystemExit("give --zone or --script-file")

    _script_fat, scripts = detect_script_archive(rom)
    if script_file >= len(scripts.files):
        raise SystemExit(f"script file {script_file} outside the archive ({len(scripts.files)} files)")
    data = scripts.files[script_file]

    if sections == [] and text_file is not None:
        _text_fat, texts = detect_text_archive(rom)
        sections = decrypt_text_sections(texts.files[text_file])

    offsets = read_script_table(data)
    if not offsets:
        raise SystemExit(f"script file {script_file} has no offset table")

    initial_work = parse_assignments(args.work)
    initial_flags = parse_assignments(args.flag)

    if args.list:
        rows = []
        for index, start in enumerate(offsets, start=1):
            end = script_end(offsets, start, len(data))
            entry, _how = resolve_entry(data, start, end, initial_work, 1, initial_flags)
            run, _events = execute(data, entry, end, initial_work, 1, initial_flags)
            first = ""
            if run.messages:
                message_id = run.messages[0]
                if 0 <= message_id < len(sections):
                    first = format_pages(sections[message_id], infer_speaker(sections[message_id]))[0]
            rows.append((index, entry, end - start, len(run.messages), first))
        if args.json:
            payload = [
                {"scriptId": index, "start": start, "size": size, "messages": count, "first": first}
                for index, start, size, count, first in rows
            ]
            print(json.dumps(payload, indent=2, ensure_ascii=False))
        else:
            for index, start, size, count, first in rows:
                print(f"{index:3d}  start=0x{start:04x} size={size:5d} messages={count:3d}  {first[:70]}")
        return 0

    script_id = args.script_id
    if script_id is None and args.npc is not None and args.zone is not None:
        script_id = script_id_for_npc(args.zone, args.npc, Path(args.entities))
    if script_id is None:
        raise SystemExit("give --script-id or --zone with --npc")
    if not 1 <= script_id <= len(offsets):
        raise SystemExit(f"script id {script_id} outside the table (1..{len(offsets)})")

    table_start = offsets[script_id - 1]
    end = script_end(offsets, table_start, len(data))
    results = [1, 0] if args.battle == "both" else [int(args.battle)]

    if args.entry is not None:
        start, how = args.entry, "forced"
    else:
        start, how = resolve_entry(data, table_start, end, initial_work, results[0], initial_flags)

    runs = []
    for battle_result in results:
        run, events = execute(data, start, end, initial_work, battle_result, initial_flags)
        render(events, sections)
        runs.append(
            {
                "battleResult": battle_result,
                "messages": len(run.messages),
                "setFlags": sorted(run.set_flags),
                "unknown": [hex(op) for op in sorted(run.unknown)],
                "steps": run.steps,
                "events": events,
            }
        )

    payload = {
        "rom": str(rom_path),
        "zone": args.zone,
        "scriptFile": script_file,
        "textFile": text_file,
        "scriptId": script_id,
        "tableStart": table_start,
        "start": start,
        "entry": how,
        "end": end,
        "initialWork": {f"0x{var:04x}": value for var, value in initial_work.items()},
        "initialFlags": {str(flag): value for flag, value in initial_flags.items()},
        "runs": runs,
    }

    if args.json:
        output = json.dumps(payload, indent=2, ensure_ascii=False)
    else:
        lines = [
            f"zone={args.zone} scriptFile={script_file} textFile={text_file} "
            f"scriptId={script_id} entry=0x{start:04x} ({how}) range=0x{table_start:04x}..0x{end:04x}"
        ]
        for run in runs:
            lines.append("")
            lines.append(
                f"== battle result = {run['battleResult']} "
                f"({run['messages']} messages, flags {[hex(f) for f in run['setFlags']]}) =="
            )
            for index, event in enumerate(run["events"]):
                lines.append(format_event(index, event))
        output = "\n".join(lines)

    if args.out:
        Path(args.out).write_text(output + "\n", encoding="utf-8")
        print(f"Wrote {args.out}")
    else:
        print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
