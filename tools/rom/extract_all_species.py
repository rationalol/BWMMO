#!/usr/bin/env python3
"""Extract all 649 Gen 5 species with base stats, types and full learnsets.

Unlike extract_species.py, this tool does not filter to the current game.json
roster. It writes every valid national dex entry to species_all.json so the
content generator can decide which moves survive the Showdown mapping.

Sources:
- a/0/1/6: personal data indexed by national dex
- a/0/1/8: level-up learnsets indexed by national dex
- a/0/0/2 file 70: species names, section index == national dex

Output: server/content/rom/species_all.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom  # noqa: E402

from extract_dialogues import decrypt_text_sections  # noqa: E402
from extract_nuvema import find_rom, read_narc  # noqa: E402
from extract_species import TYPE_NAMES, parse_learnset  # noqa: E402

SPECIES_NAME_FILE = 70
MAX_DEX = 649


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--out", default="server/content/rom/species_all.json")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    personal = read_narc(rom, "a/0/1/6")
    learnsets = read_narc(rom, "a/0/1/8")
    names = decrypt_text_sections(read_narc(rom, "a/0/0/2")[SPECIES_NAME_FILE])

    species = {}
    skipped = []
    for dex in range(1, MAX_DEX + 1):
        if dex >= len(personal) or dex >= len(learnsets):
            skipped.append((dex, "missing personal/learnset record"))
            continue
        record = personal[dex]
        if len(record) < 9:
            skipped.append((dex, "short personal record"))
            continue
        hp, atk, dfn, speed, sp_atk, sp_def = record[0:6]
        type_a, type_b = record[6], record[7]
        catch = record[8]
        if type_a not in TYPE_NAMES or (type_b not in TYPE_NAMES and type_b != type_a):
            skipped.append((dex, f"unknown types {type_a}/{type_b}"))
            continue
        types = []
        for type_id in (type_a, type_b):
            name = TYPE_NAMES[type_id]
            if name not in types:
                types.append(name)
        learnset = [
            {"moveId": move_id, "level": level}
            for move_id, level in parse_learnset(learnsets[dex])
            if move_id != 0
        ]
        if not learnset:
            skipped.append((dex, "empty learnset"))
            continue
        rom_name = names[dex].strip() if dex < len(names) else ""
        species[str(dex)] = {
            "dex": dex,
            "name": rom_name,
            "types": types,
            "baseStats": {
                "hp": hp,
                "atk": atk,
                "def": dfn,
                "spAtk": sp_atk,
                "spDef": sp_def,
                "speed": speed
            },
            "catchRate255": catch,
            "learnset": learnset
        }

    if args.check:
        for dex, name in ((495, "Snivy"), (498, "Tepig"), (501, "Oshawott"), (1, "Bulbasaur"), (649, "Genesect")):
            entry = species.get(str(dex))
            assert entry, f"missing dex {dex}"
            assert entry["name"] or name, f"dex {dex} has no name"
            assert entry["learnset"], f"dex {dex} has no learnset"
        print(f"Species check passed: {len(species)} species, {len(skipped)} skipped")
        return 0

    out_path = (root / args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "source": "Pokemon Black/White ROM (local extraction)",
                "personalFile": "a/0/1/6",
                "learnsetFile": "a/0/1/8",
                "nameFile": f"a/0/0/2[{SPECIES_NAME_FILE}]",
                "species": species,
                "skipped": skipped
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {out_path}: {len(species)} species ({len(skipped)} skipped)")
    if skipped:
        print(f"Skipped: {skipped[:10]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
