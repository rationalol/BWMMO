#!/usr/bin/env python3
"""Extract Gen 5 species base data and level-up learnsets into server content.

Sources:
- a/0/1/6 personal data (60-byte records, indexed by national dex):
  HP, Atk, Def, Spe, SpA, SpD, type1, type2, catch rate, ...
- a/0/1/8 level-up movesets: repeated (move id u16, level u16), 0xFFFF-terminated.

The full ROM data is written to server/content/rom/species.json. With --apply,
game.json species get real base stats/types/catch rates and a playable learnset
filtered to moves that exist in game.json (matched by each move's romMoveId).
Status moves and unsupported damaging moves stay in the ROM dataset for later.

Usage:
    python tools/rom/extract_species.py --apply
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import find_rom, read_narc

TYPE_NAMES = {
    0: "Normal",
    1: "Fighting",
    2: "Flying",
    3: "Poison",
    4: "Ground",
    5: "Rock",
    6: "Bug",
    7: "Ghost",
    8: "Steel",
    9: "Fire",
    10: "Water",
    11: "Grass",
    12: "Electric",
    13: "Psychic",
    14: "Ice",
    15: "Dragon",
    16: "Dark"
}

SUPPORTED_TYPES = {"Normal", "Electric", "Grass", "Fire", "Water", "Rock", "Flying"}


def parse_learnset(raw: bytes) -> list[tuple[int, int]]:
    pairs: list[tuple[int, int]] = []
    for offset in range(0, len(raw) - 3, 4):
        move_id, level = struct.unpack_from("<HH", raw, offset)
        if move_id == 0xFFFF:
            break
        pairs.append((move_id, level))
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--game", default="server/content/game.json", help="game.json to read/update")
    parser.add_argument("--out", default="server/content/rom/species.json", help="ROM dataset output")
    parser.add_argument("--apply", action="store_true", help="write real stats/learnsets into game.json")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    game_path = (root / args.game).resolve()
    out_path = (root / args.out).resolve()

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    personal = [bytes(entry) for entry in read_narc(rom, "a/0/1/6")]
    learnsets = [bytes(entry) for entry in read_narc(rom, "a/0/1/8")]

    game = json.loads(game_path.read_text(encoding="utf-8"))
    supported_by_rom_id = {
        int(move["romMoveId"]): move_id
        for move_id, move in game.get("moves", {}).items()
        if isinstance(move, dict) and isinstance(move.get("romMoveId"), int)
    }

    rom_species: dict[str, dict] = {}
    report: list[str] = []
    for species_id, species in game.get("species", {}).items():
        dex = int(species["dex"])
        if dex >= len(personal) or dex >= len(learnsets):
            raise SystemExit(f"{species_id}: dex {dex} is outside the ROM tables")
        record = personal[dex]
        if len(record) < 9:
            raise SystemExit(f"{species_id}: personal record {dex} is too small")
        hp, atk, dfn, speed, sp_atk, sp_def = record[0:6]
        type_a, type_b = record[6], record[7]
        catch = record[8]
        types = []
        for type_id in (type_a, type_b):
            name = TYPE_NAMES.get(type_id)
            if name is None:
                raise SystemExit(f"{species_id}: unknown type id {type_id}")
            if name not in types:
                types.append(name)
        unsupported = [name for name in types if name not in SUPPORTED_TYPES]
        if unsupported:
            raise SystemExit(f"{species_id}: engine does not support types {unsupported}")

        full_learnset = [
            {
                "moveId": move_id,
                "level": level,
                "supported": move_id in supported_by_rom_id
            }
            for move_id, level in parse_learnset(learnsets[dex])
        ]
        filtered: list[dict] = []
        seen: set[str] = set()
        for entry in full_learnset:
            move_id = int(entry["moveId"])
            if move_id not in supported_by_rom_id:
                continue
            engine_move = supported_by_rom_id[move_id]
            if engine_move in seen:
                continue
            seen.add(engine_move)
            filtered.append({"level": int(entry["level"]), "move": engine_move})
        if not filtered:
            raise SystemExit(f"{species_id}: no supported learnset moves; add a move mapping first")
        if not any(entry["level"] <= 5 for entry in filtered):
            raise SystemExit(f"{species_id}: no supported move available at starter level")

        rom_species[species_id] = {
            "dex": dex,
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
            "learnset": full_learnset
        }

        if args.apply:
            species["types"] = types
            species["baseHp"] = hp
            species["baseAtk"] = atk
            species["baseDef"] = dfn
            species["baseSpAtk"] = sp_atk
            species["baseSpDef"] = sp_def
            species["baseSpeed"] = speed
            species["catchRate"] = round(catch / 255, 3)
            species["learnset"] = sorted(filtered, key=lambda entry: (entry["level"], entry["move"]))
        report.append(
            f"  {species_id:10s} dex {dex:3d} {types!s:20s} "
            f"{hp}/{atk}/{dfn}/{sp_atk}/{sp_def}/{speed} "
            f"catch {catch} playable moves {len(filtered)}/{len(full_learnset)}"
        )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    dataset = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "personalFile": "a/0/1/6",
        "learnsetFile": "a/0/1/8",
        "notes": "baseStats order: hp, atk, def, spAtk, spDef, speed; move ids are Gen 5 ids",
        "species": rom_species
    }
    out_path.write_text(json.dumps(dataset, indent=2) + "\n", encoding="utf-8")
    if args.apply:
        game_path.write_text(json.dumps(game, indent=2) + "\n", encoding="utf-8")

    print(f"ROM:    {rom_path}")
    print(f"Output: {out_path}")
    print(f"Applied to game.json: {args.apply}")
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
