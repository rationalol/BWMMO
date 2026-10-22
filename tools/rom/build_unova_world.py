#!/usr/bin/env python3
"""Assemble the full outdoor Unova collision world from the extracted cell GLBs.

Input:  client/assets/bw/unova_outdoor/library.json + cell GLBs
Output: server/content/worlds/unova_full.json

Each matrix cell contributes a 32x32 tile block. Collision and the terrain
height planes come from the map chunk's permission/height grid in `a/0/0/8`;
chunks without one (NG/RD) fall back to sampling the cell GLB. Encounter zones
come from the zone header's encounter table index and the ROM land table in
`a/1/2/6`.
"""

from __future__ import annotations

import argparse
import base64
import json
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import (
    ZONE_HEADER,
    chunk_terrain_heights,
    find_height_tables,
    find_rom,
    lz11_decompress,
    permission_rows,
    read_narc
)

TILE = 16.0
CELL = 32
CELL_SIZE = 512.0
SLOT_RATES = [20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1]

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def load_glb(path: Path):
    data = path.read_bytes()
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"not a GLB: {path}")
    json_length, json_type = struct.unpack_from("<II", data, 12)
    document = json.loads(data[20:20 + json_length])
    offset = 20 + json_length
    bin_length, bin_type = struct.unpack_from("<II", data, offset)
    binary = data[offset + 8:offset + 8 + bin_length]
    return document, binary


def read_accessor(document, binary, index: int):
    accessor = document["accessors"][index]
    view = document["bufferViews"][accessor["bufferView"]]
    fmt, size = COMP[accessor["componentType"]]
    count = NCOMP[accessor["type"]]
    stride = view.get("byteStride", size * count)
    base = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    result = []
    for item in range(accessor["count"]):
        values = struct.unpack_from("<" + fmt * count, binary, base + item * stride)
        result.append(values if count > 1 else values[0])
    return result


def material_char(name: str) -> str:
    if name.startswith("kusa_ec"):
        return "g"
    walkable = (
        name.startswith("michi")
        or name.startswith("grass01")
        or name.startswith("ue_grass")
        or name.startswith("hana")
        or name.startswith("kaidan")
        or name.startswith("hashi")
        or name.startswith("dansa")
        or name.startswith("t01wd")
        or name.startswith("t02michi")
        or name.startswith("t02kaidan")
        or name.startswith("t02kusa")
        or name.startswith("t2michi")
        or name.startswith("sea_jimen")
        or name.startswith("nagaisu")
    )
    return "." if walkable else "#"


def sample_cell(glb_path: Path, classifier=material_char) -> list[str]:
    document, binary = load_glb(glb_path)
    positions = read_accessor(document, binary, 0)
    materials = [material.get("name", "?") for material in document.get("materials", [])]
    triangles = []
    for primitive in document["meshes"][0]["primitives"]:
        name = materials[primitive["material"]]
        indices = read_accessor(document, binary, primitive["indices"])
        for index in range(0, len(indices), 3):
            points = [positions[i] for i in indices[index:index + 3]]
            if len(points) < 3:
                continue
            ax, ay, az = points[0]
            bx, by, bz = points[1]
            cx, cy, cz = points[2]
            ux, uy, uz = bx - ax, by - ay, bz - az
            vx, vy, vz = cx - ax, cy - ay, cz - az
            nx = uy * vz - uz * vy
            ny = uz * vx - ux * vz
            nz = ux * vy - uy * vx
            length = (nx * nx + ny * ny + nz * nz) ** 0.5
            if length == 0 or ny <= 0.1 * length:
                continue
            triangles.append((name, points))

    def sample(x: float, z: float):
        best = None
        for name, points in triangles:
            (x1, y1, z1), (x2, y2, z2), (x3, y3, z3) = points
            denominator = (z2 - z3) * (x1 - x3) + (x3 - x2) * (z1 - z3)
            if abs(denominator) < 1e-9:
                continue
            a = ((z2 - z3) * (x - x3) + (x3 - x2) * (z - z3)) / denominator
            b = ((z3 - z1) * (x - x3) + (x1 - x3) * (z - z3)) / denominator
            c = 1 - a - b
            if a >= -0.02 and b >= -0.02 and c >= -0.02:
                height = a * y1 + b * y2 + c * y3
                if best is None or height > best[0]:
                    best = (height, name)
        return best[1] if best else None

    rows = []
    for local_y in range(CELL):
        row = []
        for local_x in range(CELL):
            x = -248 + local_x * TILE
            z = -248 + local_y * TILE
            material = sample(x, z)
            row.append(classifier(material) if material else "#")
        rows.append("".join(row))
    return rows


def sample_cell_heights(glb_path: Path, cell: int = CELL, tile: float = TILE,
                        origin: float = -248.0) -> list[int]:
    """Fallback height sampling from the cell GLB at every tile centre.

    Used for NG/RD chunks that have no MapHeightTile terrain section. This is
    a visual-mesh approximation: the topmost upward-facing surface can be a
    tree/grass card rather than the floor. Returns fixed-point heights (1/16
    world unit) in row-major order; a tile with no surface is 0.
    """
    document, binary = load_glb(glb_path)
    positions = read_accessor(document, binary, 0)
    heights: list[float | None] = [None] * (cell * cell)
    for primitive in document["meshes"][0]["primitives"]:
        indices = read_accessor(document, binary, primitive["indices"])
        for index in range(0, len(indices), 3):
            points = [positions[i] for i in indices[index:index + 3]]
            if len(points) < 3:
                continue
            ax, ay, az = points[0]
            bx, by, bz = points[1]
            cx, cy, cz = points[2]
            ux, uy, uz = bx - ax, by - ay, bz - az
            vx, vy, vz = cx - ax, cy - ay, cz - az
            nx = uy * vz - uz * vy
            ny = uz * vx - ux * vz
            nz = ux * vy - uy * vx
            length = (nx * nx + ny * ny + nz * nz) ** 0.5
            if length == 0 or ny <= 0.1 * length:
                continue
            denominator = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
            if abs(denominator) < 1e-9:
                continue
            min_tx = max(0, int((min(ax, bx, cx) - origin) // tile))
            max_tx = min(cell - 1, int((max(ax, bx, cx) - origin) // tile))
            min_ty = max(0, int((min(az, bz, cz) - origin) // tile))
            max_ty = min(cell - 1, int((max(az, bz, cz) - origin) // tile))
            for ty in range(min_ty, max_ty + 1):
                zc = origin + ty * tile
                for tx in range(min_tx, max_tx + 1):
                    xc = origin + tx * tile
                    a = ((bz - cz) * (xc - cx) + (cx - bx) * (zc - cz)) / denominator
                    b = ((cz - az) * (xc - cx) + (ax - cx) * (zc - cz)) / denominator
                    c = 1 - a - b
                    if a < -0.02 or b < -0.02 or c < -0.02:
                        continue
                    height = a * ay + b * by + c * cy
                    slot = ty * cell + tx
                    if heights[slot] is None or height > heights[slot]:
                        heights[slot] = height
    values = [0 if height is None else max(-32768, min(32767, round(height * 16)))
              for height in heights]
    return values


def encode_heights(values: list[int]) -> str:
    return base64.b64encode(struct.pack(f"<{len(values)}h", *values)).decode("ascii")


def encode_terrain_heights(rows: list[list[float]]) -> str:
    values = [
        max(-32768, min(32767, round(height * 16)))
        for row in rows
        for height in row
    ]
    return encode_heights(values)


def encounter_table(rom, zone_header, content_species_by_dex):
    encounter_id = zone_header[11]
    if encounter_id == 0xFFFF:
        return None
    tables = read_narc(rom, "a/1/2/6")
    if encounter_id >= len(tables):
        return None
    entry = tables[encounter_id]
    table = []
    for index, weight in enumerate(SLOT_RATES):
        offset = 8 + index * 4
        if offset + 4 > len(entry):
            break
        dex, min_level, max_level = struct.unpack_from("<HBB", entry, offset)
        species = content_species_by_dex.get(dex)
        if dex == 0 or species is None:
            continue
        table.append({
            "species": species,
            "minLevel": min_level,
            "maxLevel": max_level,
            "weight": weight
        })
    return table or None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--assets", default="client/assets/bw/unova_outdoor", help="outdoor asset dir")
    parser.add_argument("--out", default="server/content/worlds/unova_full.json", help="world JSON")
    parser.add_argument("--game", default="server/content/game.json", help="game content for dex mapping")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    asset_dir = (root / args.assets).resolve()
    library = json.loads((asset_dir / "library.json").read_text(encoding="utf-8"))
    game = json.loads((root / args.game).read_text(encoding="utf-8")) if (root / args.game).exists() else {}
    species_by_dex = {
        int(species["dex"]): species_id
        for species_id, species in game.get("species", {}).items()
    }
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    zone_data = read_narc(rom, "a/0/1/2")[0]
    chunks = read_narc(rom, "a/0/0/8")
    height_slopes, height_offsets = find_height_tables(rom)

    matrix = library["matrix"]
    width_cells, height_cells = matrix["width"], matrix["height"]
    width = width_cells * CELL
    height = height_cells * CELL
    rows = [["#"] * width for _ in range(height)]
    visual_chunks = []
    encounter_zones = []
    height_cache: dict[str, str] = {}
    height_fallbacks = 0

    for cell in library["cells"]:
        cell_x, cell_y = cell["x"], cell["y"]
        glb = asset_dir / cell["mapFile"]
        chunk = lz11_decompress(chunks[cell["model"]])
        cell_rows = permission_rows(chunk, CELL, CELL, CELL, scale=True)
        if cell_rows is None:
            cell_rows = sample_cell(glb)
        for local_y, row in enumerate(cell_rows):
            for local_x, char in enumerate(row):
                rows[cell_y * CELL + local_y][cell_x * CELL + local_x] = char
        if cell["mapFile"] not in height_cache:
            terrain_rows = chunk_terrain_heights(chunk, height_slopes, height_offsets, CELL, scale=True)
            if terrain_rows is None:
                height_fallbacks += 1
                height_cache[cell["mapFile"]] = encode_heights(sample_cell_heights(glb))
            else:
                height_cache[cell["mapFile"]] = encode_terrain_heights(terrain_rows)
        visual_chunks.append({
            "asset": f"unova_outdoor/{cell['mapFile'].rsplit('/', 1)[0]}",
            "cellX": cell_x,
            "cellY": cell_y,
            "offsetX": cell_x * CELL_SIZE,
            "offsetZ": cell_y * CELL_SIZE,
            "heights": height_cache[cell["mapFile"]]
        })

        header = ZONE_HEADER.unpack_from(zone_data, cell["zone"] * ZONE_HEADER.size)
        table = encounter_table(rom, header, species_by_dex)
        if table:
            encounter_zones.append({
                "id": f"zone_{cell['zone']}_{cell_x}_{cell_y}",
                "name": f"zone {cell['zone']}",
                "x": cell_x * CELL,
                "y": cell_y * CELL,
                "width": CELL,
                "height": CELL,
                "rate": 0.1,
                "table": table
            })
        print(f"  cell {cell_x:2d},{cell_y:2d} model {cell['model']} -> {sum(r.count('.') + r.count('g') for r in cell_rows)} walkable tiles")

    spawn_cell_x, spawn_cell_y = 24, 23
    spawn = {
        "x": spawn_cell_x * CELL + 16,
        "y": spawn_cell_y * CELL + 17,
        "dir": "down"
    }
    world = {
        "id": "unova_full",
        "name": "Unova",
        "matrix": matrix,
        "width": width,
        "height": height,
        "tile": 16,
        "originX": -248,
        "originZ": -248,
        "spawn": spawn,
        "tiles": ["".join(row) for row in rows],
        "visual": {
            "originX": -248,
            "originZ": -248,
            "tile": 16,
            "cellSize": CELL,
            "heightScale": 16,
            "chunks": visual_chunks
        },
        "encounterZones": encounter_zones
    }
    out = (root / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(world, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {out} ({width}x{height} tiles, {len(visual_chunks)} cells, {len(encounter_zones)} encounter zones)")
    if height_fallbacks:
        print(f"Heights: {height_fallbacks} chunks fell back to GLB sampling")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
