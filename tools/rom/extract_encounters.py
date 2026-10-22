#!/usr/bin/env python3
"""Extract Gen 5 land encounter tables for a zone or map matrix cell.

Gen 5 zone headers (`a/0/1/2`, 48-byte records) store the encounter table index
in field 11. The table lives in `a/1/2/6`; the first 12 slots are the regular
land-grass slots, each `(species dex, min level, max level)`.

Usage:
    python tools/rom/extract_encounters.py --zone 317
    python tools/rom/extract_encounters.py --cell 24,22
    python tools/rom/extract_encounters.py --cell 24,22 --json

The standard Gen 5 land slot rates are applied:
20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import NONE, ZONE_HEADER, find_rom, read_narc

SLOT_RATES = [20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1]


def zone_for_cell(rom: ndspy.rom.NintendoDSRom, cell: tuple[int, int]) -> int:
    overworld = read_narc(rom, "a/0/0/9")[0]
    _, _, width, height = struct.unpack_from("<HHHH", overworld)
    x, y = cell
    if not (0 <= x < width and 0 <= y < height):
        raise SystemExit(f"cell {cell} is outside the {width}x{height} matrix")
    zones = struct.unpack_from(f"<{width * height}I", overworld, 8 + 4 * width * height)
    zone = zones[y * width + x]
    if zone == NONE:
        raise SystemExit(f"cell {cell} has no zone")
    return zone


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--zone", type=int, help="zone header id")
    group.add_argument("--cell", help="map matrix cell X,Y")
    parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))

    zone_id = args.zone
    if args.cell:
        x, y = (int(value) for value in args.cell.split(","))
        zone_id = zone_for_cell(rom, (x, y))

    zone_data = read_narc(rom, "a/0/1/2")[0]
    header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
    encounter_id = header[11]
    if encounter_id == 0xFFFF:
        print(f"zone {zone_id}: no wild encounters")
        return 0

    tables = read_narc(rom, "a/1/2/6")
    if encounter_id >= len(tables):
        raise SystemExit(f"zone {zone_id} encounter id {encounter_id} is out of range")
    entry = tables[encounter_id]
    if len(entry) < 8 + 12 * 4:
        raise SystemExit(f"encounter table {encounter_id} is too small")

    content_path = root / "server" / "content" / "game.json"
    species_by_dex = {}
    if content_path.is_file():
        content = json.loads(content_path.read_text(encoding="utf-8"))
        species_by_dex = {
            species["dex"]: species_id
            for species_id, species in content.get("species", {}).items()
        }

    slots = []
    for index, rate in enumerate(SLOT_RATES):
        dex, min_level, max_level = struct.unpack_from("<HBB", entry, 8 + index * 4)
        if dex == 0:
            continue
        slots.append({
            "slot": index + 1,
            "dex": dex,
            "species": species_by_dex.get(dex),
            "minLevel": min_level,
            "maxLevel": max_level,
            "weight": rate
        })

    result = {"zone": zone_id, "encounterId": encounter_id, "table": slots}
    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    print(f"zone {zone_id}: encounter table {encounter_id}")
    for slot in slots:
        species = slot["species"] or f"dex {slot['dex']}"
        print(
            f"  slot {slot['slot']:2d}: {species:12s} L{slot['minLevel']}-{slot['maxLevel']} "
            f"weight {slot['weight']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
