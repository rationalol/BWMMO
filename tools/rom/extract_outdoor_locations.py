#!/usr/bin/env python3
"""Build the outdoor matrix -> location-name grid used by the HUD.

The seamless Unova map is one 29x27 matrix of 32x32-tile cells. Each cell has
a ROM zone id, and the zone header's field 14 points at a section in text bank
`a/0/0/2[89]` (the location-name table). This script writes the English names
as a compact grid; server/src/i18n names the display strings for zh_CN.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import ZONE_HEADER, find_rom, read_narc
from extract_dialogues import decrypt_text_sections

NONE = 0xFFFFFFFF
LOCATION_TEXT_FILE = 89


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--out",
        default="server/content/rom/outdoor_locations.json",
        help="output JSON path",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom = ndspy.rom.NintendoDSRom.fromFile(
        str(find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom)))
    )
    overworld = read_narc(rom, "a/0/0/9")[0]
    _, _, width, height = struct.unpack_from("<HHHH", overworld, 0)
    zone_grid = struct.unpack_from(f"<{width * height}I", overworld, 8 + 4 * width * height)
    zone_data = read_narc(rom, "a/0/1/2")[0]
    text = decrypt_text_sections(read_narc(rom, "a/0/0/2")[LOCATION_TEXT_FILE])

    grid: list[list[str]] = []
    zone_ids: list[list[int]] = []
    for y in range(height):
        row: list[str] = []
        id_row: list[int] = []
        for x in range(width):
            zone_id = zone_grid[y * width + x]
            if zone_id == NONE:
                row.append("")
                id_row.append(-1)
                continue
            header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
            index = header[14] & 0xFF
            row.append(text[index] if index < len(text) else "")
            id_row.append(zone_id)
        grid.append(row)
        zone_ids.append(id_row)

    output = {
        "width": width,
        "height": height,
        "tileSize": 32,
        "grid": grid,
        "zoneIds": zone_ids,
    }
    out = root / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out.relative_to(root)} ({width}x{height})")
    for y in range(max(0, height - 8), height):
        print(y, " | ".join(name or "-" for name in grid[y]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
