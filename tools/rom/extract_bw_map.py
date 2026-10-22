#!/usr/bin/env python3
"""Extract an overworld map matrix cell (Pokemon Black/White) for the 3D client.

The Nuvema extractor hardcodes one cell. This tool resolves any matrix cell from
the ROM, extracts its terrain/props/textures, converts them with Apicula, and
writes a placements manifest the client can load.

Example (Route 1 south and north):

    python tools/rom/extract_bw_map.py --cell 24,22 --out client/assets/bw/route1
    python tools/rom/extract_bw_map.py --cell 24,21 --out client/assets/bw/route1_north

Output stays in client/assets/bw/ (gitignored, personal use only).
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import (
    AREA_RECORD,
    NONE,
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


def parse_cell(value: str) -> tuple[int, int]:
    parts = value.split(",")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("cell must be X,Y")
    return int(parts[0]), int(parts[1])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--cell", required=True, type=parse_cell, help="matrix cell X,Y")
    parser.add_argument("--out", required=True, help="output asset directory")
    parser.add_argument("--apicula", default=None, help="Apicula executable")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    out = (root / args.out).resolve()
    map_out = out / "map"
    props_out = out / "props"
    raw_out = out / "raw"
    map_out.mkdir(parents=True, exist_ok=True)
    props_out.mkdir(parents=True, exist_ok=True)
    raw_out.mkdir(parents=True, exist_ok=True)

    print(f"ROM:   {rom_path}")
    print(f"Cell:  {args.cell}")
    print(f"Output:{out}")
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))

    matrices = read_narc(rom, "a/0/0/9")
    overworld = matrices[0]
    has_zones, _, width, height = struct.unpack_from("<HHHH", overworld)
    if not has_zones:
        raise SystemExit("overworld matrix has no zone grid")
    x, y = args.cell
    if not (0 <= x < width and 0 <= y < height):
        raise SystemExit(f"cell {args.cell} is outside the {width}x{height} matrix")
    cells = struct.unpack_from(f"<{width * height}I", overworld, 8)
    zone_grid = struct.unpack_from(f"<{width * height}I", overworld, 8 + 4 * width * height)
    model_id = cells[y * width + x]
    zone_id = zone_grid[y * width + x]
    if model_id == NONE or zone_id == NONE:
        raise SystemExit(f"cell {args.cell} has no map model/zone")

    zone_data = read_narc(rom, "a/0/1/2")[0]
    header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
    map_type, _, area_id, matrix_id, *rest = header
    fly = (rest[-3], rest[-2], rest[-1])
    if map_type != 0 or matrix_id != 0:
        raise SystemExit(f"zone {zone_id} is not an outdoor overworld zone")
    print(f"Zone:  id={zone_id} area={area_id} model={model_id} fly={fly}")

    area_data = bytes(rom.getFileByName("a/0/1/3"))
    area = AREA_RECORD.unpack_from(area_data, area_id * AREA_RECORD.size)
    prop_bundle_id, map_texture_set = area[0], area[1]
    print(f"Area:  prop bundle={prop_bundle_id} map texture set={map_texture_set}")

    chunks = read_narc(rom, "a/0/0/8")
    chunk = lz11_decompress(chunks[model_id])
    bmd, placements = extract_chunk(chunk)
    name = model_name(bmd)
    map_nsbmd = raw_out / f"{name}.nsbmd"
    map_nsbmd.write_bytes(bmd)
    print(f"Map:   {name} ({len(bmd)} bytes), {len(placements)} props")

    bundles = read_narc(rom, "a/2/2/9")
    if prop_bundle_id >= len(bundles):
        raise SystemExit("prop bundle index is out of range")
    bundle_models = prop_bundle_models(bundles[prop_bundle_id])
    used_ids = sorted({placement["prop"] for placement in placements})
    prop_inputs = []
    prop_files = {}
    for res_id in used_ids:
        if res_id not in bundle_models:
            print(f"Warning: prop res_id {res_id} not found in bundle {prop_bundle_id}", file=sys.stderr)
            continue
        prop_name, model = bundle_models[res_id]
        path = raw_out / f"prop_{res_id}_{prop_name}.nsbmd"
        path.write_bytes(model)
        prop_inputs.append(path)
        prop_files[res_id] = f"{prop_name}.glb"
        print(f"  prop {res_id}: {prop_name}")

    map_textures = read_narc(rom, "a/0/1/4")
    if map_texture_set >= len(map_textures):
        raise SystemExit("map texture set is out of range")
    map_tex = raw_out / "map_textures.nsbtx"
    map_tex.write_bytes(map_textures[map_texture_set])
    prop_textures = read_narc(rom, "a/1/7/6")
    if prop_bundle_id >= len(prop_textures):
        raise SystemExit("prop texture set is out of range")
    prop_tex = raw_out / "prop_textures.nsbtx"
    prop_tex.write_bytes(prop_textures[prop_bundle_id])

    apicula = find_apicula(root, args.apicula)
    if apicula is None:
        print(
            "Apicula was not found. Raw NSBMD/NSBTX files are in "
            f"{raw_out}; download Apicula into .tools/apicula or pass --apicula.",
            file=sys.stderr,
        )
        return 1

    print(f"Converting with {apicula}")
    for old in map_out.glob("*"):
        if old.is_file():
            old.unlink()
    for old in props_out.glob("*"):
        if old.is_file():
            old.unlink()
    run_apicula(apicula, [map_nsbmd, map_tex], map_out)
    if prop_inputs:
        run_apicula(apicula, prop_inputs + [prop_tex], props_out)

    manifest = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "cell": [x, y],
        "zone": zone_id,
        "mapFile": f"map/{name}.glb",
        "props": placements,
        "propFiles": prop_files,
    }
    (out / "placements.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Done. {name} assets -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
