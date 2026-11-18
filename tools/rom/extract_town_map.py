#!/usr/bin/env python3
"""Extract the original Unova town map for the client's world map screen.

The BW town map is two 8bpp BG layers plus a table of 61 places.  The map
texture lives in archive a/0/8/5 (file 7, 256x176; the last 8 rows are the
screen's colour strip and are cropped) and the place table in a/0/8/6.

The place table has 61 records of 27 u16s.  Field 0 is the zone id, fields 2
and 3 are the marker's x/y in the 256x168 map, and field 11 is the place type
(0 town, 1 route, 2-5 landmark).  Zone ids are joined to the named outdoor
areas through the world's matrix cells, so the server can send a localized
place for every location the HUD already names.

Outputs:
- client/assets/bw/ui/unova_map.png (local ROM asset, gitignored)
- server/content/rom/world_map.json (place list consumed by the server)

Requires: ndspy, Pillow.  Run after extract_unova_outdoor.py, which produces
client/assets/bw/unova_outdoor/library.json.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

try:
    import ndspy.narc
    import ndspy.rom
except ImportError:
    print("Missing dependency: pip install ndspy pillow", file=sys.stderr)
    raise

try:
    from PIL import Image
except ImportError:
    print("Missing dependency: pip install ndspy pillow", file=sys.stderr)
    raise


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ROM = ROOT / "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
DEFAULT_IMAGE = ROOT / "client" / "assets" / "bw" / "ui" / "unova_map.png"
DEFAULT_DATA = ROOT / "server" / "content" / "rom" / "world_map.json"
LOCATIONS_FILE = ROOT / "server" / "content" / "rom" / "outdoor_locations.json"
CELLS_FILE = ROOT / "client" / "assets" / "bw" / "unova_outdoor" / "library.json"

GRAPHICS_ARCHIVE = "a/0/8/5"
MAP_NCGR = 7
MAP_NCLR = 0
MAP_WIDTH = 256
MAP_HEIGHT = 176
CROPPED_HEIGHT = 168
PLACE_ARCHIVE = "a/0/8/6"
PLACE_COUNT = 61
PLACE_FIELD_COUNT = 27
PLACE_TYPE_TOWN = 0
PLACE_TYPE_ROUTE = 1


def read_narc(rom, path: str) -> list[bytes]:
    return [bytes(entry) for entry in ndspy.narc.NARC(rom.getFileByName(path)).files]


def palette_colors(data: bytes) -> list[tuple[int, int, int]]:
    if data[:4] != b"RLCN":
        raise ValueError("map palette is not an NCLR file")
    data_size = int.from_bytes(data[0x20:0x24], "little")
    raw = data[0x28 : 0x28 + data_size]
    colors: list[tuple[int, int, int]] = []
    for offset in range(0, len(raw), 2):
        value = raw[offset] | (raw[offset + 1] << 8)
        r5, g5, b5 = value & 31, (value >> 5) & 31, (value >> 10) & 31
        colors.append((r5 * 255 // 31, g5 * 255 // 31, b5 * 255 // 31))
    return colors


def decode_8bpp_ncgr(data: bytes, width: int, height: int) -> Image.Image:
    if data[:4] != b"RGCN":
        raise ValueError("map texture is not an NCGR file")
    data_size = int.from_bytes(data[0x28:0x2C], "little")
    tiles = data[0x30 : 0x30 + data_size]
    tiles_x = width // 8
    tiles_y = height // 8
    expected = tiles_x * tiles_y * 64
    if len(tiles) < expected:
        raise ValueError(f"map texture is {len(tiles)} bytes, expected {expected}")
    pixels = bytearray(width * height)
    for tile_y in range(tiles_y):
        for tile_x in range(tiles_x):
            base = (tile_y * tiles_x + tile_x) * 64
            for py in range(8):
                row = base + py * 8
                out = (tile_y * 8 + py) * width + tile_x * 8
                pixels[out : out + 8] = tiles[row : row + 8]
    highest = max(pixels)
    if highest >= 256:
        raise ValueError(f"map texture uses palette index {highest}")
    return Image.frombytes("P", (width, height), bytes(pixels))


def load_place_table(rom) -> dict[int, dict[str, int]]:
    data = read_narc(rom, PLACE_ARCHIVE)[0]
    expected = PLACE_COUNT * PLACE_FIELD_COUNT * 2
    if len(data) != expected:
        raise ValueError(
            f"{PLACE_ARCHIVE} is {len(data)} bytes, expected "
            f"{expected} ({PLACE_COUNT} places)"
        )
    places: dict[int, dict[str, int]] = {}
    for index in range(PLACE_COUNT):
        values = struct.unpack_from(f"<{PLACE_FIELD_COUNT}H", data, index * 54)
        zone, x, y, kind = values[0], values[2], values[3], values[11]
        if not (0 <= x < MAP_WIDTH and 0 <= y < CROPPED_HEIGHT):
            raise ValueError(f"place {index} has out-of-map coordinates {x},{y}")
        places[zone] = {"x": x, "y": y, "type": kind}
    return places


def read_json(path: Path, hint: str) -> object:
    if not path.exists():
        raise SystemExit(f"Missing {path}\n{hint}")
    return json.loads(path.read_text(encoding="utf-8"))


def build_world_map(places_by_zone: dict[int, dict[str, int]]) -> dict:
    locations = read_json(
        LOCATIONS_FILE,
        "Run tools/rom/extract_outdoor_locations.py (or the full Unova build) first.",
    )
    cells = read_json(
        CELLS_FILE,
        "Run tools/rom/extract_unova_outdoor.py before extracting the town map.",
    )
    grid = locations["grid"]
    zone_by_cell = {
        (int(cell["x"]), int(cell["y"])): int(cell["zone"]) for cell in cells["cells"]
    }

    by_name: dict[str, dict] = {}
    for y, row in enumerate(grid):
        for x, name in enumerate(row):
            if not name or name in by_name:
                continue
            zone = zone_by_cell.get((x, y))
            place = places_by_zone.get(zone) if zone is not None else None
            if place is None:
                continue
            if place["type"] == PLACE_TYPE_TOWN:
                kind = "town"
            elif place["type"] == PLACE_TYPE_ROUTE:
                kind = "route"
            else:
                kind = "landmark"
            by_name[name] = {
                "key": name,
                "x": place["x"],
                "y": place["y"],
                "kind": kind,
            }

    order = {"town": 0, "route": 1, "landmark": 2}
    missing = [
        str(name)
        for row in grid
        for name in row
        if name and name not in by_name
    ]
    return {
        "source": f"{GRAPHICS_ARCHIVE}[{MAP_NCGR}] + {PLACE_ARCHIVE}",
        "image": {
            "asset": "res://assets/bw/ui/unova_map.png",
            "width": MAP_WIDTH,
            "height": CROPPED_HEIGHT,
        },
        "places": sorted(
            by_name.values(), key=lambda p: (order[p["kind"]], p["key"])
        ),
        "missing": sorted(set(missing)),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", type=Path, default=DEFAULT_ROM)
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    args = parser.parse_args()

    if not args.rom.exists():
        raise SystemExit(f"ROM not found: {args.rom}")

    rom = ndspy.rom.NintendoDSRom.fromFile(str(args.rom))
    graphics = read_narc(rom, GRAPHICS_ARCHIVE)

    colors = palette_colors(graphics[MAP_NCLR])
    image = decode_8bpp_ncgr(graphics[MAP_NCGR], MAP_WIDTH, MAP_HEIGHT)
    image = image.crop((0, 0, MAP_WIDTH, CROPPED_HEIGHT))
    image.putpalette([channel for color in colors[:256] for channel in color])
    image = image.convert("RGB")

    args.image.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.image)

    places_by_zone = load_place_table(rom)
    world_map = build_world_map(places_by_zone)
    args.data.parent.mkdir(parents=True, exist_ok=True)
    args.data.write_text(
        json.dumps(world_map, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(f"map   -> {args.image} ({MAP_WIDTH}x{CROPPED_HEIGHT})")
    print(f"places-> {args.data} ({len(world_map['places'])} places)")
    if world_map["missing"]:
        print("unmapped named areas: " + ", ".join(world_map["missing"]))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
