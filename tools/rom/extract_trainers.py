#!/usr/bin/env python3
"""Extract trainer definitions (class, party) from a Pokemon Black/White ROM.

The ROM's file-name table is stripped, so both archives are located by their
contents:

* trainer archive -- one record per trainer, 20-64 bytes. The first four bytes
  are the party format, trainer class, battle type and party size.
* party archive -- one record per trainer, ``party size * entry length`` bytes.

The party record format follows the Gen 5 layout:

    u8  IVs
    u8  gender (bits 0-1) + ability (bits 4-7)
    u8  level
    u8  nature
    u16 species (1-based national dex)
    u16 form
    u16 held item            (only when format >= 2)
    u16 moves[4]             (only when format is odd)

``format`` = bit 0 unique moves, bit 1 held items, which gives entry lengths
of 8, 16, 18 or 26 bytes.

Output: ``server/content/rom/trainers.json`` (local extraction, gitignored).
The compiled story uses it to fill ``battle`` trainers with a real party.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from nds_fs import NintendoDSRom, iter_narcs  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "server/content/rom/trainers.json"
GAME_CONTENT = ROOT / "server/content/game.json"

TRAINER_MIN_LEN = 20
TRAINER_MAX_LEN = 64
MIN_MEMBER_COUNT = 300
MAX_MEMBER_COUNT = 2000


def party_entry_length(fmt: int) -> int:
    return 8 + (8 if fmt & 1 else 0) + (2 if fmt >= 2 else 0)


def score_trainer_archive(narc) -> float:
    """Share of members that look like a trainer header."""
    if not MIN_MEMBER_COUNT <= len(narc.files) <= MAX_MEMBER_COUNT:
        return 0.0
    good = 0
    for data in narc.files:
        if not TRAINER_MIN_LEN <= len(data) <= TRAINER_MAX_LEN:
            continue
        if data[0] > 3 or data[3] > 6:
            continue
        good += 1
    return good / len(narc.files)


def find_trainer_archives(rom: NintendoDSRom) -> tuple[list[bytes], list[bytes]]:
    archives = list(iter_narcs(rom))
    scored = sorted(((score_trainer_archive(narc), index, narc) for index, narc in archives), reverse=True)
    if not scored or scored[0][0] < 0.9:
        raise LookupError("no trainer data archive found in the ROM")
    score, index, trainer_narc = scored[0]

    trainers = trainer_narc.files
    best = (0.0, None)
    for other_index, other in archives:
        if other_index == index or len(other.files) != len(trainers):
            continue
        exact = 0
        for entry, party in zip(trainers, other.files):
            fmt, count = entry[0], entry[3]
            if len(party) == count * party_entry_length(fmt):
                exact += 1
        share = exact / len(trainers)
        if share > best[0]:
            best = (share, other)
    if best[1] is None or best[0] < 0.9:
        raise LookupError("no trainer party archive matched the trainer records")
    return trainers, best[1].files


def species_names() -> list[str]:
    if not GAME_CONTENT.exists():
        return []
    try:
        data = json.loads(GAME_CONTENT.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    species = data.get("species")
    return list(species) if isinstance(species, dict) else []


def parse_party(entry: bytes, party: bytes, names: list[str]) -> list[dict]:
    fmt, count = entry[0], entry[3]
    entry_length = party_entry_length(fmt)
    members = []
    for index in range(count):
        pos = index * entry_length
        if pos + 8 > len(party):
            break
        ivs, ability_byte, level, nature = party[pos], party[pos + 1], party[pos + 2], party[pos + 3]
        species_id, form = struct.unpack_from("<HH", party, pos + 4)
        cursor = pos + 8
        item = None
        moves: list[int] = []
        if fmt >= 2:
            item = struct.unpack_from("<H", party, cursor)[0]
            cursor += 2
        if fmt & 1:
            moves = list(struct.unpack_from("<4H", party, cursor))
        members.append(
            {
                "speciesId": species_id,
                "species": names[species_id - 1] if 0 < species_id <= len(names) else f"species_{species_id}",
                "level": level,
                "form": form,
                "ability": ability_byte >> 4,
                "gender": ability_byte & 3,
                "nature": nature,
                "ivs": ivs,
                "item": item,
                "moves": moves or None,
            }
        )
    return members


def build(rom: NintendoDSRom) -> dict:
    trainers, parties = find_trainer_archives(rom)
    names = species_names()
    out = {}
    total_members = 0
    for trainer_id, (entry, party) in enumerate(zip(trainers, parties)):
        if len(entry) < 4:
            continue
        members = parse_party(entry, party, names)
        total_members += len(members)
        out[str(trainer_id)] = {
            "class": entry[1],
            "battleType": entry[2],
            "format": entry[0],
            "party": members,
        }
    return {
        "source": "Pokemon Black/White ROM (local extraction)",
        "trainers": out,
        "totals": {"trainers": len(out), "partyMembers": total_members},
    }


def validate(data: dict) -> list[str]:
    problems = []
    names = species_names()
    limit = len(names) or 649
    for trainer_id, trainer in data["trainers"].items():
        if not trainer["party"]:
            # A few slots are placeholders the game never sends out (id 0 is one).
            continue
        for member in trainer["party"]:
            if not 1 <= member["speciesId"] <= limit:
                problems.append(f"trainer {trainer_id} species {member['speciesId']} out of range")
            if not 1 <= member["level"] <= 100:
                problems.append(f"trainer {trainer_id} level {member['level']} out of range")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="output JSON")
    parser.add_argument("--json", action="store_true", help="print instead of writing")
    args = parser.parse_args()

    rom_path = Path(args.rom)
    if rom_path.is_dir():
        candidates = sorted(rom_path.glob("*.nds"))
        if not candidates:
            print("no .nds ROM found", file=sys.stderr)
            return 1
        rom_path = candidates[0]
    rom = NintendoDSRom.open(rom_path)

    data = build(rom)
    problems = validate(data)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {out} ({data['totals']['trainers']} trainers, {data['totals']['partyMembers']} party members)")
    if problems:
        print(f"{len(problems)} validation problems, first 5:", file=sys.stderr)
        for problem in problems[:5]:
            print("  " + problem, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
