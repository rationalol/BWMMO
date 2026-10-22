#!/usr/bin/env python3
"""Batch-extract every outdoor Unova matrix cell from the user's BW ROM.

This is the first stage of assembling the full overworld:

- resolves all 109 non-empty overworld cells from `a/0/0/9`
- extracts each cell's terrain BMD0 and prop placements from `a/0/0/8`
- converts terrain with the cell's map texture set (`a/0/1/4`)
- converts shared props once per (prop bundle, resource id) using `a/1/7/6`
- writes a `library.json` describing cell offsets and prop instances

Output stays under `client/assets/bw/` (gitignored). Indoor scenes use the
separate small map matrices in `a/0/0/9` and are not handled here yet.
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import (
    AREA_RECORD,
    ZONE_HEADER,
    extract_chunk,
    find_apicula,
    find_rom,
    lz11_decompress,
    model_name,
    prop_bundle_models,
    read_narc,
    run_apicula,
)


# Building models are shells; their doors are separate props placed at the
# building origin by the game. The client attaches them by filename, so export
# each door next to its building. Maps building prop name -> (door name, res id).
BUILDING_DOOR_PROPS = {
    "pc_01": ("door_pc", 93),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--out", default="client/assets/bw/unova_outdoor", help="output directory")
    parser.add_argument("--apicula", default=None, help="Apicula executable")
    parser.add_argument("--limit", type=int, default=0, help="only process the first N cells")
    parser.add_argument("--force", action="store_true", help="rebuild cell/prop assets")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    out = (root / args.out).resolve()
    cells_out = out / "cells"
    props_out = out / "props"
    raw_out = out / "raw"
    for directory in (cells_out, props_out, raw_out):
        directory.mkdir(parents=True, exist_ok=True)

    apicula = find_apicula(root, args.apicula)
    if apicula is None:
        print("Apicula not found. Put it in .tools/apicula or pass --apicula.", file=sys.stderr)
        return 1

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    matrices = read_narc(rom, "a/0/0/9")
    overworld = matrices[0]
    has_zones, _, width, height = struct.unpack_from("<HHHH", overworld)
    if not has_zones:
        raise SystemExit("overworld matrix has no zone grid")
    model_grid = struct.unpack_from(f"<{width * height}I", overworld, 8)
    zone_grid = struct.unpack_from(f"<{width * height}I", overworld, 8 + 4 * width * height)
    zone_data = read_narc(rom, "a/0/1/2")[0]
    area_data = bytes(rom.getFileByName("a/0/1/3"))
    chunks = read_narc(rom, "a/0/0/8")
    map_textures = read_narc(rom, "a/0/1/4")
    prop_bundles = read_narc(rom, "a/2/2/9")
    prop_textures = read_narc(rom, "a/1/7/6")

    cells: list[dict] = []
    seen: set[tuple[int, int]] = set()
    for y in range(height):
        for x in range(width):
            model_id = model_grid[y * width + x]
            zone_id = zone_grid[y * width + x]
            if model_id == 0xFFFFFFFF or zone_id == 0xFFFFFFFF:
                continue
            if (x, y) in seen:
                continue
            seen.add((x, y))
            header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
            area_id = header[2]
            area = AREA_RECORD.unpack_from(area_data, area_id * AREA_RECORD.size)
            bundle_id, texture_set = area[0], area[1]
            cells.append({
                "x": x,
                "y": y,
                "model": model_id,
                "zone": zone_id,
                "area": area_id,
                "texSet": texture_set,
                "bundle": bundle_id
            })

    if args.limit > 0:
        cells = cells[: args.limit]
    print(f"ROM:    {rom_path}")
    print(f"Output: {out}")
    print(f"Cells:  {len(cells)}")

    prop_cache: dict[tuple[int, int], dict] = {}
    prop_manifests: dict[str, dict] = {}
    for index, cell in enumerate(cells, start=1):
        model_id = cell["model"]
        texture_set = cell["texSet"]
        bundle_id = cell["bundle"]
        cell_dir = cells_out / f"cell_{cell['x']:02d}_{cell['y']:02d}"
        cell_dir.mkdir(parents=True, exist_ok=True)
        chunk = lz11_decompress(chunks[model_id])
        bmd, placements = extract_chunk(chunk)
        name = model_name(bmd)
        map_nsbmd = raw_out / f"map_{model_id}_{name}.nsbmd"
        map_nsbmd.write_bytes(bmd)

        map_tex_path = raw_out / f"map_tex_{texture_set}.nsbtx"
        if not map_tex_path.exists():
            map_tex_path.write_bytes(map_textures[texture_set])
        map_glb = cell_dir / f"{name}.glb"
        if args.force or not map_glb.exists():
            for old in cell_dir.glob("*"):
                if old.is_file():
                    old.unlink()
            run_apicula(apicula, [map_nsbmd, map_tex_path], cell_dir)

        if bundle_id not in prop_manifests:
            bundle = prop_bundles[bundle_id]
            models = prop_bundle_models(bundle)
            prop_manifests[str(bundle_id)] = {
                "textureSet": bundle_id,
                "models": {
                    str(res_id): prop_name for res_id, (prop_name, _) in models.items()
                }
            }
            prop_texture_path = raw_out / f"prop_tex_{bundle_id}.nsbtx"
            prop_texture_path.write_bytes(prop_textures[bundle_id])

        cell_props = []
        for placement in placements:
            res_id = placement["prop"]
            key = (bundle_id, res_id)
            if key not in prop_cache:
                bundle = prop_bundles[bundle_id]
                models = prop_bundle_models(bundle)
                if res_id not in models:
                    prop_cache[key] = {}
                    continue
                prop_name, prop_model = models[res_id]
                prop_dir = props_out / f"b{bundle_id}" / f"p{res_id}_{prop_name}"
                prop_dir.mkdir(parents=True, exist_ok=True)
                prop_nsbmd = raw_out / f"prop_{bundle_id}_{res_id}_{prop_name}.nsbmd"
                prop_nsbmd.write_bytes(prop_model)
                prop_glb = prop_dir / f"{prop_name}.glb"
                if args.force or not prop_glb.exists():
                    for old in prop_dir.glob("*"):
                        if old.is_file():
                            old.unlink()
                    run_apicula(
                        apicula,
                        [prop_nsbmd, raw_out / f"prop_tex_{bundle_id}.nsbtx"],
                        prop_dir
                    )
                prop_cache[key] = {
                    "file": f"props/b{bundle_id}/p{res_id}_{prop_name}/{prop_name}.glb",
                    "name": prop_name
                }
                if prop_name in BUILDING_DOOR_PROPS:
                    door_name, door_res_id = BUILDING_DOOR_PROPS[prop_name]
                    if door_res_id in models:
                        door_nsbmd = raw_out / f"prop_{bundle_id}_{door_res_id}_{door_name}.nsbmd"
                        door_nsbmd.write_bytes(models[door_res_id][1])
                        door_glb = prop_dir / f"{door_name}.glb"
                        if args.force or not door_glb.exists():
                            door_tmp = raw_out / f"door_tmp_{bundle_id}_{door_res_id}"
                            if door_tmp.exists():
                                shutil.rmtree(door_tmp)
                            run_apicula(
                                apicula,
                                [door_nsbmd, raw_out / f"prop_tex_{bundle_id}.nsbtx"],
                                door_tmp
                            )
                            converted = door_tmp / f"{door_name}.glb"
                            if converted.exists():
                                shutil.copy2(converted, door_glb)
                            shutil.rmtree(door_tmp)
            prop_info = prop_cache[key]
            if not prop_info:
                continue
            cell_props.append({
                "x": placement["x"],
                "y": placement["y"],
                "z": placement["z"],
                "rotation": placement["rotation"],
                "file": prop_info["file"]
            })

        cells[index - 1] = {
            **cell,
            "name": name,
            "mapFile": f"cells/cell_{cell['x']:02d}_{cell['y']:02d}/{name}.glb",
            "props": cell_props
        }
        print(f"  [{index:3d}/{len(cells)}] cell {cell['x']},{cell['y']} model {model_id} -> {name} ({len(cell_props)} props)")

    library = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "matrix": {"width": width, "height": height},
        "cellSize": 32,
        "tile": 16,
        "cells": cells,
        "propBundles": prop_manifests
    }
    (out / "library.json").write_text(
        json.dumps(library, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Done. {len(cells)} outdoor cells -> {out / 'library.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
