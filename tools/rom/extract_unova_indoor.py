#!/usr/bin/env python3
"""Batch-extract all indoor Unova scenes referenced by zone headers.

Indoor scenes use the small model matrices in `a/0/0/9` (files other than 0).
Each zone header names an area (props/texture set) and a matrix file. This tool:

- builds one scene per zone with matrix_id != 0
- batches map models by texture set so PNGs are shared
- batches props by prop bundle so props are shared
- writes a scene library with cell offsets and prop instances

Output stays under client/assets/bw/ (gitignored). Warps and NPCs are not
decoded in this stage.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import defaultdict
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--out", default="client/assets/bw/unova_indoor", help="output directory")
    parser.add_argument("--apicula", default=None, help="Apicula executable")
    parser.add_argument("--limit", type=int, default=0, help="only process the first N scenes")
    parser.add_argument("--force", action="store_true", help="rebuild asset folders")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    out = (root / args.out).resolve()
    mapset_root = out / "mapsets"
    propset_root = out / "propsets"
    raw_root = out / "raw"
    for directory in (mapset_root, propset_root, raw_root):
        directory.mkdir(parents=True, exist_ok=True)

    apicula = find_apicula(root, args.apicula)
    if apicula is None:
        print("Apicula not found. Put it in .tools/apicula or pass --apicula.", file=sys.stderr)
        return 1

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    matrices = read_narc(rom, "a/0/0/9")
    zone_data = read_narc(rom, "a/0/1/2")[0]
    area_data = bytes(rom.getFileByName("a/0/1/3"))
    chunks = read_narc(rom, "a/0/0/8")
    map_textures = read_narc(rom, "a/0/1/4")
    prop_bundles = read_narc(rom, "a/2/2/9")
    prop_textures = read_narc(rom, "a/1/7/6")

    zone_count = len(zone_data) // ZONE_HEADER.size
    scenes: list[dict] = []
    model_pairs: set[tuple[int, int]] = set()
    prop_pairs: set[tuple[int, int]] = set()

    for zone_id in range(zone_count):
        header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
        matrix_id = header[3]
        area_id = header[2]
        if matrix_id == 0:
            continue
        if matrix_id >= len(matrices):
            print(f"Warning: zone {zone_id} matrix {matrix_id} is out of range", file=sys.stderr)
            continue
        matrix = matrices[matrix_id]
        if len(matrix) < 8:
            continue
        _, _, width, height = struct.unpack_from("<HHHH", matrix)
        cells = struct.unpack_from(f"<{width * height}I", matrix, 8)
        area = AREA_RECORD.unpack_from(area_data, area_id * AREA_RECORD.size)
        bundle_id, texture_set = area[0], area[1]
        scene_cells = []
        for index, model_id in enumerate(cells):
            if model_id == 0xFFFFFFFF:
                continue
            cell_x, cell_y = index % width, index // width
            model_pairs.add((model_id, texture_set))
            chunk = lz11_decompress(chunks[model_id])
            _, placements = extract_chunk(chunk)
            for placement in placements:
                prop_pairs.add((placement["prop"], bundle_id))
            scene_cells.append({
                "x": cell_x,
                "y": cell_y,
                "model": model_id,
                "props": placements
            })
        if not scene_cells:
            continue
        scenes.append({
            "id": f"zone_{zone_id}",
            "zone": zone_id,
            "area": area_id,
            "matrix": matrix_id,
            "width": width,
            "height": height,
            "texSet": texture_set,
            "bundle": bundle_id,
            "cells": scene_cells
        })

    if args.limit > 0:
        scenes = scenes[: args.limit]
        used_models = {cell["model"] for scene in scenes for cell in scene["cells"]}
        model_pairs = {(model_id, tex) for model_id, tex in model_pairs if model_id in used_models}
        used_props = {
            placement["prop"]
            for scene in scenes
            for cell in scene["cells"]
            for placement in cell["props"]
        }
        prop_pairs = {(res_id, bundle) for res_id, bundle in prop_pairs if res_id in used_props}

    print(f"ROM:    {rom_path}")
    print(f"Output: {out}")
    print(f"Scenes: {len(scenes)}, model/tex pairs: {len(model_pairs)}, prop pairs: {len(prop_pairs)}")

    # Resolve BMD names and group models by texture set.
    model_info: dict[int, tuple[str, bytes]] = {}
    names_by_tex: dict[int, list[tuple[int, str]]] = defaultdict(list)
    for model_id, texture_set in sorted(model_pairs):
        chunk = lz11_decompress(chunks[model_id])
        bmd, _ = extract_chunk(chunk)
        name = model_name(bmd)
        model_info[model_id] = (name, bmd)
        names_by_tex[texture_set].append((model_id, name))

    map_file_by_model: dict[int, str] = {}
    for texture_set, entries in names_by_tex.items():
        counts = defaultdict(int)
        for _, name in entries:
            counts[name] += 1
        batch = [(model_id, name) for model_id, name in entries if counts[name] == 1]
        duplicates = [(model_id, name) for model_id, name in entries if counts[name] > 1]
        target = mapset_root / f"tex_{texture_set}"
        target.mkdir(parents=True, exist_ok=True)
        texture_path = raw_root / f"map_tex_{texture_set}.nsbtx"
        texture_path.write_bytes(map_textures[texture_set])

        inputs = []
        for model_id, name in batch:
            _, bmd = model_info[model_id]
            nsbmd = raw_root / f"map_{model_id}_{name}.nsbmd"
            nsbmd.write_bytes(bmd)
            inputs.append(nsbmd)
            map_file_by_model[model_id] = f"mapsets/tex_{texture_set}/{name}.glb"
        if inputs:
            if args.force:
                for old in target.glob("*"):
                    if old.is_file():
                        old.unlink()
            run_apicula(apicula, inputs + [texture_path], target)
            print(f"  tex {texture_set}: {len(inputs)} models -> {target.name}")

        for model_id, name in duplicates:
            _, bmd = model_info[model_id]
            nsbmd = raw_root / f"map_{model_id}_{name}.nsbmd"
            nsbmd.write_bytes(bmd)
            target = mapset_root / f"tex_{texture_set}" / f"m{model_id}_{name}"
            target.mkdir(parents=True, exist_ok=True)
            if args.force:
                for old in target.glob("*"):
                    if old.is_file():
                        old.unlink()
            run_apicula(apicula, [nsbmd, texture_path], target)
            map_file_by_model[model_id] = f"mapsets/tex_{texture_set}/m{model_id}_{name}/{name}.glb"
            print(f"  tex {texture_set}: duplicate {name} model {model_id} -> {target.name}")

    # Props grouped by bundle.
    props_by_bundle: dict[int, list[tuple[int, str, bytes]]] = defaultdict(list)
    for res_id, bundle_id in sorted(prop_pairs):
        bundle = prop_bundles[bundle_id]
        models = prop_bundle_models(bundle)
        if res_id not in models:
            continue
        name, model = models[res_id]
        props_by_bundle[bundle_id].append((res_id, name, model))
    prop_file_by_key: dict[tuple[int, int], str] = {}
    for bundle_id, entries in props_by_bundle.items():
        counts = defaultdict(int)
        for _, name, _ in entries:
            counts[name] += 1
        batch = [(res_id, name, model) for res_id, name, model in entries if counts[name] == 1]
        duplicates = [(res_id, name, model) for res_id, name, model in entries if counts[name] > 1]
        target = propset_root / f"b{bundle_id}"
        target.mkdir(parents=True, exist_ok=True)
        texture_path = raw_root / f"prop_tex_{bundle_id}.nsbtx"
        texture_path.write_bytes(prop_textures[bundle_id])
        inputs = []
        for res_id, name, model in batch:
            nsbmd = raw_root / f"prop_{bundle_id}_{res_id}_{name}.nsbmd"
            nsbmd.write_bytes(model)
            inputs.append(nsbmd)
            prop_file_by_key[(res_id, bundle_id)] = f"propsets/b{bundle_id}/{name}.glb"
        if inputs:
            if args.force:
                for old in target.glob("*"):
                    if old.is_file():
                        old.unlink()
            run_apicula(apicula, inputs + [texture_path], target)
            print(f"  props {bundle_id}: {len(inputs)} models -> {target.name}")
        for res_id, name, model in duplicates:
            nsbmd = raw_root / f"prop_{bundle_id}_{res_id}_{name}.nsbmd"
            nsbmd.write_bytes(model)
            target = propset_root / f"b{bundle_id}" / f"p{res_id}_{name}"
            target.mkdir(parents=True, exist_ok=True)
            if args.force:
                for old in target.glob("*"):
                    if old.is_file():
                        old.unlink()
            run_apicula(apicula, [nsbmd, texture_path], target)
            prop_file_by_key[(res_id, bundle_id)] = (
                f"propsets/b{bundle_id}/p{res_id}_{name}/{name}.glb"
            )

    for scene in scenes:
        bundle_id = scene["bundle"]
        for cell in scene["cells"]:
            model_id = cell["model"]
            cell["mapFile"] = map_file_by_model.get(model_id, "")
            rendered_props = []
            for placement in cell["props"]:
                prop_file = prop_file_by_key.get((placement["prop"], bundle_id))
                if not prop_file:
                    continue
                rendered_props.append({
                    "x": placement["x"],
                    "y": placement["y"],
                    "z": placement["z"],
                    "rotation": placement["rotation"],
                    "file": prop_file
                })
            cell["props"] = rendered_props

    library = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "cellSize": 32,
        "tile": 16,
        "scenes": scenes
    }
    (out / "library.json").write_text(
        json.dumps(library, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Done. {len(scenes)} indoor scenes -> {out / 'library.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
