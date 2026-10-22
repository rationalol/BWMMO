#!/usr/bin/env python3
"""Build collision + visual data for every extracted indoor Unova scene.

Input:  client/assets/bw/unova_indoor/library.json + shared cell GLBs
Output: server/content/worlds/unova_indoor.json

Collision comes from each map chunk's permission grid in `a/0/0/8`. Scenes whose
chunks are NG/RD (no terrain permissions) fall back to sampling the cell GLB.
Visual chunks reference the shared mapset/propset files directly.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from build_unova_world import CELL, encode_heights, sample_cell, sample_cell_heights
from extract_nuvema import find_rom, lz11_decompress, permission_rows, read_narc


def indoor_char(name: str) -> str:
    lower = name.lower()
    walkable = (
        lower.startswith("bc_jimen")
        or lower.startswith("bc_michi")
        or lower.startswith("floor")
        or lower.startswith("yuka")
        or "yuka" in lower
        or "floor" in lower
        or "carpet" in lower
        or "tatami" in lower
        or "mat" in lower
        or lower.startswith("in02_step")
        or "step" in lower
        or "stairs" in lower
        or "kaidan" in lower
        or lower.startswith("bc_gate")
        or lower.startswith("fhgenkan")
        or lower.startswith("fhyuka")
        or lower.startswith("m_lab01")
    )
    return "." if walkable else "#"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--assets", default="client/assets/bw/unova_indoor", help="indoor asset dir")
    parser.add_argument("--out", default="server/content/worlds/unova_indoor.json", help="output JSON")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    asset_dir = (root / args.assets).resolve()
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    chunks = read_narc(rom, "a/0/0/8")
    library = json.loads((asset_dir / "library.json").read_text(encoding="utf-8"))
    fallback_cache: dict[str, list[str]] = {}
    height_cache: dict[str, str] = {}
    scenes = []
    empty = 0
    fallback_scenes = 0
    for index, scene in enumerate(library["scenes"], start=1):
        width = scene["width"] * CELL
        height = scene["height"] * CELL
        rows = [["#"] * width for _ in range(height)]
        visual_chunks = []
        used_fallback = False
        for cell in scene["cells"]:
            map_file = cell["mapFile"]
            chunk = lz11_decompress(chunks[cell["model"]])
            cell_rows = permission_rows(chunk, CELL, CELL, CELL)
            if cell_rows is None:
                used_fallback = True
                if map_file not in fallback_cache:
                    fallback_cache[map_file] = sample_cell(asset_dir / map_file, indoor_char)
                cell_rows = fallback_cache[map_file]
            for local_y, row in enumerate(cell_rows):
                for local_x, char in enumerate(row):
                    rows[cell["y"] * CELL + local_y][cell["x"] * CELL + local_x] = char
            if map_file not in height_cache:
                height_cache[map_file] = encode_heights(
                    sample_cell_heights(asset_dir / map_file)
                )
            visual_chunks.append({
                "asset": f"unova_indoor/zone_{scene['zone']}/{cell['x']}_{cell['y']}",
                "cellX": cell["x"],
                "cellY": cell["y"],
                "offsetX": cell["x"] * 512,
                "offsetZ": cell["y"] * 512,
                "mapFile": f"unova_indoor/{map_file}",
                "heights": height_cache[map_file],
                "props": [
                    {
                        "x": prop["x"],
                        "y": prop["y"],
                        "z": prop["z"],
                        "rotation": prop["rotation"],
                        "file": f"unova_indoor/{prop['file']}",
                    }
                    for prop in cell.get("props", [])
                ],
            })
        walkable = sum(row.count(".") + row.count("g") for row in rows)
        if walkable == 0:
            empty += 1
        if used_fallback:
            fallback_scenes += 1
        scenes.append({
            "id": scene["id"],
            "zone": scene["zone"],
            "area": scene["area"],
            "matrix": scene["matrix"],
            "width": width,
            "height": height,
            "tile": 16,
            "originX": -248,
            "originZ": -248,
            "visual": {
                "originX": -248,
                "originZ": -248,
                "tile": 16,
                "cellSize": CELL,
                "heightScale": 16,
                "chunks": visual_chunks,
            },
            "tiles": ["".join(row) for row in rows],
        })
        print(f"  [{index:3d}/{len(library['scenes'])}] {scene['id']} {width}x{height} walkable {walkable}")

    out = (root / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps({"source": "Pokemon Black/White ROM (local extraction)", "scenes": scenes}, indent=2)
        + "\n",
        encoding="utf-8"
    )
    print(
        f"Wrote {out} ({len(scenes)} scenes, {empty} empty collisions, "
        f"{fallback_scenes} fallback scenes)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
