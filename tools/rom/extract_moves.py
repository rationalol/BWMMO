#!/usr/bin/env python3
"""Extract all Gen 5 move data and English move names from the ROM.

Sources:
- a/0/2/1: 560 records of 36 bytes; byte 0 is the type, byte 2 the category,
  byte 3 power, byte 4 accuracy, byte 5 PP, byte 6 priority.
- a/0/0/2 file 203: 560 text sections; the section index is the move id.

Output: server/content/rom/moves.json
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
CATEGORIES = {0: "status", 1: "physical", 2: "special"}
MOVE_NAME_FILE = 203


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--out", default="server/content/rom/moves.json")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    records = read_narc(rom, "a/0/2/1")
    names = decrypt_text_sections(read_narc(rom, "a/0/0/2")[MOVE_NAME_FILE])

    moves = {}
    missing_names = []
    for move_id in range(1, len(records)):
        record = records[move_id]
        name = names[move_id].strip() if move_id < len(names) else ""
        if not name:
            missing_names.append(move_id)
            continue
        type_id = record[0]
        category = record[2]
        if type_id not in TYPE_NAMES or category not in CATEGORIES:
            print(f"skip move {move_id} {name}: type={type_id} category={category}", file=sys.stderr)
            continue
        moves[str(move_id)] = {
            "id": move_id,
            "name": name,
            "type": TYPE_NAMES[type_id],
            "category": CATEGORIES[category],
            "power": record[3],
            "accuracy": 0 if record[4] > 100 else record[4],
            "pp": record[5],
            "priority": record[6] - 256 if record[6] > 127 else record[6]
        }

    expected = {
        33: ("Tackle", "Normal", "physical", 50, 100, 35, 0),
        22: ("Vine Whip", "Grass", "physical", 35, 100, 15, 0),
        52: ("Ember", "Fire", "special", 40, 100, 25, 0),
        98: ("Quick Attack", "Normal", "physical", 40, 100, 30, 1),
        209: ("Spark", "Electric", "physical", 65, 100, 20, 0)
    }
    for move_id, values in expected.items():
        move = moves.get(str(move_id))
        assert move, f"missing move {move_id}"
        actual = (
            move["name"], move["type"], move["category"], move["power"],
            move["accuracy"], move["pp"], move["priority"]
        )
        assert actual == values, f"move {move_id}: {actual} != {values}"

    if args.check:
        print(f"Move check passed: {len(moves)} moves, {len(missing_names)} missing names")
        if missing_names:
            print("Missing names:", missing_names[:20])
        return 0

    out_path = (root / args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "source": "Pokemon Black/White ROM (local extraction)",
                "moveDataFile": "a/0/2/1",
                "moveNameFile": f"a/0/0/2[{MOVE_NAME_FILE}]",
                "moves": moves
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {out_path}: {len(moves)} moves ({len(missing_names)} missing names)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
