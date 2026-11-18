#!/usr/bin/env python3
"""One-click audit of every map and its extracted ROM assets.

This does not replace looking at the game, but it catches the classes of
regressions that are easy to miss while touring 386 maps by hand:

- missing map/prop GLBs or manifests
- portals whose target map/tile is missing
- spawn/portal tiles blocked by NPCs
- non-service story NPCs left in indoor maps
- adjacent walkable tiles with a >24 unit step (invisible walls such as the
  Pinwheel Forest entrance before the ROM height grid was used)
- light/glow materials still rendered with plain alpha blending (white cards
  such as d2_hika02 at the Pinwheel Forest entrance)

Usage:
    python tools/rom/audit_maps.py
    python tools/rom/audit_maps.py --report .tools/map-audit/report.md
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import struct
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None

try:
    import ndspy.rom
    from extract_nuvema import (
        AREA_RECORD,
        ZONE_HEADER,
        extract_chunk,
        find_rom,
        lz11_decompress,
        prop_bundle_models,
        read_narc,
    )
except ImportError:
    ndspy = None


ROOT = Path(__file__).resolve().parents[2]
MAPS = ROOT / "server" / "content" / "maps"
ASSETS = ROOT / "client" / "assets" / "bw"
WALKABLE = set(".,gf=P")
SERVICE_KINDS = {"healer", "shop", "pc"}
MAX_STEP_UP = 24.0
MAX_STEP_DOWN = 128.0
PORTAL_NEAR = 3
LIGHT_PATTERN = re.compile(r"(hika|hikari|light|glow|mori01s)", re.IGNORECASE)
HANDLED_ALPHA = re.compile(r"^(ki|hana|kusa|r01_|mizu|sea|kage|saku|shadow)", re.IGNORECASE)


def load_maps() -> dict[str, dict]:
    result: dict[str, dict] = {}
    for path in sorted(MAPS.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and "id" in data:
            result[str(data["id"])] = data
    return result


class Heights:
    def __init__(self, map_data: dict) -> None:
        visual = map_data.get("visual") or {}
        self.cell_size = max(1, int(visual.get("cellSize", 32)))
        self.chunks: dict[tuple[int, int], tuple[int, ...]] = {}
        for chunk in visual.get("chunks", []):
            encoded = chunk.get("heights")
            if not encoded:
                continue
            raw = base64.b64decode(encoded)
            values = struct.unpack(f"<{len(raw) // 2}h", raw)
            self.chunks[
                (int(chunk.get("cellX", 0)), int(chunk.get("cellY", 0)))
            ] = values

    def at(self, x: int, y: int) -> float:
        cell = (x // self.cell_size, y // self.cell_size)
        values = self.chunks.get(cell)
        if values is None:
            return 0.0
        index = (y % self.cell_size) * self.cell_size + (x % self.cell_size)
        if index < 0 or index >= len(values):
            return 0.0
        return float(values[index]) / 16.0


def tile(map_data: dict, x: int, y: int) -> str:
    tiles = map_data.get("tiles") or []
    if y < 0 or y >= len(tiles):
        return "#"
    row = str(tiles[y])
    if x < 0 or x >= len(row):
        return "#"
    return row[x]


def is_walkable(map_data: dict, x: int, y: int) -> bool:
    return tile(map_data, x, y) in WALKABLE


def can_step(heights: Heights, a: tuple[int, int], b: tuple[int, int]) -> bool:
    delta = heights.at(*b) - heights.at(*a)
    return delta <= MAX_STEP_UP and delta >= -MAX_STEP_DOWN


def reachable(
    map_data: dict,
    heights: Heights,
    blocked: set[tuple[int, int]] | None = None,
) -> set[tuple[int, int]]:
    blocked = blocked or set()
    spawn = map_data.get("spawn") or {}
    start = (int(spawn.get("x", 0)), int(spawn.get("y", 0)))
    if not is_walkable(map_data, *start) or start in blocked:
        return set()
    seen = {start}
    queue = deque([start])
    while queue:
        x, y = queue.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nxt = (x + dx, y + dy)
            if nxt in seen or nxt in blocked:
                continue
            if not is_walkable(map_data, *nxt):
                continue
            if not can_step(heights, (x, y), nxt):
                continue
            seen.add(nxt)
            queue.append(nxt)
    return seen


def portal_sources(map_data: dict) -> set[tuple[int, int]]:
    return {
        (int(portal.get("x", 0)), int(portal.get("y", 0)))
        for portal in map_data.get("portals", [])
    }


def outdoor_asset_path(map_data: dict, asset: str) -> Path:
    return ASSETS / asset


def resolve_prop_path(asset: str, filename: str) -> Path:
    if filename.startswith("res://"):
        return ROOT / filename.replace("res://", "client/", 1)
    if filename.startswith(("unova_outdoor/", "unova_indoor/")):
        return ASSETS / filename
    if "/" in filename:
        return ASSETS / filename
    return ASSETS / asset / "props" / filename


def collect_glbs(maps: dict[str, dict]) -> tuple[dict[Path, set[str]], list[str]]:
    """Return referenced GLBs and asset errors."""
    glbs: dict[Path, set[str]] = defaultdict(set)
    errors: list[str] = []

    # Outdoor resource manifests.
    outdoor_root = ASSETS / "unova_outdoor"
    library_path = outdoor_root / "library.json"
    if library_path.exists():
        library = json.loads(library_path.read_text(encoding="utf-8"))
        for cell in library.get("cells", []):
            cell_asset = f"unova_outdoor/{Path(cell['mapFile']).parent.as_posix()}"
            map_path = outdoor_root / cell["mapFile"]
            if map_path.exists():
                glbs[map_path].add("outdoor-cell")
            else:
                errors.append(f"missing outdoor cell map: {cell['mapFile']}")
            manifest = map_path.parent / "placements.json"
            if not manifest.exists():
                errors.append(f"missing cell manifest: {manifest.relative_to(ROOT)}")
                continue
            placement = json.loads(manifest.read_text(encoding="utf-8"))
            for prop in placement.get("props", []):
                filename = str(prop.get("file", ""))
                if filename == "":
                    filename = str(placement.get("propFiles", {}).get(str(prop.get("prop", 0)), ""))
                path = resolve_prop_path(cell_asset, filename)
                if path.exists():
                    glbs[path].add("outdoor-prop")
                else:
                    errors.append(f"missing outdoor prop: {filename}")

    # Server map visuals (indoor and separate matrices).
    for map_id, map_data in maps.items():
        visual = map_data.get("visual") or {}
        for chunk in visual.get("chunks", []):
            if "mapFile" in chunk:
                path = ASSETS / str(chunk["mapFile"])
            else:
                asset = str(chunk.get("asset", ""))
                manifest_path = ASSETS / asset / "placements.json"
                if not manifest_path.exists():
                    errors.append(f"{map_id}: missing chunk manifest {asset}")
                    continue
                placement = json.loads(manifest_path.read_text(encoding="utf-8"))
                map_file = str(placement.get("mapFile", ""))
                path = ASSETS / asset / map_file if map_file else None
                for prop in placement.get("props", []):
                    filename = str(prop.get("file", ""))
                    if filename == "":
                        filename = str(placement.get("propFiles", {}).get(str(prop.get("prop", 0)), ""))
                    if filename == "":
                        continue
                    prop_path = resolve_prop_path(asset, filename)
                    if prop_path.exists():
                        glbs[prop_path].add("outdoor-prop")
                    else:
                        errors.append(f"{map_id}: missing prop {filename}")
            if path is None:
                continue
            if not path.exists():
                errors.append(f"{map_id}: missing visual map {path.relative_to(ROOT)}")
                continue
            glbs[path].add(f"map:{map_id}")
            if "mapFile" in chunk:
                for prop in chunk.get("props", []):
                    filename = str(prop.get("file", ""))
                    if filename == "":
                        continue
                    prop_path = resolve_prop_path(str(chunk.get("asset", "")), filename)
                    if prop_path.exists():
                        glbs[prop_path].add("indoor-prop")
                    else:
                        errors.append(f"{map_id}: missing prop {filename}")
    return glbs, errors


def audit_materials(glbs: dict[Path, set[str]]) -> tuple[list[str], list[str], dict[str, dict]]:
    errors: list[str] = []
    warnings: list[str] = []
    stats: dict[str, dict] = {}
    texture_alpha_cache: dict[Path, tuple[int, int] | None] = {}

    for path, roles in glbs.items():
        if path.suffix.lower() != ".glb":
            continue
        try:
            data = path.read_bytes()
            json_length = struct.unpack_from("<I", data, 12)[0]
            document = json.loads(data[20:20 + json_length])
        except Exception as error:  # noqa: BLE001 - report malformed asset
            errors.append(f"cannot read {path.relative_to(ROOT)}: {error}")
            continue
        images = document.get("images", [])
        textures = document.get("textures", [])
        for material in document.get("materials", []):
            name = str(material.get("name", ""))
            alpha_mode = str(material.get("alphaMode", "OPAQUE")).upper()
            info = stats.setdefault(name, {
                "files": 0,
                "light": bool(LIGHT_PATTERN.search(name)),
                "alpha_modes": Counter(),
                "examples": [],
                "issues": set(),
            })
            info["files"] += 1
            info["alpha_modes"][alpha_mode] += 1
            if len(info["examples"]) < 3:
                info["examples"].append(path.relative_to(ROOT).as_posix())

            pbr = material.get("pbrMetallicRoughness") or {}
            texture_index = (pbr.get("baseColorTexture") or {}).get("index")
            texture_path: Path | None = None
            if texture_index is not None and texture_index < len(textures):
                source = textures[texture_index].get("source")
                if source is not None and source < len(images):
                    uri = images[source].get("uri")
                    if uri:
                        texture_path = (path.parent / uri).resolve()
                        if not texture_path.exists():
                            errors.append(
                                f"{path.relative_to(ROOT)}: missing texture {texture_path.name}"
                            )
                            texture_path = None
            alpha_range = None
            if texture_path is not None and Image is not None:
                if texture_path not in texture_alpha_cache:
                    try:
                        image = Image.open(texture_path).convert("RGBA")
                        texture_alpha_cache[texture_path] = image.getchannel("A").getextrema()
                    except Exception:  # noqa: BLE001 - report below
                        texture_alpha_cache[texture_path] = None
                alpha_range = texture_alpha_cache[texture_path]
            if info["light"]:
                info["issues"].add("light")
                warnings.append(
                    f"light/glow material {name} uses {alpha_mode}; "
                    f"verify it renders soft, not as a white card ({info['examples'][0]})"
                )
            if (
                alpha_range is not None
                and alpha_mode == "OPAQUE"
                and alpha_range[0] < 250
                and not HANDLED_ALPHA.match(name)
            ):
                info["issues"].add("alpha-on-opaque")
                warnings.append(
                    f"material {name} is OPAQUE but its texture has alpha "
                    f"{alpha_range[0]}..{alpha_range[1]} ({info['examples'][0]})"
                )
    # Collapse the per-file warnings into one line per material.
    collapsed: list[str] = []
    seen: set[str] = set()
    for warning in warnings:
        key = warning.split(" (", 1)[0]
        if key in seen:
            continue
        seen.add(key)
        collapsed.append(warning)
    return errors, collapsed, stats


def audit_rom_outdoor() -> tuple[list[str], list[str], int]:
    """Compare the extracted outdoor manifests with the ROM chunks.

    This is the check that would have caught the prop-bundle regression that
    silently dropped every city building: it re-reads each chunk's placement
    list and resolves its resource ids against the same bundle mapping as the
    extractor.
    """
    if ndspy is None:
        return [], ["ROM prop check skipped (ndspy/Pillow tools unavailable)"], 0
    try:
        rom_path = find_rom(ROOT)
    except Exception as error:  # noqa: BLE001 - optional local ROM
        return [], [f"ROM prop check skipped: {error}"], 0
    library_path = ASSETS / "unova_outdoor" / "library.json"
    if not library_path.exists():
        return ["missing outdoor library.json"], [], 0
    library = json.loads(library_path.read_text(encoding="utf-8"))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    chunks = read_narc(rom, "a/0/0/8")
    bundles = read_narc(rom, "a/2/2/9")
    zone_data = read_narc(rom, "a/0/1/2")[0]
    area_data = bytes(rom.getFileByName("a/0/1/3"))
    errors: list[str] = []
    warnings: list[str] = []
    checked = 0
    for cell in library.get("cells", []):
        try:
            chunk = lz11_decompress(chunks[cell["model"]])
            _, placements = extract_chunk(chunk)
        except Exception as error:  # noqa: BLE001 - report corrupt chunk
            errors.append(f"cell {cell['x']},{cell['y']}: cannot parse ROM chunk: {error}")
            continue
        header = ZONE_HEADER.unpack_from(zone_data, cell["zone"] * ZONE_HEADER.size)
        area = AREA_RECORD.unpack_from(area_data, header[2] * AREA_RECORD.size)
        bundle_id = area[1] // 4
        try:
            models = prop_bundle_models(bundles[bundle_id])
        except Exception as error:  # noqa: BLE001
            errors.append(f"cell {cell['x']},{cell['y']}: cannot read prop bundle {bundle_id}: {error}")
            continue
        for placement in placements:
            checked += 1
            if placement["prop"] not in models:
                errors.append(
                    f"cell {cell['x']},{cell['y']}: ROM prop {placement['prop']} "
                    f"missing from bundle {bundle_id}"
                )
        manifest_path = (
            ASSETS
            / "unova_outdoor"
            / "cells"
            / f"cell_{cell['x']:02d}_{cell['y']:02d}"
            / "placements.json"
        )
        if not manifest_path.exists():
            errors.append(f"cell {cell['x']},{cell['y']}: missing placements.json")
            continue
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if len(manifest.get("props", [])) != len(placements):
            errors.append(
                f"cell {cell['x']},{cell['y']}: ROM has {len(placements)} props, "
                f"manifest has {len(manifest.get('props', []))}"
            )
    return errors, warnings, checked


def audit_maps(maps: dict[str, dict]) -> tuple[list[str], list[str], dict]:
    errors: list[str] = []
    warnings: list[str] = []
    height_pairs: list[dict] = []
    all_height_pairs: list[dict] = []
    summary = {
        "maps": len(maps),
        "portals": 0,
        "walkable": 0,
        "reachable": 0,
        "height_pairs": 0,
    }

    for map_id, map_data in maps.items():
        tiles = map_data.get("tiles") or []
        if not tiles:
            errors.append(f"{map_id}: no tiles")
            continue
        width = len(str(tiles[0]))
        height = len(tiles)
        for row_index, row in enumerate(tiles):
            if len(str(row)) != width:
                errors.append(f"{map_id}: row {row_index} is {len(str(row))} wide, expected {width}")
        spawn = map_data.get("spawn") or {}
        sx, sy = int(spawn.get("x", 0)), int(spawn.get("y", 0))
        if not is_walkable(map_data, sx, sy):
            errors.append(f"{map_id}: spawn {sx},{sy} is not walkable")
        npc_tiles = {
            (int(npc.get("x", 0)), int(npc.get("y", 0)))
            for npc in map_data.get("npcs", [])
        }
        if (sx, sy) in npc_tiles:
            errors.append(f"{map_id}: spawn {sx},{sy} is occupied by an NPC")
        for npc in map_data.get("npcs", []):
            if map_id.startswith("unova_in_") and npc.get("kind") not in SERVICE_KINDS:
                errors.append(
                    f"{map_id}: non-service NPC {npc.get('id')} ({npc.get('kind')})"
                )

        ports = map_data.get("portals", [])
        summary["portals"] += len(ports)
        for portal in ports:
            target_id = str(portal.get("targetMap", ""))
            target = maps.get(target_id)
            tx, ty = int(portal.get("targetX", 0)), int(portal.get("targetY", 0))
            if target is None:
                errors.append(f"{map_id}: portal {portal.get('x')},{portal.get('y')} targets missing map {target_id}")
                continue
            if not is_walkable(target, tx, ty):
                errors.append(
                    f"{map_id}: portal {portal.get('x')},{portal.get('y')} "
                    f"targets non-walkable {target_id} {tx},{ty}"
                )

        heights = Heights(map_data)
        total_walkable = 0
        for y in range(height):
            for x in range(width):
                if is_walkable(map_data, x, y):
                    total_walkable += 1
        summary["walkable"] += total_walkable
        open_reach = reachable(map_data, heights)
        summary["reachable"] += len(open_reach)
        blocked_reach = reachable(map_data, heights, npc_tiles)
        for source in sorted(portal_sources(map_data)):
            if source not in open_reach:
                warnings.append(f"{map_id}: portal source {source[0]},{source[1]} is unreachable from spawn")
                break
        if npc_tiles and len(blocked_reach) < len(open_reach):
            blocked_portals = [
                source for source in portal_sources(map_data)
                if source in open_reach and source not in blocked_reach
            ]
            if blocked_portals:
                errors.append(
                    f"{map_id}: NPCs block {len(blocked_portals)} portal tile(s), "
                    f"e.g. {blocked_portals[0][0]},{blocked_portals[0][1]}"
                )

        # Adjacent walkable tiles with an upward step > 24. These are one-way
        # ledges in the ROM, but on flat-looking paths they are invisible walls.
        count = 0
        samples: list[dict] = []
        for y in range(height):
            for x in range(width):
                if not is_walkable(map_data, x, y):
                    continue
                for dx, dy in ((1, 0), (0, 1)):
                    nx, ny = x + dx, y + dy
                    if not is_walkable(map_data, nx, ny):
                        continue
                    delta = heights.at(nx, ny) - heights.at(x, y)
                    if delta > MAX_STEP_UP:
                        pair = {
                            "map": map_id,
                            "from": (x, y),
                            "to": (nx, ny),
                            "delta": round(delta, 2),
                            "near_portal": any(
                                abs(px - x) <= PORTAL_NEAR and abs(py - y) <= PORTAL_NEAR
                                for px, py in portal_sources(map_data)
                            ),
                        }
                        count += 1
                        all_height_pairs.append(pair)
                        if len(samples) < 4:
                            samples.append(pair)
                    reverse = heights.at(x, y) - heights.at(nx, ny)
                    if reverse > MAX_STEP_UP:
                        pair = {
                            "map": map_id,
                            "from": (nx, ny),
                            "to": (x, y),
                            "delta": round(reverse, 2),
                            "near_portal": any(
                                abs(px - x) <= PORTAL_NEAR and abs(py - y) <= PORTAL_NEAR
                                for px, py in portal_sources(map_data)
                            ),
                        }
                        count += 1
                        all_height_pairs.append(pair)
                        if len(samples) < 4:
                            samples.append(pair)
        summary["height_pairs"] += count
        if count:
            height_pairs.append({"map": map_id, "count": count, "samples": samples})

    height_pairs.sort(key=lambda item: (not any(s["near_portal"] for s in item["samples"]), -item["count"]))
    return errors, warnings, {
        "summary": summary,
        "height_pairs": height_pairs,
        "all_height_pairs": all_height_pairs,
    }


def write_report(
    path: Path,
    maps: dict[str, dict],
    errors: list[str],
    warnings: list[str],
    map_result: dict,
    material_stats: dict[str, dict],
) -> None:
    summary = map_result["summary"]
    lines: list[str] = []
    lines.append("# BWMMO map audit")
    lines.append("")
    lines.append(
        f"- Maps: **{summary['maps']}**; portals: **{summary['portals']}**; "
        f"walkable tiles: **{summary['walkable']}**"
    )
    lines.append(
        f"- Errors: **{len(errors)}**; warnings: **{len(warnings)}**; "
        f"height step-ups: **{summary['height_pairs']}**"
    )
    lines.append("")
    lines.append("## Errors")
    lines.append("")
    lines.extend(f"- {item}" for item in errors) if errors else lines.append("- None")
    lines.append("")
    lines.append("## Warnings")
    lines.append("")
    if warnings:
        seen: set[str] = set()
        for item in warnings:
            if item in seen:
                continue
            seen.add(item)
            lines.append(f"- {item}")
    else:
        lines.append("- None")
    lines.append("")
    lines.append("## Height step-ups (> 24 units, potential invisible walls)")
    lines.append("")
    lines.append(
        "These are adjacent walkable tiles whose upward height difference exceeds "
        "`MAX_STEP_UP`. Ledges are intentional, but pairs near a portal are worth "
        "checking first (the Pinwheel Forest entrance was one of these)."
    )
    lines.append("")
    for entry in map_result["height_pairs"][:40]:
        lines.append(f"### {entry['map']} ({entry['count']} pairs)")
        for sample in entry["samples"]:
            near = " **near portal**" if sample["near_portal"] else ""
            lines.append(
                f"- {sample['from'][0]},{sample['from'][1]} -> "
                f"{sample['to'][0]},{sample['to'][1]} (up {sample['delta']}){near}"
            )
        lines.append("")
    if not map_result["height_pairs"]:
        lines.append("- None")
    lines.append("")
    lines.append("## Render-risk materials")
    lines.append("")
    risky = [
        (name, info)
        for name, info in sorted(material_stats.items())
        if info.get("issues")
    ]
    for name, info in risky[:80]:
        modes = ", ".join(f"{mode}:{count}" for mode, count in info["alpha_modes"].items())
        lines.append(
            f"- `{name}` ({modes}){', light/glow' if info['light'] else ''} "
            f"e.g. {info['examples'][0]}"
        )
    if not risky:
        lines.append("- None")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        default=str(ROOT / ".tools" / "map-audit" / "report.md"),
        help="Markdown report path",
    )
    args = parser.parse_args()

    maps = load_maps()
    if not maps:
        print("No maps found under server/content/maps", file=sys.stderr)
        return 1

    map_errors, map_warnings, map_result = audit_maps(maps)
    rom_errors, rom_warnings, rom_props = audit_rom_outdoor()
    glbs, asset_errors = collect_glbs(maps)
    material_errors, material_warnings, material_stats = audit_materials(glbs)

    errors = map_errors + rom_errors + asset_errors + material_errors
    warnings = map_warnings + rom_warnings + material_warnings
    map_result["summary"]["rom_props"] = rom_props
    report = Path(args.report)
    write_report(report, maps, errors, warnings, map_result, material_stats)
    csv_path = report.with_name("height-pairs.csv")
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", encoding="utf-8") as handle:
        handle.write("map,from_x,from_y,to_x,to_y,delta,near_portal\n")
        for pair in map_result["all_height_pairs"]:
            handle.write(
                f"{pair['map']},{pair['from'][0]},{pair['from'][1]},"
                f"{pair['to'][0]},{pair['to'][1]},{pair['delta']},"
                f"{int(pair['near_portal'])}\n"
            )

    print(f"Maps:     {len(maps)}")
    print(f"GLBs:     {len(glbs)}")
    print(f"ROM props:{rom_props}")
    print(f"Errors:   {len(errors)}")
    print(f"Warnings: {len(warnings)}")
    print(f"Report:   {report}")
    print(f"Height CSV: {csv_path}")
    if errors:
        for error in errors[:12]:
            print(f"  ERROR {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
