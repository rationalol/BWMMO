#!/usr/bin/env python3
"""Extract NPC dialogue from Pokémon BW field scripts and story text.

Inputs:
  a/0/5/7   field script files (offset table + 16-bit command stream)
  a/0/0/3   story text files (encrypted string tables)
  a/0/1/2   zone headers: script file id in field 4, text file id in field 6
  server/content/rom/zone_entities.json  NPC entities and local script ids

Output:
  server/content/rom/npc_dialogues.json

NPC `script` ids are 1-based entries in the zone's script file offset table.
Each NPC script is executed with a small VM using the current story flags.
The default run uses all flags and work values zero (new-game state); variants
are generated for the flags referenced by the script so the server can pick a
branch after story events set those flags.

The opcode width table lives in bw_script_ops.json. It contains only factual
parameter widths derived from public Gen 5 scripting documentation; no tool
source code is included.
"""

from __future__ import annotations

import argparse
import itertools
import json
import re
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom  # noqa: E402

from extract_nuvema import ZONE_HEADER, find_rom, read_narc  # noqa: E402

SCRIPT_TERMINATOR = 0xFD13
SCRIPT_MSG_FILE = 0x400
VAR_START = 0x4000
VAR_END = 0xC000
MAX_STEPS = 3000
MAX_VARIANT_FLAGS = 5
MAX_TEXT_PAGES = 80

COMPARISONS = {
    0: lambda left, right: left < right,
    1: lambda left, right: left == right,
    2: lambda left, right: left > right,
    3: lambda left, right: left <= right,
    4: lambda left, right: left >= right,
    5: lambda left, right: left != right,
    6: lambda left, right: left == 1 or right == 1,
    7: lambda left, right: left == 1 and right == 1
}

CMP_LUT = ((1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1))

SPEAKER_PATTERN = re.compile(r"^([A-Z][A-Za-z0-9' .-]{1,28}):\s+")


def load_op_sizes() -> dict[int, list[int]]:
    path = Path(__file__).with_name("bw_script_ops.json")
    data = json.loads(path.read_text(encoding="utf-8"))
    return {int(op, 16): list(sizes) for op, sizes in data["ops"].items()}


OP_SIZES = load_op_sizes()


def read_script_table(data: bytes) -> list[int]:
    offsets = []
    pos = 0
    while pos + 2 <= len(data) and struct.unpack_from("<H", data, pos)[0] != SCRIPT_TERMINATOR:
        value = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        offsets.append(pos + value)
    return offsets


def decrypt_text_sections(data: bytes) -> list[str]:
    num_blocks, entries_per_block, _, _ = struct.unpack_from("<HHII", data, 0)
    if num_blocks == 0:
        return []
    block_offsets = list(struct.unpack_from(f"<{num_blocks}I", data, 12))
    sections: list[str] = []
    for block_offset in block_offsets:
        entries = []
        cursor = block_offset + 4
        for _ in range(entries_per_block):
            table_offset, char_count, _flags = struct.unpack_from("<IHH", data, cursor)
            cursor += 8
            entries.append((table_offset, char_count))
        for table_offset, char_count in entries:
            if char_count == 0:
                sections.append("")
                continue
            encoded = list(struct.unpack_from(f"<{char_count}H", data, block_offset + table_offset))
            key = encoded[-1] ^ 0xFFFF
            chars: list[int] = []
            while encoded:
                char = encoded.pop() ^ key
                key = ((key >> 3) | (key << 13)) & 0xFFFF
                chars.insert(0, char)
            if chars and chars[0] == 0xF100:
                chars = unpack_9bit(chars[1:])
            sections.append(render_text(chars))
    return sections


def unpack_9bit(chars: list[int]) -> list[int]:
    out: list[int] = []
    container = 0
    bit = 0
    for value in chars:
        container |= value << bit
        bit += 16
        while bit >= 9:
            bit -= 9
            code = container & 0x1FF
            container >>= 9
            out.append(0xFFFF if code == 0x1FF else code)
    return out


def render_text(chars: list[int]) -> str:
    text = ""
    index = 0
    while index < len(chars):
        code = chars[index]
        index += 1
        if code == 0xFFFF:
            break
        if code == 0xFFFE:
            text += "\n"
        elif code == 0xF000:
            if index + 1 >= len(chars):
                break
            kind = chars[index]
            count = chars[index + 1]
            index += 2
            args = chars[index:index + count]
            index += count
            if kind == 0xBE00 and count == 0:
                text += "<F>"
            elif kind == 0xBE01 and count == 0:
                text += "<PAGE>"
            elif kind == 0x0100 and count == 1:
                text += "{name}"
            elif kind == 0x0101 and count == 1:
                text += "{rival}"
            elif kind == 0x0102 and count == 1:
                text += "{nickname}"
            elif kind == 0xFF00:
                pass
            else:
                text += "{}"
        elif code < 20 or code > 0xFF60:
            continue
        else:
            text += chr(code)
    return text


def format_pages(text: str, speaker: str = "") -> list[str]:
    text = text.replace("\r", "\n")
    chunks = re.split(r"<PAGE>|<F>", text)
    pages: list[str] = []
    for chunk in chunks:
        lines = [line.rstrip() for line in chunk.split("\n")]
        cleaned = "\n".join(lines).strip()
        cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
        cleaned = re.sub(r"[ \t]+\n", "\n", cleaned)
        if not cleaned:
            continue
        if pages and cleaned == pages[-1]:
            continue
        if speaker and len(pages) == 0:
            cleaned = strip_speaker(cleaned, speaker)
        pages.append(cleaned)
        if len(pages) >= MAX_TEXT_PAGES:
            break
    return pages


def strip_speaker(text: str, speaker: str) -> str:
    match = SPEAKER_PATTERN.match(text)
    if match and match.group(1) == speaker:
        return text[match.end():].lstrip()
    return text


def infer_speaker(text: str) -> str:
    first = next((line for line in text.split("\n") if line.strip()), "")
    match = SPEAKER_PATTERN.match(first.strip())
    return match.group(1) if match else ""


def compare_result(left: int, right: int) -> int:
    return (left > right) - (left < right)


def read_var(data: bytes, pos: int, work: dict[int, int]) -> int:
    value = struct.unpack_from("<H", data, pos)[0]
    if VAR_START <= value < VAR_END:
        return work.get(value, 0)
    return value


@dataclass
class RunResult:
    messages: list[int] = field(default_factory=list)
    set_flags: set[int] = field(default_factory=set)
    used_flags: set[int] = field(default_factory=set)
    unknown: set[int] = field(default_factory=set)
    steps: int = 0


def run_script(
    data: bytes, start: int, end: int, initial_flags: dict[int, int]
) -> RunResult:
    result = RunResult()
    work: dict[int, int] = {}
    flags = dict(initial_flags)
    stack: list[int] = []
    calls: list[int] = []
    cmp_result = 0
    pc = start

    def read16(pos: int) -> int:
        return struct.unpack_from("<H", data, pos)[0]

    def read32(pos: int) -> int:
        return struct.unpack_from("<i", data, pos)[0]

    def push(value: int) -> None:
        stack.append(value & 0xFFFFFFFF)

    def pop() -> int:
        return stack.pop() if stack else 0

    while start <= pc < end and result.steps < MAX_STEPS:
        result.steps += 1
        op = read16(pc)
        cursor = pc + 2
        sizes = OP_SIZES.get(op)

        if op == 0x02:
            break
        if op in (0x00, 0x01):
            pc = cursor
        elif op == 0x03:
            pc = cursor + 2
        elif op == 0x04:
            offset = read32(cursor)
            cursor += 4
            calls.append(cursor)
            pc = cursor + offset
        elif op == 0x05:
            pc = calls.pop() if calls else end
        elif op == 0x08:
            push(read16(cursor))
            pc = cursor + 2
        elif op == 0x09:
            push(read_var(data, cursor, work))
            pc = cursor + 2
        elif op == 0x0A:
            var = read16(cursor)
            if VAR_START <= var < VAR_END:
                work[var] = pop()
            pc = cursor + 2
        elif op == 0x0B:
            pop()
            pc = cursor
        elif op in (0x0C, 0x0D, 0x0E, 0x0F):
            right = pop()
            left = pop()
            if op == 0x0C:
                push(left + right)
            elif op == 0x0D:
                push(left - right)
            elif op == 0x0E:
                push(left * right)
            else:
                push(left // right if right else 0)
            pc = cursor
        elif op == 0x10:
            flag = read_var(data, cursor, work)
            result.used_flags.add(flag)
            push(1 if flags.get(flag, 0) else 0)
            pc = cursor + 2
        elif op == 0x11:
            comparison = read16(cursor)
            right = pop()
            left = pop()
            fn = COMPARISONS.get(comparison)
            push(1 if fn and fn(left, right) else 0)
            pc = cursor + 2
        elif op in (0x12, 0x13):
            pc = cursor + 4
        elif op in (0x14, 0x17):
            pc = cursor + 2
        elif op in (0x15, 0x18):
            pc = cursor + 5
        elif op == 0x16:
            pc = cursor + 2
        elif op == 0x19:
            left = read_var(data, cursor, work)
            right = read16(cursor + 2)
            cmp_result = compare_result(left, right)
            pc = cursor + 4
        elif op == 0x1A:
            left = read_var(data, cursor, work)
            right = read_var(data, cursor + 2, work)
            cmp_result = compare_result(left, right)
            pc = cursor + 4
        elif op == 0x1E:
            offset = read32(cursor)
            cursor += 4
            pc = cursor + offset
        elif op == 0x1F:
            condition = data[cursor]
            offset = read32(cursor + 1)
            cursor += 5
            jump = False
            if condition == 0xFF:
                jump = pop() != 1
            elif condition < len(CMP_LUT):
                jump = CMP_LUT[condition][cmp_result + 1] == 1
            pc = cursor + offset if jump else cursor
        elif op == 0x20:
            condition = data[cursor]
            offset = read32(cursor + 1)
            cursor += 5
            if condition < len(CMP_LUT) and CMP_LUT[condition][cmp_result + 1] == 1:
                calls.append(cursor)
                pc = cursor + offset
            else:
                pc = cursor
        elif op == 0x23:
            flag = read_var(data, cursor, work)
            flags[flag] = 1
            result.set_flags.add(flag)
            result.used_flags.add(flag)
            pc = cursor + 2
        elif op == 0x24:
            flag = read_var(data, cursor, work)
            flags[flag] = 0
            result.used_flags.add(flag)
            pc = cursor + 2
        elif op == 0x25:
            flag = read_var(data, cursor, work)
            var = read16(cursor + 2)
            if VAR_START <= var < VAR_END:
                work[var] = flags.get(flag, 0)
            result.used_flags.add(flag)
            pc = cursor + 4
        elif op == 0x26:
            var = read16(cursor)
            if VAR_START <= var < VAR_END:
                work[var] = work.get(var, 0) + read_var(data, cursor + 2, work)
            pc = cursor + 4
        elif op == 0x27:
            var = read16(cursor)
            if VAR_START <= var < VAR_END:
                work[var] = work.get(var, 0) - read_var(data, cursor + 2, work)
            pc = cursor + 4
        elif op == 0x28:
            var = read16(cursor)
            if VAR_START <= var < VAR_END:
                work[var] = read_var(data, cursor + 2, work)
            pc = cursor + 4
        elif op == 0x29:
            var = read16(cursor)
            push(work.get(var, 0))
            pc = cursor + 2
        elif op == 0x2A:
            var = read16(cursor)
            if VAR_START <= var < VAR_END:
                work[var] = pop()
            pc = cursor + 2
        elif op == 0x2B:
            var = read16(cursor)
            if VAR_START <= var < VAR_END:
                work[var] = (work.get(var, 0) * read_var(data, cursor + 2, work)) & 0xFFFF
            pc = cursor + 4
        elif op == 0x2C:
            var = read16(cursor)
            rhs = read_var(data, cursor + 2, work)
            if VAR_START <= var < VAR_END:
                work[var] = work.get(var, 0) // rhs if rhs else 0
            pc = cursor + 4
        elif op == 0x2D:
            var = read16(cursor)
            rhs = read_var(data, cursor + 2, work)
            if VAR_START <= var < VAR_END:
                work[var] = work.get(var, 0) % rhs if rhs else 0
            pc = cursor + 4
        elif op in (0x2E, 0x2F, 0x31, 0x32, 0x3B, 0x3E, 0x3F):
            pc = cursor
        elif op == 0x30:
            break
        elif op in (0x3C, 0x3D):
            file_no = read_var(data, cursor, work)
            message_id = read_var(data, cursor + 2, work)
            if file_no == SCRIPT_MSG_FILE:
                result.messages.append(message_id)
            pc = cursor + (10 if op == 0x3C else 8)
        elif op == 0x4C:
            pc = cursor + 1
        else:
            if sizes is None:
                result.unknown.add(op)
                break
            pc = cursor + sum(sizes)
        if pc < start and pc != end:
            result.unknown.add(op)
            break
    return result


def referenced_flags(data: bytes, start: int, end: int) -> set[int]:
    flags: set[int] = set()
    pc = start
    steps = 0
    while start <= pc < end and steps < MAX_STEPS:
        steps += 1
        op = struct.unpack_from("<H", data, pc)[0]
        sizes = OP_SIZES.get(op)
        if op == 0x02:
            break
        if op in (0x10, 0x23, 0x24, 0x25):
            flag = struct.unpack_from("<H", data, pc + 2)[0]
            if flag < VAR_START:
                flags.add(flag)
        if sizes is None and op not in (0x00, 0x01, 0x02, 0x05, 0x0B, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x3B, 0x3E, 0x3F):
            break
        if op in (0x04, 0x1E):
            pc += 2 + 4
        elif op == 0x1F:
            pc += 2 + 5
        elif op == 0x20:
            pc += 2 + 5
        elif op == 0x03:
            pc += 4
        elif op in (0x3C, 0x3D):
            pc += 2 + (10 if op == 0x3C else 8)
        elif op == 0x4C:
            pc += 3
        elif op in (0x08, 0x09, 0x0A, 0x10, 0x11, 0x23, 0x24, 0x29, 0x2A):
            pc += 2 + 2
        elif op == 0x25:
            pc += 2 + 4
        elif op in (0x19, 0x1A, 0x26, 0x27, 0x28, 0x2B, 0x2C, 0x2D, 0x12, 0x13):
            pc += 2 + 4
        elif op in (0x14, 0x17, 0x16):
            pc += 2 + 2
        elif op in (0x15, 0x18):
            pc += 2 + 5
        elif sizes is not None:
            pc += 2 + sum(sizes)
        else:
            break
    return flags


def static_messages(data: bytes, start: int, end: int, text_count: int) -> list[int]:
    """Fallback for scripts that use an unknown command.

    Scans for message commands without following control flow. Branch messages
    may be included, but this is preferable to dropping the NPC's dialogue.
    """
    messages: list[int] = []
    seen: set[int] = set()
    for offset in range(start, max(start, end - 11)):
        if data[offset:offset + 2] == b"\x3d\x00":
            message_id = struct.unpack_from("<H", data, offset + 4)[0]
            if message_id < text_count and message_id not in seen:
                seen.add(message_id)
                messages.append(message_id)
        elif data[offset:offset + 2] == b"\x3c\x00":
            message_id = struct.unpack_from("<H", data, offset + 4)[0]
            if message_id < text_count and message_id not in seen:
                seen.add(message_id)
                messages.append(message_id)
    return messages


def profile_for_script(
    data: bytes,
    start: int,
    end: int,
    text_sections: list[str],
) -> dict | None:
    flags = sorted(referenced_flags(data, start, end))
    defaults = run_script(data, start, end, {})

    def lines_for(message_ids: list[int]) -> list[str]:
        lines: list[str] = []
        for message_id in message_ids:
            if 0 <= message_id < len(text_sections):
                raw = text_sections[message_id]
                pages = format_pages(raw, infer_speaker(raw))
                lines.extend(pages)
        return lines

    if not defaults.messages:
        message_ids = static_messages(data, start, end, len(text_sections))
        lines = lines_for(message_ids)
        if not lines:
            return None
        speaker = infer_speaker(text_sections[message_ids[0]])
        pages = format_pages(text_sections[message_ids[0]], speaker)
        if pages:
            lines = pages + lines[len(pages):]
        return {
            "name": speaker,
            "lines": lines,
            "usedFlags": [],
            "setFlags": []
        }

    default_lines = lines_for(defaults.messages)
    if not default_lines:
        return None
    speaker = infer_speaker(text_sections[defaults.messages[0]])
    default_pages = format_pages(text_sections[defaults.messages[0]], speaker)
    if default_pages:
        # The first message determines the name; strip its prefix from the first page.
        default_lines = default_pages + default_lines[len(default_pages):]

    variants: list[dict] = []
    seen = {tuple(default_lines)}
    if 0 < len(flags) <= MAX_VARIANT_FLAGS:
        for values in itertools.product((0, 1), repeat=len(flags)):
            assignment = dict(zip(flags, values))
            if all(value == 0 for value in values):
                continue
            run = run_script(data, start, end, assignment)
            lines = lines_for(run.messages)
            if not lines:
                continue
            key = tuple(lines)
            if key in seen:
                continue
            seen.add(key)
            variants.append(
                {
                    "flags": {str(flag): assignment[flag] for flag in flags},
                    "lines": lines,
                    "setFlags": sorted(run.set_flags)
                }
            )

    profile = {
        "name": speaker,
        "lines": default_lines,
        "usedFlags": flags,
        "setFlags": sorted(defaults.set_flags)
    }
    if variants:
        profile["variants"] = variants
    return profile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--entities", default="server/content/rom/zone_entities.json")
    parser.add_argument("--out", default="server/content/rom/npc_dialogues.json")
    parser.add_argument("--check", action="store_true", help="verify known dialogue and exit")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    scripts = read_narc(rom, "a/0/5/7")
    texts = read_narc(rom, "a/0/0/3")
    headers = read_narc(rom, "a/0/1/2")[0]
    entity_data = json.loads((root / args.entities).read_text(encoding="utf-8"))

    zones_out: dict[str, dict] = {}
    profile_count = 0
    variant_count = 0
    unknown_ops: set[int] = set()

    for zone in entity_data["zones"]:
        zone_id = zone["id"]
        if zone_id * ZONE_HEADER.size + ZONE_HEADER.size > len(headers):
            continue
        header = ZONE_HEADER.unpack_from(headers, zone_id * ZONE_HEADER.size)
        script_file_id, text_file_id = header[4], header[6]
        if script_file_id >= len(scripts) or text_file_id >= len(texts):
            continue
        if not zone["npcs"]:
            continue
        script_data = scripts[script_file_id]
        offsets = read_script_table(script_data)
        if not offsets:
            continue
        text_sections = decrypt_text_sections(texts[text_file_id])
        if not text_sections:
            continue

        npc_profiles: dict[str, dict] = {}
        for npc in zone["npcs"]:
            script_id = npc["script"]
            if script_id <= 0 or script_id > len(offsets):
                continue
            start = offsets[script_id - 1]
            end = min([offset for offset in offsets if offset > start] + [len(script_data)])
            profile = profile_for_script(script_data, start, end, text_sections)
            if profile is None:
                continue
            defaults = run_script(script_data, start, end, {})
            unknown_ops.update(defaults.unknown)
            npc_profiles[str(npc["id"])] = profile
            profile_count += 1
            variant_count += len(profile.get("variants", []))

        if npc_profiles:
            zones_out[str(zone_id)] = {
                "scriptFile": script_file_id,
                "textFile": text_file_id,
                "npcs": npc_profiles
            }

    if args.check:
        lab = zones_out.get("396", {}).get("npcs", {}).get("0", {})
        mom = zones_out.get("390", {}).get("npcs", {}).get("0", {})
        bianca = zones_out.get("396", {}).get("npcs", {}).get("1", {})
        assert lab and any("Why, hello" in line for line in lab["lines"]), "lab Juniper dialogue missing"
        assert mom and mom["lines"], "Mom dialogue missing"
        assert bianca and any("Bianca" in line or "heart is pounding" in line for line in bianca["lines"]), "Bianca dialogue missing"
        print(
            f"Dialogue check passed: {len(zones_out)} zones, {profile_count} NPC profiles, "
            f"{variant_count} conditional variants"
        )
        if unknown_ops:
            print(f"Unknown opcodes: {', '.join(hex(op) for op in sorted(unknown_ops))}")
        return 0

    out_path = (root / args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "source": "Pokemon Black/White ROM (local extraction)",
                "zones": zones_out,
                "totals": {
                    "zones": len(zones_out),
                    "npcs": profile_count,
                    "variants": variant_count
                }
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        f"Wrote {out_path}: {len(zones_out)} zones, {profile_count} NPC profiles, "
        f"{variant_count} conditional variants"
    )
    if unknown_ops:
        print(f"Unknown opcodes: {', '.join(hex(op) for op in sorted(unknown_ops))}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
