#!/usr/bin/env python3
"""Headless audit of the extracted field assets, straight from the ROM.

Both classes of bug found here used to need the game running: furniture that
silently failed to resolve and went missing, and walk sheets whose left and
right frames were swapped so NPCs walked backwards. Both are data-pipeline
bugs, so both are checkable without a client.

``--props`` (default)
    Rebuilds every zone's prop placements from the ROM (zone header -> area
    record -> map matrix -> chunk -> placement table), resolves each scene's
    props with the rule in ``prop_resolve.py`` (its own texture-set bundle
    first, any other supplier for ids that bundle lacks), and compares the
    result against ``library.json`` -- the file the extractor actually wrote. Comparison is by
    prop *name*, because a numeric id resolves in dozens of bundles; names are
    the only honest signal. A wrong bundle, a prop the ROM supplies but the
    library dropped, a prop the library invented, or a model missing from disk
    all fail.

    The canary is the player's bedroom (zone 391): ``tv01``, ``stair_d01`` and
    ``plant01`` must resolve in the ROM *and* be present in the library. That
    is exactly what broke when props were resolved against ``area[0]``, the
    overworld fallback (6 for Nuvema): the bedroom came out empty while the
    house was furnished with outdoor props.

``--sprites`` (default)
    Reads the extracted walk sheets and checks, per frame, which way the sprite
    faces. ``walk_left`` must lean left, ``walk_right`` must lean right, and a
    down frame must show skin while an up frame must not.

``--self-test``
    Proves the props audit works without a freshly extracted library: it
    synthesises the library the current rule produces, asserts the audit
    passes, then synthesises the library the ``area[0]`` bug produced and
    asserts the audit fails and pinpoints the bedroom. A checker that cannot
    fail is not a checker.

Nothing here needs ndspy, apicula or a GPU: ``--rom`` only reads the image and
``--library``/``--sheets`` only read files the extractor already wrote.

    python3 tools/rom/audit_assets.py
    python3 tools/rom/audit_assets.py --props --json
    python3 tools/rom/audit_assets.py --self-test
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import tempfile
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prop_resolve  # noqa: E402
from nds_fs import NARC, NintendoDSRom, ZONE_HEADER, magic_archives  # noqa: E402
from extract_nuvema import (  # noqa: E402  (stdlib-only helpers)
    AREA_RECORD,
    extract_chunk,
    lz11_decompress,
)
from sprite_frames import face_offset, read_png_rgba, skin_pixels  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]

# Zone 391 is the player's bedroom: whoever breaks the indoor prop pipeline
# breaks this first, and the three props are visible from the spawn tile.
BEDROOM_ZONE = 391
BEDROOM_PROPS = ("tv01", "stair_d01", "plant01")


class AuditError(Exception):
    """The ROM layout does not match what this tool expects."""


def prop_name_key(name: str) -> str:
    """Normalise a prop name so the two spellings compare equal.

    The ROM's NSBMD names drop underscores (``pc01``) while the extracted glb
    files keep the model table's (``pc_01``); case is not meaningful either.
    """
    return name.replace("_", "").lower()


def named_file(rom: NintendoDSRom, path: str, names: dict[str, int]) -> bytes:
    """Raw bytes of a file the name table names directly."""
    index = names.get(path)
    if index is None:
        raise AuditError(f"the ROM's file name table has no {path}")
    return rom.file(index)


def named_archive(rom: NintendoDSRom, path: str, names: dict[str, int]) -> list[bytes]:
    """Members of a NARC the file name table names directly."""
    data = named_file(rom, path, names)
    try:
        return NARC(data).files
    except ValueError as error:
        raise AuditError(f"{path} is not a NARC archive: {error}") from error


def bundle_archives(rom: NintendoDSRom) -> list[tuple[int, list[bytes]]]:
    """The AB prop bundle archives, largest (indoor, 64 bundles) first.

    The name table stops before them: the indoor archive is the unnamed FAT 472
    and the outdoor one is FAT 471 (52 bundles; ``a/2/2/8`` = FAT 470 holds 6
    and is a decoy). Bundle 53 -- the bedroom's -- exists in the 64-bundle
    archive alone, which is why the archive is chosen by content and size, not
    by path.
    """
    archives = magic_archives(rom.every_file(), b"AB")
    if len(archives) < 2:
        raise AuditError(f"expected two AB prop bundle archives, found {len(archives)}")
    archives.sort(key=lambda item: len(item[1]), reverse=True)
    return archives


def scene_placements(rom: NintendoDSRom, names: dict[str, int]) -> dict:
    """Every zone with a map matrix, and what the ROM places in it."""
    chunks = named_archive(rom, "a/0/0/8", names)
    matrices = named_archive(rom, "a/0/0/9", names)
    zone_data = named_archive(rom, "a/0/1/2", names)[0]
    # a/0/1/3 is the bare record table (282 x 10 bytes), not a NARC.
    area_data = named_file(rom, "a/0/1/3", names)

    scenes: dict[int, dict] = {}
    for zone_id in range(len(zone_data) // ZONE_HEADER.size):
        header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
        area_id, matrix_id = header[2], header[3]
        if matrix_id == 0 or matrix_id >= len(matrices):
            continue
        matrix = matrices[matrix_id]
        if len(matrix) < 8:
            continue
        width, height = struct.unpack_from("<HH", matrix, 4)
        if not (1 <= width <= 128 and 1 <= height <= 128):
            continue
        area = AREA_RECORD.unpack_from(area_data, area_id * AREA_RECORD.size)
        cells = struct.unpack_from(f"<{width * height}I", matrix, 8)
        placements: list[dict] = []
        for index, model_id in enumerate(cells):
            if model_id == 0xFFFFFFFF or model_id >= len(chunks):
                continue
            try:
                chunk = lz11_decompress(chunks[model_id])
                _, found = extract_chunk(chunk)
            except (ValueError, struct.error):
                continue
            for placement in found:
                placements.append(
                    {
                        "prop": placement["prop"],
                        "cell": [index % width, index // width],
                    }
                )
        scenes[zone_id] = {
            "zone": zone_id,
            "area": area_id,
            "matrix": matrix_id,
            "texSet": area[1],
            "fallback": area[0],
            "placements": placements,
            "propIds": prop_resolve.prop_ids(placements),
            "mapObjects": prop_resolve.map_objects(placements),
        }
    return {
        "archives": {
            "chunks": names["a/0/0/8"],
            "matrices": names["a/0/0/9"],
            "areas": names["a/0/1/3"],
            "zones": names["a/0/1/2"],
            "chunkCount": len(chunks),
            "zoneCount": len(zone_data) // ZONE_HEADER.size,
        },
        "scenes": scenes,
    }


def choose_archive(rom: NintendoDSRom, scenes: dict[int, dict]) -> dict:
    """Score both AB archives and keep the one that serves the interior set."""
    interiors = [scene for scene in scenes.values() if scene["propIds"]]
    candidates = []
    for index, members in bundle_archives(rom):
        tables = prop_resolve.prop_tables(members)
        picks = prop_resolve.assign(interiors, tables)
        candidates.append(
            {
                "score": prop_resolve.score(interiors, tables),
                "index": index,
                "bundles": len(members),
                "tables": tables,
                "picks": picks,
            }
        )
    candidates.sort(key=lambda item: item["score"], reverse=True)
    best = candidates[0]
    best["interiors"] = interiors
    return best


def resolved_names(scene: dict, tables: list[dict], primary: int | None = None) -> Counter:
    """Prop names the ROM supplies for a scene, as a multiset.

    Uses the same union rule as the extractor: the primary bundle first, any
    other bundle that supplies the id otherwise.
    """
    source = prop_resolve.sources(scene, tables, primary)
    return Counter(
        prop_name_key(tables[source[placement["prop"]]][placement["prop"]][0])
        for placement in scene["placements"]
        if placement["prop"] in source
    )


def library_prop_names(scene: dict) -> list[str]:
    """Prop names a library scene claims to have placed."""
    names: list[str] = []
    for cell in scene.get("cells", []):
        for prop in cell.get("props", []):
            file = str(prop.get("file") or "")
            if not file:
                continue
            name = Path(file).name
            names.append(name[: -len(".glb")] if name.endswith(".glb") else name)
    return names


def library_prop_files(scene: dict) -> list[str]:
    """Prop model paths a library scene references."""
    return [
        str(prop["file"])
        for cell in scene.get("cells", [])
        for prop in cell.get("props", [])
        if prop.get("file")
    ]


def audit_props(rom: NintendoDSRom, library_path: Path) -> tuple[list[str], dict]:
    problems: list[str] = []
    scenes = scene_placements(rom, rom.named_files())["scenes"]
    chosen = choose_archive(rom, scenes)
    tables, picks = chosen["tables"], chosen["picks"]
    interiors = chosen["interiors"]

    conflicts = prop_resolve.name_conflicts(tables)
    if conflicts:
        sample = sorted(conflicts)[0]
        problems.append(
            f"{len(conflicts)} prop ids have different names in different bundles "
            f"(e.g. id {sample} = {sorted(conflicts[sample])}); the bundle-by-coverage "
            f"rule is unsafe"
        )

    unresolved = [
        {"zone": scene["zone"], "missing": picks[scene["zone"]][1]}
        for scene in interiors
        if picks[scene["zone"]][1]
    ]
    prop_placements = sum(len(scene["propIds"]) for scene in interiors)
    resolved = prop_placements - sum(len(item["missing"]) for item in unresolved)

    library: dict[int, dict] | None = None
    if library_path.is_file():
        library = {
            scene["zone"]: scene
            for scene in json.loads(library_path.read_text(encoding="utf-8"))["scenes"]
        }
    else:
        problems.append(
            f"library.json not found at {library_path}; run extract_unova_indoor.py"
        )

    bedroom = scenes.get(BEDROOM_ZONE)
    bedroom_bundle = picks.get(BEDROOM_ZONE, (None, []))[0]
    bedroom_rom = sorted(
        resolved_names(bedroom, tables, bedroom_bundle)
        if bedroom is not None and bedroom_bundle is not None
        else Counter()
    )
    bedroom_library = (
        sorted({prop_name_key(name) for name in library_prop_names(library[BEDROOM_ZONE])})
        if library is not None and BEDROOM_ZONE in library
        else []
    )
    bedroom_recorded = (
        library[BEDROOM_ZONE].get("bundle")
        if library is not None and BEDROOM_ZONE in library
        else None
    )
    canary = {prop_name_key(name) for name in BEDROOM_PROPS}
    if bedroom is None:
        problems.append(f"zone {BEDROOM_ZONE}: the bedroom has no map matrix in the ROM")
    if not canary.issubset(bedroom_rom):
        problems.append(
            f"zone {BEDROOM_ZONE}: the ROM does not supply "
            f"{sorted(canary - set(bedroom_rom))} through bundle {bedroom_bundle}; "
            f"the prop-bundle rule is wrong"
        )
    if library is not None and not canary.issubset(bedroom_library):
        problems.append(
            f"zone {BEDROOM_ZONE}: library.json is missing "
            f"{sorted(canary - set(bedroom_library))}; the bedroom is the canary for "
            f"the whole indoor pipeline"
        )

    # Aggregated so a stale library reports one line per failure kind instead of
    # one per zone: 270 nearly identical lines is noise, and noise gets ignored.
    wrong_bundle: list[dict] = []
    missing_props: list[dict] = []
    extra_props: list[dict] = []
    absent_props: list[dict] = []
    absent_maps_list: list[dict] = []
    missing_scenes: list[int] = []
    if library is not None:
        for scene in interiors:
            zone_id = scene["zone"]
            bundle = picks[zone_id][0]
            want = resolved_names(scene, tables, bundle)
            entry = library.get(zone_id)
            if entry is None:
                missing_scenes.append(zone_id)
                continue
            if entry.get("bundle") != bundle:
                wrong_bundle.append(
                    {
                        "zone": zone_id,
                        "library": entry.get("bundle"),
                        "rom": bundle,
                        "texSet": scene["texSet"],
                    }
                )
            got = Counter(prop_name_key(name) for name in library_prop_names(entry))
            missing, extra = want - got, got - want
            if missing:
                missing_props.append(
                    {"zone": zone_id, "count": sum(missing.values()), "names": sorted(missing)[:6]}
                )
            if extra:
                extra_props.append(
                    {"zone": zone_id, "count": sum(extra.values()), "names": sorted(extra)[:6]}
                )
            absent = [
                path
                for path in library_prop_files(entry)
                if not (library_path.parent / path).is_file()
            ]
            if absent:
                absent_props.append({"zone": zone_id, "count": len(absent), "file": absent[0]})
            absent_maps = [
                cell["mapFile"]
                for cell in entry.get("cells", [])
                if cell.get("mapFile")
                and not (library_path.parent / cell["mapFile"]).is_file()
            ]
            if absent_maps:
                absent_maps_list.append(
                    {"zone": zone_id, "count": len(absent_maps), "file": absent_maps[0]}
                )

        if wrong_bundle:
            sample = ", ".join(
                f"zone {item['zone']} recorded bundle {item['library']} instead of "
                f"{item['rom']} (texture set {item['texSet']})"
                for item in wrong_bundle[:3]
            )
            problems.append(
                f"{len(wrong_bundle)} of {len(interiors)} interiors resolved props against "
                f"the wrong bundle: {sample}"
            )
        if missing_scenes:
            problems.append(
                f"{len(missing_scenes)} interiors with props are missing from library.json "
                f"(e.g. zones {sorted(missing_scenes)[:8]})"
            )
        if missing_props:
            total_missing = sum(item["count"] for item in missing_props)
            sample = "; ".join(
                f"zone {item['zone']} lost {item['names']}" for item in missing_props[:3]
            )
            problems.append(
                f"{len(missing_props)} interiors are missing {total_missing} props the ROM "
                f"supplies, so they cannot render: {sample}"
            )
        if extra_props:
            total_extra = sum(item["count"] for item in extra_props)
            sample = "; ".join(
                f"zone {item['zone']} gained {item['names']}" for item in extra_props[:3]
            )
            problems.append(
                f"{len(extra_props)} interiors contain {total_extra} props the ROM does not "
                f"place there: {sample}"
            )
        if absent_props:
            problems.append(
                f"{sum(item['count'] for item in absent_props)} prop models referenced by "
                f"library.json are not on disk (e.g. {absent_props[0]['file']})"
            )
        if absent_maps_list:
            problems.append(
                f"{sum(item['count'] for item in absent_maps_list)} map models referenced by "
                f"library.json are not on disk (e.g. {absent_maps_list[0]['file']})"
            )

    report = {
        "indoorArchive": chosen["index"],
        "indoorBundles": chosen["bundles"],
        "zones": len(scenes),
        "interiorZones": len(interiors),
        "propPlacements": prop_placements,
        "resolved": resolved,
        "unresolvedZones": len(unresolved),
        "unresolved": unresolved[:20],
        "mapObjects": sum(scene["mapObjects"] for scene in scenes.values()),
        "bedroomBundle": bedroom_bundle,
        "bedroomRom": bedroom_rom,
        "bedroomLibrary": bedroom_library,
        "bedroomRecorded": bedroom_recorded,
        "library": str(library_path) if library is not None else None,
        "wrongBundle": wrong_bundle[:40],
        "missingProps": missing_props[:40],
        "extraProps": extra_props[:40],
        "missingScenes": missing_scenes[:40],
    }
    return problems, report


def audit_sprites(sheets: Path) -> tuple[list[str], dict]:
    problems: list[str] = []
    checked: list[dict] = []
    skipped: list[str] = []
    if not sheets.is_dir():
        return [f"sprite folder not found at {sheets}"], {}
    for actor_path in sorted(sheets.glob("npc_*/actor.json")):
        actor = json.loads(actor_path.read_text(encoding="utf-8"))
        frames_dir = actor_path.parent / "frames"
        animations = actor.get("animations", {})

        def frame(name: str) -> tuple[int, int, bytes] | None:
            indexes = animations.get(name) or []
            if not indexes:
                return None
            path = frames_dir / f"frame_{int(indexes[0]) + 1:02d}.png"
            if not path.is_file():
                problems.append(f"{actor_path.parent.name}: {name} frame {path.name} is missing")
                return None
            return read_png_rgba(path)

        left = frame("walk_left")
        right = frame("walk_right")
        down = frame("walk_down")
        up = frame("walk_up")
        if not (left and right and down and up):
            continue
        left_offset = face_offset(left[2], left[0], left[1])
        right_offset = face_offset(right[2], right[0], right[1])
        if left_offset is None or right_offset is None:
            skipped.append(actor_path.parent.name)
            continue
        down_skin = skin_pixels(down[2], down[0], down[1])
        up_skin = skin_pixels(up[2], up[0], up[1])
        if left_offset > -0.02:
            problems.append(
                f"{actor_path.parent.name}: walk_left leans right ({left_offset:+.2f}); "
                f"the sheet's direction order changed"
            )
        if right_offset < 0.02:
            problems.append(
                f"{actor_path.parent.name}: walk_right leans left ({right_offset:+.2f}); "
                f"horizontal walking would play the wrong side"
            )
        if down_skin < 8:
            problems.append(f"{actor_path.parent.name}: walk_down shows no face")
        if up_skin > down_skin:
            problems.append(
                f"{actor_path.parent.name}: walk_up shows more face than walk_down "
                f"({up_skin} vs {down_skin} skin pixels)"
            )
        checked.append(
            {
                "key": actor_path.parent.name,
                "left": round(left_offset, 2),
                "right": round(right_offset, 2),
                "downSkin": down_skin,
                "upSkin": up_skin,
            }
        )
    report = {"checked": len(checked), "skipped": skipped, "sheets": checked}
    return problems, report


def synthetic_library(scenes: dict[int, dict], tables: list[dict], bundle_of) -> dict:
    """The library.json the extractor produces for a given bundle rule.

    Mirrors ``extract_unova_indoor.py``: one prop entry per placement its bundle
    supplies; placements it cannot supply are not written.
    """
    entries = []
    for zone_id, scene in sorted(scenes.items()):
        if not scene["propIds"]:
            continue
        bundle = bundle_of(scene)
        source = prop_resolve.sources(scene, tables, bundle)
        cells: dict[tuple[int, int], dict] = {}
        for placement in scene["placements"]:
            prop_id = placement["prop"]
            if prop_id not in source:
                continue
            entry = tables[source[prop_id]][prop_id]
            cell = cells.setdefault(
                tuple(placement["cell"]),
                {
                    "x": placement["cell"][0],
                    "y": placement["cell"][1],
                    "model": 0,
                    "mapFile": "",
                    "props": [],
                },
            )
            cell["props"].append(
                {
                    "file": f"propsets/b{source[prop_id]}/{entry[0]}.glb",
                    "x": 0.0,
                    "y": 0.0,
                    "z": 0.0,
                    "rotation": 0.0,
                }
            )
        entries.append({"zone": zone_id, "bundle": bundle, "cells": list(cells.values())})
    return {"scenes": entries}


def self_test(rom: NintendoDSRom) -> int:
    """Prove the props audit passes the current rule and fails the old one."""
    failures: list[str] = []
    scenes = scene_placements(rom, rom.named_files())["scenes"]
    archives = bundle_archives(rom)
    indoor = prop_resolve.prop_tables(archives[0][1])
    outdoor = prop_resolve.prop_tables(archives[-1][1])

    for label, tables in (("indoor", indoor), ("outdoor", outdoor)):
        conflicts = prop_resolve.name_conflicts(tables)
        if conflicts:
            failures.append(
                f"{len(conflicts)} prop ids disagree between bundles of the {label} "
                f"archive; the coverage rule would change props silently"
            )

    chosen = choose_archive(rom, scenes)
    picks = chosen["picks"]
    complete, covered = chosen["score"]
    total = sum(len(scene["propIds"]) for scene in chosen["interiors"])

    with tempfile.TemporaryDirectory() as tmp:
        good = Path(tmp) / "good"
        good.mkdir()
        (good / "library.json").write_text(
            json.dumps(synthetic_library(scenes, indoor, lambda scene: picks[scene["zone"]][0])),
            encoding="utf-8",
        )
        problems, report = audit_props(rom, good / "library.json")
        interesting = [p for p in problems if "not on disk" not in p]
        if interesting:
            failures.append(
                "the current rule should audit clean, got:\n    "
                + "\n    ".join(interesting[:5])
            )

        buggy = Path(tmp) / "buggy"
        buggy.mkdir()
        (buggy / "library.json").write_text(
            json.dumps(synthetic_library(scenes, outdoor, lambda scene: scene["fallback"])),
            encoding="utf-8",
        )
        buggy_problems, buggy_report = audit_props(rom, buggy / "library.json")
        caught = [p for p in buggy_problems if "not on disk" not in p]
        if not caught:
            failures.append("the area[0] bug should have been caught")
        if not any("canary" in line for line in caught):
            failures.append("the area[0] bug should trip the bedroom canary")
        if buggy_report["bedroomRecorded"] == buggy_report["bedroomBundle"]:
            failures.append(
                f"the area[0] bug should make the bedroom record a bundle other than "
                f"{buggy_report['bedroomBundle']}, but it recorded "
                f"{buggy_report['bedroomRecorded']}"
            )

    if report["bedroomBundle"] != 53:
        failures.append(
            f"the bedroom resolved through bundle {report['bedroomBundle']}, expected 53"
        )
    if complete == 0:
        failures.append("no scene is fully covered by its own texture-set bundle")

    if failures:
        print("self-test FAILED")
        for line in failures:
            print(f"  - {line}")
        return 1
    print(
        f"self-test passed: archive fit {complete}/{len(chosen['interiors'])} scenes via "
        f"their own texture-set bundle; {report['resolved']}/{report['propPlacements']} "
        f"prop instances resolvable by the union rule; bedroom -> bundle "
        f"{report['bedroomBundle']}; the area[0] rule trips the canary"
    )
    return 0


def REPO(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else (ROOT / path)


def find_rom(value: str) -> Path:
    path = Path(value)
    if path.is_file():
        return path
    if path.is_dir():
        candidates = sorted(path.glob("*.nds"))
        if candidates:
            return candidates[0]
    candidates = sorted(ROOT.glob("*.nds"))
    if candidates:
        return candidates[0]
    raise AuditError(f"no .nds ROM found in {value} or {ROOT}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--library",
        default="client/assets/bw/unova_indoor/library.json",
        help="the extracted indoor scene library to compare against",
    )
    parser.add_argument(
        "--sheets", default="client/assets/bw/overworld", help="extracted walk sheets"
    )
    parser.add_argument("--props", action="store_true", help="audit indoor prop coverage")
    parser.add_argument("--sprites", action="store_true", help="audit walk-sheet directions")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove the audit catches the historical prop-bundle bug",
    )
    parser.add_argument("--json", action="store_true", help="print a machine-readable report")
    args = parser.parse_args()

    run_props = args.props or not (args.sprites or args.self_test)
    run_sprites = args.sprites or not (args.props or args.self_test)

    problems: list[str] = []
    report: dict = {}
    try:
        rom_path = find_rom(args.rom)
        if args.self_test:
            return self_test(NintendoDSRom.open(rom_path))
        report["rom"] = str(rom_path)
        rom = NintendoDSRom.open(rom_path)
        if run_props:
            prop_problems, prop_report = audit_props(rom, REPO(args.library))
            problems.extend(prop_problems)
            report["props"] = prop_report
        if run_sprites:
            sprite_problems, sprite_report = audit_sprites(REPO(args.sheets))
            problems.extend(sprite_problems)
            report["sprites"] = sprite_report
    except AuditError as error:
        print(f"audit failed: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"problems": problems, "report": report}, indent=2))
        return 1 if problems else 0

    if "props" in report:
        props = report["props"]
        print(
            f"props:   bundle archive {props['indoorArchive']} "
            f"({props['indoorBundles']} bundles), {props['interiorZones']} interiors "
            f"of {props['zones']} zones"
        )
        print(
            f"         {props['resolved']}/{props['propPlacements']} prop instances "
            f"resolve; {props['unresolvedZones']} interiors need an id no bundle has; "
            f"{props['mapObjects']} placements are map objects (not furniture)"
        )
        if props["unresolved"]:
            sample = ", ".join(
                f"zone {item['zone']} ({len(item['missing'])})"
                for item in props["unresolved"][:6]
            )
            print(f"         unresolved: {sample}")
        print(
            f"         bedroom: bundle {props['bedroomBundle']} -> "
            f"{', '.join(props['bedroomRom']) or '(none)'}"
        )
        print(f"         bedroom library: {', '.join(props['bedroomLibrary']) or '(none)'}")
    if "sprites" in report:
        sprites = report["sprites"]
        print(
            f"sprites: {sprites['checked']} sheets checked, "
            f"{len(sprites['skipped'])} without skin (Pokémon/props)"
        )
        for sheet in sprites["sheets"]:
            print(
                f"         {sheet['key']:<10} left {sheet['left']:+.2f}  "
                f"right {sheet['right']:+.2f}  "
                f"face {sheet['downSkin']}/{sheet['upSkin']}"
            )
    if problems:
        print()
        for line in problems:
            print(f"  FAIL {line}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    print("\naudit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
