#!/usr/bin/env python3
"""Build playable indoor maps and door portals from ROM zone entities.

Inputs:
  server/content/rom/zone_entities.json   (extract_zone_entities.py)
  server/content/rom/npc_dialogues.json    (extract_dialogues.py)
  server/content/worlds/unova_full.json    (build_unova_world.py)
  server/content/worlds/unova_indoor.json  (build_unova_indoor_worlds.py)
  server/content/maps/unova_full.json      (existing NPCs preserved)

Outputs:
  server/content/maps/unova_full.json      (fresh collision/visual + portals)
  server/content/maps/unova_in_<zone>.json (one map per walkable indoor scene)

Doors come from `a/1/2/5` warp entries. A warp's coordinates point at the door
tile; the destination is the target warp's own tile in the target zone. Each
portal keeps the source warp's contact direction as `entryDir`, so the server
only uses the door when the player walks into it the same way the ROM expects.
`onWarpTile` is false when the trigger was snapped to the walkable strip in
front of a solid door (the full 1x3/3x1 frontage), which means the player must
press into the door instead of simply stepping onto the trigger tile.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import find_rom, read_narc

WALKABLE = set(".,gf=P")
DIRECTIONS = ("down", "up", "left", "right")
CONTACT_TO_DIR = {1: "down", 2: "up", 3: "right", 4: "left"}
APPROACH_DELTA = {"down": (0, 1), "up": (0, -1), "left": (-1, 0), "right": (1, 0)}
OPPOSITE = {"down": "up", "up": "down", "left": "right", "right": "left"}
COLORS = ["#f2b8c6", "#a9d6e5", "#c7f9cc", "#ffd6a5", "#d0bfff", "#ffc9de"]

NUVEMA_NAMES = {
    390: "Player's House",
    391: "Player's House 2F",
    392: "Bianca's House",
    393: "Bianca's House 2F",
    394: "Cheren's House",
    395: "Cheren's House 2F",
    396: "Professor Juniper's Lab",
}


def indoor_map_id(zone: int) -> str:
    return f"unova_in_{zone}"


def nearest_walkable(tiles: list[str], x: int, y: int, radius: int = 3) -> tuple[int, int] | None:
    height = len(tiles)
    width = len(tiles[0]) if height else 0
    if 0 <= x < width and 0 <= y < height and tiles[y][x] in WALKABLE:
        return x, y
    for distance in range(1, radius + 1):
        best = None
        for dy in range(-distance, distance + 1):
            for dx in range(-distance, distance + 1):
                if max(abs(dx), abs(dy)) != distance:
                    continue
                nx, ny = x + dx, y + dy
                if not (0 <= nx < width and 0 <= ny < height):
                    continue
                if tiles[ny][nx] not in WALKABLE:
                    continue
                score = abs(dx) + abs(dy)
                if best is None or score < best[0]:
                    best = (score, nx, ny)
        if best is not None:
            return best[1], best[2]
    return None


def warp_tiles(
    tiles: list[str], warp: dict
) -> tuple[list[tuple[int, int]], bool]:
    """Walkable tiles a warp covers, and whether they are the warp's own tiles.

    A warp's anchor is the top-left tile in 1/16-tile space and width/height
    count tiles. Side doors are usually 1x3 and building doors 3x1. When the
    doorway is solid in the permission grid, the trigger is the whole walkable
    strip on the contact side of the doorway, so every tile of the original
    doorway accepts the entrance; the second value is false then, so the server
    knows the player is standing at the door rather than in it.
    """
    height = len(tiles)
    width = len(tiles[0]) if height else 0
    ax, ay = warp["x"] // 16, warp["y"] // 16
    fw = max(1, int(warp.get("width", 1)))
    fh = max(1, int(warp.get("height", 1)))
    covered = []
    for y in range(ay, ay + fh):
        if not (0 <= y < height):
            continue
        for x in range(ax, ax + fw):
            if not (0 <= x < width):
                continue
            if tiles[y][x] in WALKABLE:
                covered.append((x, y))
    if covered:
        return covered, True
    # Solid doorway: the ROM warp covers the full door (1x3 or 3x1), so the
    # contact strip in front of it has the same length. Returning only the
    # nearest tile made side doors require pixel-perfect alignment.
    approach = CONTACT_TO_DIR.get(warp.get("contactDirection"))
    if approach:
        dx, dy = APPROACH_DELTA[approach]
        frontage = []
        for y in range(ay, ay + fh):
            for x in range(ax, ax + fw):
                fx, fy = x - dx, y - dy
                if 0 <= fx < width and 0 <= fy < height and tiles[fy][fx] in WALKABLE:
                    frontage.append((fx, fy))
        if frontage:
            return frontage, False
    snapped = nearest_walkable(tiles, ax, ay, radius=2)
    return ([snapped] if snapped is not None else []), False


def scene_kind(map_file: str) -> str:
    name = map_file.rsplit("/", 1)[-1].lower()
    if "labo" in name or "lab" in name:
        return "Laboratory"
    if name.startswith("m_pc") or "pokecenter" in name or "pc_" in name:
        return "Pokémon Center"
    if "shop" in name or "mart" in name:
        return "Poké Mart"
    if "gym" in name:
        return "Gym"
    if name.startswith("m_hh") or name.startswith("m_fh"):
        return "House"
    if "cave" in name or name.startswith("m_cv"):
        return "Cave"
    return "Interior"


def scene_name(scene: dict) -> str:
    zone = scene["zone"]
    if zone in NUVEMA_NAMES:
        return NUVEMA_NAMES[zone]
    map_file = scene["visual"]["chunks"][0]["mapFile"] if scene["visual"]["chunks"] else ""
    return scene_kind(map_file)


def target_facing(zones: dict[int, dict], target_zone: int, target_warp: int) -> str | None:
    target = zones.get(target_zone)
    if target is None or target_warp >= len(target["warps"]):
        return None
    contact = target["warps"][target_warp]["contactDirection"]
    facing = CONTACT_TO_DIR.get(contact)
    return OPPOSITE.get(facing) if facing else None


def resolve_destination(
    zones: dict[int, dict],
    scenes: dict[int, dict],
    outdoor_tiles: list[str],
    outdoor_zones: set[int],
    target_zone: int,
    target_warp: int,
) -> tuple[str, int, int] | None:
    target = zones.get(target_zone)
    if target is None or target_warp >= len(target["warps"]):
        return None
    warp = target["warps"][target_warp]
    tx, ty = warp["x"] // 16, warp["y"] // 16
    if target["type"] == 0:
        if target_zone not in outdoor_zones:
            return None
        position = nearest_walkable(outdoor_tiles, tx, ty)
        if position is None:
            return None
        return "unova_full", position[0], position[1]
    scene = scenes.get(target_zone)
    if scene is None:
        return None
    position = nearest_walkable(scene["tiles"], tx, ty)
    if position is None:
        return None
    return indoor_map_id(target_zone), position[0], position[1]


def npc_dialogue(
    zone: int, npc: dict, dialogues: dict
) -> tuple[str, list[str], str, list[dict], list[int]]:
    fallback_name, fallback_lines, kind = npc_name(zone, npc)
    profile = (
        dialogues.get("zones", {})
        .get(str(zone), {})
        .get("npcs", {})
        .get(str(npc["id"]))
    )
    if not profile:
        return fallback_name, fallback_lines, kind, [], []
    name = profile.get("name") or fallback_name
    lines = profile.get("lines") or fallback_lines
    variants = profile.get("variants", [])
    set_flags = profile.get("setFlags", [])
    return name, lines, kind, variants, set_flags


def npc_name(zone: int, npc: dict) -> tuple[str, list[str], str]:
    # Every Pokémon Center in BW puts the nurse behind the counter with script
    # 2100 (model 78). The generic indoor fallback used to turn her into a
    # Resident, which left the Center unable to heal.
    if npc.get("script") == 2100:
        return (
            "Nurse Joy",
            [
                "Welcome to the Pokémon Center!",
                "Let me take care of your Pokémon.",
                "There! Your team is fighting fit again."
            ],
            "healer",
        )
    if zone == 396:
        if npc["id"] == 0:
            return (
                "Professor Juniper",
                [
                    "Pokémon are wonderful partners. Take good care of the one you chose!",
                    "The lab is open to every trainer in Unova."
                ],
                "guide",
            )
        if npc["id"] == 4:
            return ("Pokémon", ["Skreet! Skreet!"], "npc")
        return (
            "Lab Assistant",
            ["Professor Juniper is studying how Pokémon grow stronger."],
            "npc",
        )
    if zone == 390 and npc["script"] == 2:
        return (
            "Mom",
            ["Off on an adventure already? Don't forget to say hello to everyone in town!"],
            "healer",
        )
    if zone in (390, 392, 394):
        return (
            "Resident",
            ["Nuvema Town is quiet, but every journey starts somewhere."],
            "npc",
        )
    return (
        "Resident",
        ["Welcome in. The door is always open for traveling trainers."],
        "npc",
    )


def seal_center_counter(tiles: list[list[str]]) -> None:
    """Close the area behind the Pokémon Center counter.

    The ROM permission grid marks the floor inside the U-shaped counter as
    walkable because the counter itself is a prop with its own collision mesh.
    Our indoor collision only reads the permission grid, so without this patch
    the player can step around Nurse Joy into the counter. Keep the nurse's
    own tile walkable for validation and the row in front open for dialogue.
    """
    for y, blocked_x in (
        (8, (5, 9)),
        (9, (4, 5, 9, 10)),
        (10, (5, 6, 8, 9)),
    ):
        if y >= len(tiles):
            continue
        for x in blocked_x:
            if x < len(tiles[y]):
                tiles[y][x] = "#"


def build_indoor_map(
    scene: dict,
    zone_entities: dict[int, dict],
    zones: dict[int, dict],
    scenes: dict[int, dict],
    outdoor_tiles: list[str],
    outdoor_zones: set[int],
    dialogues: dict,
) -> dict | None:
    zone = scene["zone"]
    name = scene_name(scene)
    tiles = [list(row) for row in scene["tiles"]]
    width, height = scene["width"], scene["height"]
    if name == "Pokémon Center":
        seal_center_counter(tiles)

    spawn = None
    for warp in zone_entities.get(zone, {}).get("warps", []):
        spawn = nearest_walkable(scene["tiles"], warp["x"] // 16, warp["y"] // 16)
        if spawn is not None:
            break
    if spawn is None:
        for y in range(height):
            for x in range(width):
                if tiles[y][x] in WALKABLE:
                    spawn = (x, y)
                    break
            if spawn:
                break
    if spawn is None:
        return None

    portals = []
    used_sources = set()
    for warp in zone_entities.get(zone, {}).get("warps", []):
        covered, on_warp_tile = warp_tiles(scene["tiles"], warp)
        sources = [cell for cell in covered if cell not in used_sources]
        if not sources:
            continue
        destination = resolve_destination(
            zones,
            scenes,
            outdoor_tiles,
            outdoor_zones,
            warp["targetZone"],
            warp["targetWarp"],
        )
        if destination is None:
            continue
        target_map, tx, ty = destination
        facing = target_facing(zones, warp["targetZone"], warp["targetWarp"])
        entry = CONTACT_TO_DIR.get(warp["contactDirection"])
        for sx, sy in sources:
            used_sources.add((sx, sy))
            tiles[sy][sx] = "P"
            portal = {
                "x": sx,
                "y": sy,
                "targetMap": target_map,
                "targetX": tx,
                "targetY": ty,
                "onWarpTile": on_warp_tile,
            }
            if facing:
                portal["targetDir"] = facing
            if entry:
                portal["entryDir"] = entry
            portals.append(portal)

    npcs = []
    occupied = {(spawn[0], spawn[1])} | used_sources
    for entity in zone_entities.get(zone, {}).get("npcs", []):
        position = nearest_walkable(scene["tiles"], entity["x"], entity["z"], radius=2)
        if position is None or position in occupied:
            continue
        name, dialogue, kind, variants, set_flags = npc_dialogue(
            zone, entity, dialogues
        )
        npc = {
            "id": f"z{zone}_n{entity['id']}",
            "name": name,
            "x": position[0],
            "y": position[1],
            "color": COLORS[entity["model"] % len(COLORS)],
            "kind": kind,
            "sprite": entity["model"] % 4,
            "dialogue": dialogue,
        }
        if variants:
            npc["dialogueVariants"] = variants
        if set_flags:
            npc["setFlags"] = set_flags
        occupied.add(position)
        npcs.append(npc)

    return {
        "id": indoor_map_id(zone),
        "name": name,
        "zone": zone,
        "spawn": {"x": spawn[0], "y": spawn[1], "dir": "down"},
        "tiles": ["".join(row) for row in tiles],
        "npcs": npcs,
        "portals": portals,
        "visual": scene["visual"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--entities", default="server/content/rom/zone_entities.json")
    parser.add_argument("--dialogues", default="server/content/rom/npc_dialogues.json")
    parser.add_argument("--outdoor", default="server/content/worlds/unova_full.json")
    parser.add_argument("--indoor", default="server/content/worlds/unova_indoor.json")
    parser.add_argument("--maps", default="server/content/maps")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    overworld = read_narc(rom, "a/0/0/9")[0]
    _, _, grid_width, grid_height = struct.unpack_from("<HHHH", overworld, 0)
    models = struct.unpack_from(f"<{grid_width * grid_height}I", overworld, 8)
    zone_grid = struct.unpack_from(
        f"<{grid_width * grid_height}I", overworld, 8 + 4 * grid_width * grid_height
    )
    outdoor_zones = {
        zone for zone, model in zip(zone_grid, models) if zone != 0xFFFFFFFF and model != 0xFFFFFFFF
    }

    entity_data = json.loads((root / args.entities).read_text(encoding="utf-8"))
    dialogue_path = (root / args.dialogues).resolve()
    if dialogue_path.exists():
        dialogue_data = json.loads(dialogue_path.read_text(encoding="utf-8"))
    else:
        dialogue_data = {"zones": {}}
        print(f"Warning: {dialogue_path} missing; using fallback NPC dialogue")
    zones = {zone["id"]: zone for zone in entity_data["zones"]}
    scene_data = json.loads((root / args.indoor).read_text(encoding="utf-8"))
    scenes = {scene["zone"]: scene for scene in scene_data["scenes"]}
    outdoor_world = json.loads((root / args.outdoor).read_text(encoding="utf-8"))
    outdoor_tiles = list(outdoor_world["tiles"])

    maps_dir = (root / args.maps).resolve()
    existing_outdoor_path = maps_dir / "unova_full.json"
    existing_outdoor = (
        json.loads(existing_outdoor_path.read_text(encoding="utf-8"))
        if existing_outdoor_path.exists()
        else {}
    )

    indoor_maps = {}
    skipped = 0
    portal_count = 0
    for scene in scene_data["scenes"]:
        map_def = build_indoor_map(
            scene, zones, zones, scenes, outdoor_tiles, outdoor_zones, dialogue_data
        )
        if map_def is None:
            skipped += 1
            continue
        indoor_maps[map_def["id"]] = map_def
        portal_count += len(map_def["portals"])

    outdoor_portals = []
    used_sources = set()
    for zone_id in sorted(outdoor_zones):
        zone = zones.get(zone_id)
        if zone is None or zone["type"] != 0:
            continue
        for warp in zone["warps"]:
            covered, on_warp_tile = warp_tiles(outdoor_tiles, warp)
            sources = [cell for cell in covered if cell not in used_sources]
            if not sources:
                continue
            destination = resolve_destination(
                zones,
                scenes,
                outdoor_tiles,
                outdoor_zones,
                warp["targetZone"],
                warp["targetWarp"],
            )
            if destination is None:
                continue
            target_map, tx, ty = destination
            if target_map.startswith("unova_in_") and int(target_map.rsplit("_", 1)[1]) not in {
                map_def["zone"] for map_def in indoor_maps.values()
            }:
                continue
            facing = target_facing(zones, warp["targetZone"], warp["targetWarp"])
            entry = CONTACT_TO_DIR.get(warp["contactDirection"])
            for sx, sy in sources:
                used_sources.add((sx, sy))
                outdoor_tiles[sy] = outdoor_tiles[sy][:sx] + "P" + outdoor_tiles[sy][sx + 1:]
                portal = {
                    "x": sx,
                    "y": sy,
                    "targetMap": target_map,
                    "targetX": tx,
                    "targetY": ty,
                    "onWarpTile": on_warp_tile,
                }
                if facing:
                    portal["targetDir"] = facing
                if entry:
                    portal["entryDir"] = entry
                outdoor_portals.append(portal)

    outdoor_map = {
        **existing_outdoor,
        "id": "unova_full",
        "name": "Unova",
        "spawn": outdoor_world["spawn"],
        "tiles": outdoor_tiles,
        "npcs": existing_outdoor.get("npcs", []),
        "portals": outdoor_portals,
        "encounterZones": outdoor_world.get("encounterZones", []),
        "visual": outdoor_world["visual"],
    }
    outdoor_map.pop("width", None)
    outdoor_map.pop("height", None)
    existing_outdoor_path.write_text(json.dumps(outdoor_map, indent=2) + "\n", encoding="utf-8")

    replaced = 0
    for path in maps_dir.glob("unova_in_*.json"):
        zone = int(path.stem.rsplit("_", 1)[1])
        if zone not in {map_def["zone"] for map_def in indoor_maps.values()}:
            path.unlink()
            replaced += 1
    for map_def in indoor_maps.values():
        path = maps_dir / f"{map_def['id']}.json"
        path.write_text(json.dumps(map_def, indent=2) + "\n", encoding="utf-8")

    print(
        f"Wrote {len(indoor_maps)} indoor maps ({skipped} scenes skipped, "
        f"{portal_count} indoor portals), unova_full with {len(outdoor_portals)} portals"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
