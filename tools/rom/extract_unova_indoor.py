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

import prop_resolve
from nds_fs import magic_archives

from extract_nuvema import (
    AREA_RECORD,
    ZONE_HEADER,
    extract_chunk,
    find_apicula,
    find_rom,
    lz11_decompress,
    model_name,
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
    parser.add_argument(
        "--strict-props",
        action="store_true",
        help="fail when a scene has prop ids no bundle supplies (default: warn and "
        "drop them; audit_assets.py lists them headlessly afterwards)",
    )
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
    # Indoor props live in their own AB bundle archive, separate from the
    # overworld one, each paired with a BTX0 archive of the same length. This
    # ROM ships a stripped name table, so the two are located by content and
    # disambiguated by how many of this batch's prop ids they resolve.
    file_table = [(index, bytes(data)) for index, data in enumerate(rom.files)]
    bundle_archives = magic_archives(file_table, b"AB")
    texture_archives = magic_archives(file_table, b"BTX0")
    if not bundle_archives:
        print("No AB prop bundle archive found in the ROM.", file=sys.stderr)
        return 1

    zone_count = len(zone_data) // ZONE_HEADER.size
    scenes: list[dict] = []
    model_pairs: set[tuple[int, int]] = set()

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
        # area[1] is the map texture set: it is what the map models are textured
        # with, and it is the tie-break when several prop bundles cover a scene
        # (see prop_resolve.py). It is *not* the bundle: applying texSet // 4 to
        # every zone leaves most interiors empty. area[0] is the overworld
        # fallback and must never be used here -- doing so furnished the
        # player's house with outdoor props and dropped the staircase.
        texture_set = area[1]
        scene_cells = []
        scene_props: list[int] = []
        scene_objects = 0
        for index, model_id in enumerate(cells):
            if model_id == 0xFFFFFFFF:
                continue
            cell_x, cell_y = index % width, index // width
            model_pairs.add((model_id, texture_set))
            chunk = lz11_decompress(chunks[model_id])
            _, placements = extract_chunk(chunk)
            scene_objects += prop_resolve.map_objects(placements)
            kept = [
                placement
                for placement in placements
                if placement["prop"] < prop_resolve.PROP_ID_LIMIT
            ]
            scene_props.extend(placement["prop"] for placement in kept)
            scene_cells.append({
                "x": cell_x,
                "y": cell_y,
                "model": model_id,
                "props": kept
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
            # Filled in below once the bundle archive is chosen.
            "bundle": None,
            "propIds": sorted(set(scene_props)),
            "mapObjects": scene_objects,
            "cells": scene_cells
        })

    if args.limit > 0:
        scenes = scenes[: args.limit]
        used_models = {cell["model"] for scene in scenes for cell in scene["cells"]}
        model_pairs = {(model_id, tex) for model_id, tex in model_pairs if model_id in used_models}

    interiors = [scene for scene in scenes if scene["propIds"]]
    print(f"ROM:    {rom_path}")
    print(f"Output: {out}")
    print(
        f"Scenes: {len(scenes)} ({len(interiors)} with furniture, "
        f"{len(scenes) - len(interiors)} map-only), model/tex pairs: {len(model_pairs)}"
    )

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

    # Choose the prop bundle archive, and then a bundle per scene.
    #
    # Both AB archives are scored the same way: how many scenes can be covered
    # by a single bundle, then how many ids in total. The indoor archive (64
    # bundles) wins, which matters because bundle 53 -- the Nuvema bedroom's --
    # exists only there. The rule itself lives in prop_resolve.py so the audit
    # and this extractor cannot drift apart.
    candidates = []
    for index, files in bundle_archives:
        tables = prop_resolve.prop_tables(files)
        picks = prop_resolve.assign(interiors, tables)
        candidates.append((prop_resolve.score(interiors, tables), index, files, tables, picks))
    candidates.sort(key=lambda item: item[0], reverse=True)
    (complete, covered), bundle_file, prop_bundles, prop_tables, picks = candidates[0]
    print(
        f"Prop bundles: file {bundle_file} ({len(prop_bundles)} bundles), "
        f"{complete}/{len(interiors)} scenes fully covered by their own texture-set bundle, "
        f"{covered} prop instances from that bundle"
    )

    unresolved: list[str] = []
    prop_pairs: set[tuple[int, int]] = set()
    for scene in scenes:
        bundle_id, missing = picks.get(scene["zone"], (None, []))
        scene["bundle"] = bundle_id
        if missing:
            unresolved.append(
                f'zone {scene["zone"]}: no bundle supplies prop {missing[:6]}'
            )
        if bundle_id is None:
            continue
        # A room's props are not confined to its own bundle: the same id has the
        # same model in every bundle that supplies it, so ids the preferred
        # bundle lacks are read from whichever bundle has them instead of being
        # dropped (see prop_resolve.sources).
        scene_sources = prop_resolve.sources(scene, prop_tables, bundle_id)
        scene["propSources"] = scene_sources
        for prop_id, source_bundle in scene_sources.items():
            prop_pairs.add((prop_id, source_bundle))
    if unresolved:
        for line in unresolved[:20]:
            print(f"  {line}", file=sys.stderr)
        print(
            f"Warning: {len(unresolved)} scenes reference prop ids that no bundle of the "
            f"chosen archive supplies; those props will be left out. Run "
            f"tools/rom/audit_assets.py --props to list them, or --strict-props to fail.",
            file=sys.stderr
        )
        if args.strict_props:
            return 1

    texture_matches = [
        files for _, files in texture_archives if len(files) == len(prop_bundles)
    ]
    if len(texture_matches) != 1:
        print(
            f"Error: expected one BTX0 prop texture archive with "
            f"{len(prop_bundles)} entries, found {len(texture_matches)}",
            file=sys.stderr
        )
        return 1
    prop_textures = texture_matches[0]
    print(f"Prop textures: {len(prop_textures)} entries (paired with the bundle archive)")

    # Props grouped by bundle.
    props_by_bundle: dict[int, list[tuple[int, str, bytes]]] = defaultdict(list)
    for res_id, bundle_id in sorted(prop_pairs):
        entry = prop_tables[bundle_id].get(res_id) if bundle_id < len(prop_tables) else None
        if entry is None:
            continue
        name, model = entry
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

    dropped: list[str] = []
    unplaced = 0
    for scene in scenes:
        scene_sources: dict[int, int] = scene.get("propSources") or {}
        for cell in scene["cells"]:
            model_id = cell["model"]
            cell["mapFile"] = map_file_by_model.get(model_id, "")
            rendered_props = []
            for placement in cell["props"]:
                source_bundle = scene_sources.get(placement["prop"])
                if source_bundle is None:
                    # No bundle of the archive supplies this id at all; that is
                    # already reported per zone above. Not an extraction error.
                    unplaced += 1
                    continue
                prop_file = prop_file_by_key.get((placement["prop"], source_bundle))
                if not prop_file:
                    dropped.append(
                        f'{scene["id"]} cell ({cell["x"]},{cell["y"]}) '
                        f'prop {placement["prop"]}'
                    )
                    continue
                rendered_props.append({
                    "x": placement["x"],
                    "y": placement["y"],
                    "z": placement["z"],
                    "rotation": placement["rotation"],
                    "file": prop_file
                })
            cell["props"] = rendered_props

    if dropped:
        for line in dropped[:20]:
            print(f"  unresolved {line}", file=sys.stderr)
        print(
            f"Error: {len(dropped)} prop placements could not be resolved",
            file=sys.stderr
        )
        return 1
    prop_total = sum(len(cell["props"]) for scene in scenes for cell in scene["cells"])
    print(
        f"Props placed: {prop_total} across {len(scenes)} scenes"
        + (f" ({unplaced} placements reference ids no bundle supplies)" if unplaced else "")
    )

    for scene in scenes:
        scene.pop("propSources", None)
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
